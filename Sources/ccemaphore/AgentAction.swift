import Foundation

/// What an agent did last — its latest tool call or command — in one shape for Claude Code and Codex,
/// so a sub-agent row reads the same for both ("Reading StateEngine.swift", `rg -n "flow" lib/`). Kept
/// structured, not as a sentence: `text` localizes at render time, so a language switch re-renders it,
/// while the payload (a command, a file name, a query) is shown as the agent wrote it.
enum AgentAction: Sendable, Equatable {
    /// A shell command, verbatim (first line, whitespace collapsed).
    case command(String)
    case read(String)
    case edit(String)
    case search(String)
    case list(String)
    case open(String)
    case webSearch(String)
    case view(String)
    /// Handing work to another agent (Claude's Task tool): its description.
    case delegate(String)
    /// Any other tool, by its own name (`server · tool` for MCP).
    case tool(String)

    static let maxLength = 160

    var text: String {
        switch self {
        case .command(let s), .tool(let s): return s
        case .read(let s):      return Lf("activity.read", s)
        case .edit(let s):      return Lf("activity.edit", s)
        case .search(let s):    return Lf("activity.search", s)
        case .list(let s):      return Lf("activity.list", s)
        case .open(let s):      return Lf("activity.open", s)
        case .webSearch(let s): return Lf("activity.webSearch", s)
        case .view(let s):      return Lf("activity.view", s)
        case .delegate(let s):  return Lf("activity.delegate", s)
        }
    }

    // MARK: - Claude Code

    /// A Claude Code `tool_use` block → the action. nil for bookkeeping tools that aren't "doing" anything
    /// the user cares about (the to-do list).
    static func claude(tool: String, input: [String: Any]) -> AgentAction? {
        func str(_ k: String) -> String? { (input[k] as? String).map(oneLine).flatMap { $0.isEmpty ? nil : $0 } }
        func file(_ k: String) -> String? { str(k).map { ($0 as NSString).lastPathComponent } }
        switch tool {
        case "Bash":
            return str("command").map(AgentAction.command) ?? .tool(tool)
        case "Read":
            return file("file_path").map(AgentAction.read) ?? .tool(tool)
        case "Edit", "MultiEdit", "Write":
            return file("file_path").map(AgentAction.edit) ?? .tool(tool)
        case "NotebookEdit":
            return file("notebook_path").map(AgentAction.edit) ?? .tool(tool)
        case "Grep", "Glob":
            return str("pattern").map(AgentAction.search) ?? .tool(tool)
        case "WebFetch":
            return str("url").map { .open(URL(string: $0)?.host ?? $0) } ?? .tool(tool)
        case "WebSearch":
            return str("query").map(AgentAction.webSearch) ?? .tool(tool)
        case "Task", "Agent":
            return str("description").map(AgentAction.delegate) ?? .tool(tool)
        case "TodoWrite":
            return nil
        default:
            // `mcp__<server>__<tool>` → "server · tool".
            if tool.hasPrefix("mcp__") {
                let parts = tool.dropFirst("mcp__".count).components(separatedBy: "__")
                if parts.count >= 2 { return .tool("\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))") }
            }
            return .tool(tool)
        }
    }

    /// The latest `tool_use` in a Claude Code transcript tail (raw JSONL lines, oldest first).
    static func lastClaude(in lines: [String]) -> AgentAction? {
        for line in lines.reversed() {
            guard line.contains("\"tool_use\""), let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in blocks.reversed() where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String else { continue }
                if let action = claude(tool: name, input: block["input"] as? [String: Any] ?? [:]) { return action }
            }
        }
        return nil
    }

    // MARK: - Codex

    /// A Codex `item_completed` item → the action. nil for items that aren't actions (reasoning,
    /// messages, sub-agent bookkeeping, compaction).
    static func codex(item: [String: Any]) -> AgentAction? {
        switch item["type"] as? String {
        case "CommandExecution":
            // `parsed_cmd` names the simple cases (a single file read, a listing, a search); anything else
            // is the command as run, minus the `zsh -lc` wrapper.
            if let parsed = item["parsed_cmd"] as? [[String: Any]], parsed.count == 1 {
                let p = parsed[0]
                let name = (p["name"] as? String) ?? (p["path"] as? String).map { ($0 as NSString).lastPathComponent }
                switch p["type"] as? String {
                case "read": if let name, !name.isEmpty { return .read(oneLine(name)) }
                case "list_files": if let path = p["path"] as? String { return .list(oneLine(path)) }
                case "search": if let q = p["query"] as? String { return .search(oneLine(q)) }
                default: break
                }
            }
            guard let command = item["command"] as? [String] else { return nil }
            let shell = command.count >= 3 && command[1].hasPrefix("-") && command[1].contains("c")
                && ["sh", "bash", "zsh"].contains((command[0] as NSString).lastPathComponent)
            let text = oneLine(shell ? command[command.count - 1] : command.joined(separator: " "))
            return text.isEmpty ? nil : .command(text)
        case "FileChange":
            let files = changedFiles(item["changes"])
            guard let first = files.first else { return nil }
            let name = (first as NSString).lastPathComponent
            return .edit(files.count > 1 ? "\(name) +\(files.count - 1)" : name)
        case "McpToolCall":
            guard let server = item["server"] as? String, let tool = item["tool"] as? String else { return nil }
            return .tool("\(server) · \(tool)")
        case "Extension":
            if let url = (item["action"] as? [String: Any])?["url"] as? String {
                return .open(URL(string: url)?.host ?? oneLine(url))
            }
            return (item["query"] as? String).map { .webSearch(oneLine($0)) }
        case "ImageView":
            return (item["path"] as? String).map { .view((($0 as NSString).lastPathComponent)) }
        default:
            return nil
        }
    }

    /// `changes` is a path-keyed object — sometimes inline, sometimes JSON-encoded as a string.
    private static func changedFiles(_ v: Any?) -> [String] {
        if let d = v as? [String: Any] { return d.keys.sorted() }
        if let s = v as? String, let data = s.data(using: .utf8),
           let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return d.keys.sorted() }
        return []
    }

    // MARK: - Helpers

    /// First line, runs of whitespace collapsed, capped at `maxLength`.
    static func oneLine(_ s: String) -> String {
        let first = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = first.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        return collapsed.count <= maxLength ? collapsed : String(collapsed.prefix(maxLength)) + "…"
    }
}

/// What Claude Code records next to a sub-agent transcript (`agent-<id>.meta.json`): the Task's short
/// description, the agent type, and whether it has finished.
struct ClaudeSubagentMeta: Sendable, Equatable {
    var description: String?
    var agentType: String?
    var finished: Bool?

    static func parse(_ data: Data) -> ClaudeSubagentMeta? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func s(_ k: String) -> String? { (obj[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return ClaudeSubagentMeta(description: s("description").map(AgentAction.oneLine),
                                  agentType: s("agentType"), finished: obj["finished"] as? Bool)
    }

    /// The meta file beside a sub-agent transcript.
    static func read(transcriptPath: String) -> ClaudeSubagentMeta? {
        let path = ((transcriptPath as NSString).deletingPathExtension) + ".meta.json"
        return FileManager.default.contents(atPath: path).flatMap(parse)
    }
}
