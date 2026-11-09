import Foundation

/// `--self-test` suites for the sub-agent rows: what an agent is doing (`AgentAction`), Claude's
/// sub-agent meta file, and the shared row rules (`ChildAgent.headline` / `detail`).
extension SelfTest {
    static func agentSuites() -> [Suite] {
        [
            Suite(name: "Agent actions (Claude)", body: claudeActions),
            Suite(name: "Agent actions (Codex)", body: codexActions),
            Suite(name: "Sub-agent rows", body: childRows),
            Suite(name: "Usage schedule", body: usageSchedule),
        ]
    }

    /// When ccusage runs (`UsageSchedule`) and what a failed run's log line keeps (`stderrTail`).
    private static func usageSchedule(_ t: inout Tester) {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        func run(at s: TimeInterval, gap: TimeInterval = 60, attempt: TimeInterval?, success: TimeInterval?,
                 activity: TimeInterval?) -> Bool {
            UsageSchedule.shouldRun(now: t0 + s, minGap: gap, lastAttempt: attempt.map { t0 + $0 },
                                    lastSuccess: success.map { t0 + $0 }, latestActivity: activity.map { t0 + $0 })
        }
        t.expect(run(at: 0, attempt: nil, success: nil, activity: nil), "first run ever goes")
        t.expect(!run(at: 100, attempt: 0, success: 0, activity: -10), "idle since the last good run: no run")
        t.expect(!run(at: 100, attempt: 0, success: 0, activity: nil), "no local chats: no run")
        t.expect(run(at: 100, attempt: 0, success: 0, activity: 50), "activity since the last good run: run")
        t.expect(!run(at: 30, attempt: 0, success: 0, activity: 20), "activity, but within the gap: wait")
        t.expect(!run(at: 30, attempt: 0, success: -500, activity: -100), "a failed run still counts for the gap")
        t.expect(run(at: 70, attempt: 0, success: -500, activity: -100), "after the gap, a failed run is retried")
        t.expect(run(at: 0, gap: 0, attempt: 0, success: -900, activity: -10), "background timer (gap 0) retries")

        let noisy = Data("Resolving dependencies\nResolved, downloaded and extracted [2]\nSaved lockfile\nerror: EMFILE\n  at read\n".utf8)
        t.equal(UsageProvider.stderrTail(noisy), "error: EMFILE | at read", "stderr tail drops bunx chatter, one line")
        t.equal(UsageProvider.stderrTail(Data()), "(empty)", "empty stderr is said so")
        t.equal(UsageProvider.stderrTail(Data(String(repeating: "x", count: 700).utf8), limit: 10), "…xxxxxxxxxx",
                "a long stderr keeps its end")
    }

    private static func claudeActions(_ t: inout Tester) {
        t.equal(AgentAction.claude(tool: "Bash", input: ["command": "git diff --stat\n  && echo x"]), .command("git diff --stat"),
                "Bash: the command's first line")
        t.equal(AgentAction.claude(tool: "Read", input: ["file_path": "/a/b/StateEngine.swift"]), .read("StateEngine.swift"),
                "Read: the file name")
        t.equal(AgentAction.claude(tool: "MultiEdit", input: ["file_path": "/a/Models.swift"]), .edit("Models.swift"), "MultiEdit edits")
        t.equal(AgentAction.claude(tool: "NotebookEdit", input: ["notebook_path": "/a/n.ipynb"]), .edit("n.ipynb"), "NotebookEdit edits")
        t.equal(AgentAction.claude(tool: "Grep", input: ["pattern": "func render"]), .search("func render"), "Grep: the pattern")
        t.equal(AgentAction.claude(tool: "WebFetch", input: ["url": "https://learn.chatgpt.com/docs/hooks.md"]),
                .open("learn.chatgpt.com"), "WebFetch: the host")
        t.equal(AgentAction.claude(tool: "WebSearch", input: ["query": "codex hooks"]), .webSearch("codex hooks"), "WebSearch: the query")
        t.equal(AgentAction.claude(tool: "Task", input: ["description": "Map hooks"]), .delegate("Map hooks"), "Task: its description")
        t.equal(AgentAction.claude(tool: "TodoWrite", input: [:]), nil, "the to-do list is not an action")
        t.equal(AgentAction.claude(tool: "mcp__codebase-memory-mcp__search_graph", input: [:]),
                .tool("codebase-memory-mcp · search_graph"), "MCP: server · tool")
        t.equal(AgentAction.claude(tool: "Bash", input: [:]), .tool("Bash"), "missing input: the tool's name")
        t.equal(AgentAction.claude(tool: "Skill", input: ["skill": "x"]), .tool("Skill"), "unknown tools: their name")

        func assistant(_ blocks: [[String: Any]]) -> String {
            let obj: [String: Any] = ["type": "assistant", "message": ["role": "assistant", "content": blocks]]
            return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        }
        let result = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}"#
        let lines = [
            assistant([["type": "tool_use", "name": "Read", "input": ["file_path": "/a/Old.swift"]]]),
            result,
            assistant([["type": "text", "text": "hm"], ["type": "tool_use", "name": "Bash", "input": ["command": "rg -n flow"]],
                       ["type": "tool_use", "name": "TodoWrite", "input": [:]]]),
            result,
        ]
        t.equal(AgentAction.lastClaude(in: lines), .command("rg -n flow"),
                "the latest tool_use wins, skipping bookkeeping tools in the same message")
        t.equal(AgentAction.lastClaude(in: [result]), nil, "no tool_use → nothing")

        let meta = ClaudeSubagentMeta.parse(Data(#"{"agentType":"Explore","description":"Map hooks\nmore","finished":true}"#.utf8))
        t.equal(meta, ClaudeSubagentMeta(description: "Map hooks", agentType: "Explore", finished: true), "meta.json fields")
        t.equal(ClaudeSubagentMeta.parse(Data("[]".utf8)), nil, "a non-object meta is ignored")
        let dir = t.tempDir()
        let transcript = (dir as NSString).appendingPathComponent("agent-abc.jsonl")
        FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent("agent-abc.meta.json"),
                                       contents: Data(#"{"description":"Review diff"}"#.utf8))
        t.equal(ClaudeSubagentMeta.read(transcriptPath: transcript)?.description, "Review diff", "read beside the transcript")
    }

    private static func codexActions(_ t: inout Tester) {
        t.equal(AgentAction.codex(item: ["type": "CommandExecution", "command": ["/bin/zsh", "-lc", "cat /a/SKILL.md"],
                                         "parsed_cmd": [["type": "read", "cmd": "cat /a/SKILL.md", "name": "SKILL.md", "path": "/a/SKILL.md"]]]),
                .read("SKILL.md"), "a single file read reads as Reading <file>")
        t.equal(AgentAction.codex(item: ["type": "CommandExecution", "command": ["/bin/zsh", "-lc", "rg -n 'flow' lib/ | head"],
                                         "parsed_cmd": [["type": "unknown", "cmd": "rg"], ["type": "unknown", "cmd": "head"]]]),
                .command("rg -n 'flow' lib/ | head"), "anything else: the command, without the zsh -lc wrapper")
        t.equal(AgentAction.codex(item: ["type": "CommandExecution", "command": ["git", "status"]]), .command("git status"),
                "a bare argv is joined")
        t.equal(AgentAction.codex(item: ["type": "FileChange", "changes": #"{"/a/Z.md":{"type":"update"},"/a/Plan.md":{"type":"add"}}"#]),
                .edit("Plan.md +1"), "FileChange (JSON-encoded): the first file by path and how many more")
        t.equal(AgentAction.codex(item: ["type": "FileChange", "changes": ["/a/X.swift": ["type": "update"]]]), .edit("X.swift"),
                "FileChange (inline object)")
        t.equal(AgentAction.codex(item: ["type": "McpToolCall", "server": "codebase-memory-mcp", "tool": "list_projects"]),
                .tool("codebase-memory-mcp · list_projects"), "MCP: server · tool")
        t.equal(AgentAction.codex(item: ["type": "Extension", "kind": "web.search", "query": "x",
                                         "action": ["type": "openPage", "url": "https://openrouter.ai/api/v1/models"]]),
                .open("openrouter.ai"), "opening a page: its host")
        t.equal(AgentAction.codex(item: ["type": "Extension", "kind": "web.search", "query": "swift actors"]), .webSearch("swift actors"),
                "a web search: its query")
        t.equal(AgentAction.codex(item: ["type": "ImageView", "path": "file:///a/shot.png"]), .view("shot.png"), "viewing an image")
        for type in ["Reasoning", "AgentMessage", "SubAgentActivity", "ContextCompaction", "CollabAgentToolCall"] {
            t.equal(AgentAction.codex(item: ["type": type]), nil, "\(type) is not an action")
        }

        // Through the rollout parser: own actions only, the latest wins.
        let now = Date()
        func line(_ ord: Int, _ type: String, _ payload: [String: Any]) -> String {
            let obj: [String: Any] = ["timestamp": now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
                                      "type": type, "payload": payload, "ordinal": ord]
            return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        }
        let cmd = { (c: String) -> [String: Any] in ["type": "item_completed", "item": ["type": "CommandExecution", "command": ["zsh", "-lc", c]]] }
        let tail = CodexRolloutParser.parseTail(lines: [
            line(0, "session_meta", ["id": "kid", "subagent_history_start_ordinal": 2]),
            line(1, "event_msg", cmd("parent's command")),
            line(2, "event_msg", cmd("ls lib")),
            line(3, "event_msg", ["type": "item_completed", "item": ["type": "Reasoning"]]),
        ])
        t.equal(tail.lastAction, .command("ls lib"), "the sub-agent's own latest action; copied history and reasoning don't count")

        t.equal(CodexSessionStore.taskName("/root/analysis_rag"), "Analysis rag", "task path → readable name")
        t.equal(CodexSessionStore.taskName("/root/team/selection-flow"), "Selection flow", "the last component, dashes too")
        t.equal(CodexSessionStore.taskName("/root"), nil, "the root itself is no task")
        t.equal(CodexSessionStore.taskName(nil), nil, "no path, no name")

        t.equal(AgentAction.oneLine("  a \t b  \nsecond"), "a b", "first line, whitespace collapsed")
        t.equal(AgentAction.oneLine(String(repeating: "x", count: 200)).count, AgentAction.maxLength + 1, "capped with an ellipsis")
    }

    private static func childRows(_ t: inout Tester) {
        let now = Date()
        var codex = ChildAgent(id: "c", name: "Hilbert", kind: .codexSubagent, state: .working, lastActivity: now,
                               purpose: "Analysis rag", who: "Hilbert", activity: .command("rg -n flow"))
        t.equal(codex.headline, "Analysis rag", "headline: what it's for")
        t.equal(codex.detail, "rg -n flow", "working: what it's doing now")
        codex.state = .done
        t.equal(codex.detail, nil, "done, task unknown (Codex encrypts it): no second line")

        var claude = ChildAgent(id: "a", name: "aebb6cd1", kind: .subagent, state: .done, lastActivity: now,
                                title: "You are reviewing an uncommitted change", purpose: "Review diff", activity: .read("x.swift"))
        t.equal(claude.headline, "Review diff", "headline: the Task description")
        t.equal(claude.detail, "You are reviewing an uncommitted change", "done: the task's first line")
        claude.purpose = nil
        t.equal(claude.headline, "You are reviewing an uncommitted change", "no description: the task is the headline")
        t.equal(claude.detail, nil, "…and isn't repeated below it")
        claude.title = nil
        t.equal(claude.headline, "aebb6cd1", "nothing known: the id")
    }
}
