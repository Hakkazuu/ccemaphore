import Foundation

/// Minimal, lenient decode of a JSONL line — only the fields the heuristic needs. Unknown keys are
/// ignored; any line that fails to decode is simply skipped (one bad line never aborts a batch).
///
/// JSON keys are snake_case (`stop_reason`, `tool_use_id`); we decode with
/// `.convertFromSnakeCase`, so Swift properties stay camelCase. Keys that are already camel
/// (`isSidechain`, `gitBranch`, `aiTitle`) are left untouched by that strategy and match directly.
struct LogLine: Decodable, Sendable {
    let type: String?
    let subtype: String?          // "api_error" on type=="system" retry lines
    let timestamp: String?        // ISO-8601 UTC, usually with millis + "Z"
    let isSidechain: Bool?
    let cwd: String?
    let gitBranch: String?
    let aiTitle: String?
    let lastPrompt: String?
    let message: Message?

    private enum CodingKeys: String, CodingKey {
        case type, subtype, timestamp, isSidechain, cwd, gitBranch, aiTitle, lastPrompt, message
    }

    /// Decode each field independently so a single wrong-typed field (e.g. a future schema change
    /// making `timestamp` numeric) can't abort the whole line and silently drop a live record —
    /// for the *last* line that would make an active session vanish. Per-field `try?` degrades to
    /// nil for just the offending field. (`.convertFromSnakeCase` still maps the JSON keys.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type        = try? c.decodeIfPresent(String.self, forKey: .type)
        subtype     = try? c.decodeIfPresent(String.self, forKey: .subtype)
        timestamp   = try? c.decodeIfPresent(String.self, forKey: .timestamp)
        isSidechain = try? c.decodeIfPresent(Bool.self, forKey: .isSidechain)
        cwd         = try? c.decodeIfPresent(String.self, forKey: .cwd)
        gitBranch   = try? c.decodeIfPresent(String.self, forKey: .gitBranch)
        aiTitle     = try? c.decodeIfPresent(String.self, forKey: .aiTitle)
        lastPrompt  = try? c.decodeIfPresent(String.self, forKey: .lastPrompt)
        message     = try? c.decodeIfPresent(Message.self, forKey: .message)
    }

    struct Message: Decodable, Sendable {
        let role: String?
        let stopReason: String?   // end_turn | tool_use | stop_sequence | null
        let content: Content?
        let usage: Usage?         // present on a completed assistant turn
    }

    /// Token accounting on a completed assistant turn. input + both cache buckets ≈ the live
    /// context-window occupancy (the same sum Claude Code's statusLine reported). Keys are snake_case
    /// in the JSON; `.convertFromSnakeCase` maps them to these camelCase properties.
    struct Usage: Decodable, Sendable {
        let inputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
    }

    /// `message.content` is either a plain string (user prompt) or an array of typed blocks.
    enum Content: Decodable, Sendable {
        case text
        case blocks([Block])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let blocks = try? c.decode([Block].self) {
                self = .blocks(blocks)
            } else {
                self = .text
            }
        }

        var blocks: [Block] {
            if case .blocks(let b) = self { return b }
            return []
        }
    }

    struct Block: Decodable, Sendable {
        let type: String?         // text | tool_use | tool_result | ...
        let id: String?           // tool_use block id
        let toolUseId: String?    // tool_result references the tool_use id it answers
    }

    static func decode(_ line: String) -> LogLine? {
        guard let data = line.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try? dec.decode(LogLine.self, from: data)
    }
}

/// The tail-shape of a transcript's last line.
enum TailShape {
    case working          // mid-turn: assistant tool_use / unfinalized stream / fresh user prompt
    case userToolResult   // tool result just arrived; agent about to continue
    case systemRetry      // api_error auto-retry
    case doneEndTurn      // clean finish
    case other
}

/// The single copy of the working/done/waiting tail heuristic — distilled from ~90 real transcripts +
/// adversarial review. Extracted verbatim from `SessionStore`'s private machinery so the LOCAL
/// file-watch path (`SessionStore`) and the REMOTE ssh-poll path (`RemoteTranscriptPoller`) classify the
/// identical transcript tail identically instead of drifting between two hand-synced copies. Pure and
/// `nonisolated`, so both the `actor` and the `@MainActor` poller can call it.
enum TailClassifier {
    /// Tail shape of a single (last) line.
    static func shape(of line: LogLine) -> TailShape {
        if line.type == "assistant" {
            switch line.message?.stopReason {
            case "end_turn", "stop_sequence": return .doneEndTurn
            case "tool_use": return .working
            case .none: return .working               // unfinalized streaming line
            default: return .other
            }
        }
        if line.type == "user" {
            let blocks = line.message?.content?.blocks ?? []
            if blocks.contains(where: { $0.type == "tool_result" }) { return .userToolResult }
            return .working                            // fresh prompt — the agent owes a turn
        }
        return .other
    }

    /// True if the last assistant line carries a `tool_use` whose id has no matching `tool_result`
    /// after it.
    static func hasUnpairedToolUse(_ lines: [LogLine]) -> Bool {
        guard let i = lines.lastIndex(where: { $0.type == "assistant" }) else { return false }
        let toolIds = (lines[i].message?.content?.blocks ?? [])
            .compactMap { $0.type == "tool_use" ? $0.id : nil }
        guard !toolIds.isEmpty else { return false }

        var resolved = Set<String>()
        if i + 1 < lines.count {
            for line in lines[(i + 1)...] {
                for block in line.message?.content?.blocks ?? [] where block.type == "tool_result" {
                    if let t = block.toolUseId { resolved.insert(t) }
                }
            }
        }
        return toolIds.contains { !resolved.contains($0) }
    }

    /// The working/done/waiting ladder for an already-in-window (non-stale) tail. The caller applies the
    /// `age > staleWindow → .stale` gate FIRST (local `SessionStore.state(of:)` does; the remote poller
    /// pre-gates by the file's mtime before even fetching the tail), so this covers only the live tail
    /// and never returns `.stale`.
    static func classify(shape: TailShape, age: TimeInterval, hasUnpaired: Bool, activeWindow: TimeInterval) -> SessionState {
        // A trailing tool_result means the assistant still OWES its continuation — the turn is not
        // finished, however long it pauses to think between tool calls. So this stays `working`
        // regardless of age (letting a cooled tool_result fall through to `done` was the "🟢 green while
        // still working" bug during long thinking pauses).
        if shape == .userToolResult { return .working }

        if age <= activeWindow {
            switch shape {
            case .working, .systemRetry:
                return .working
            case .userToolResult, .doneEndTurn, .other:
                break
            }
        }

        // Cooled / settled tail.
        if shape == .doneEndTurn { return .done }
        if hasUnpaired { return .waiting }   // best-effort "looks like it needs the user"
        return .done
    }
}
