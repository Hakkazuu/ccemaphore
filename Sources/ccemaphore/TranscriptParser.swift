import Foundation

/// Minimal, lenient decode of a JSONL line — only the fields the heuristic needs. Unknown keys are
/// ignored; any line that fails to decode is simply skipped (one bad line never aborts a batch).
///
/// JSON keys are snake_case (`stop_reason`, `tool_use_id`); we decode with
/// `.convertFromSnakeCase`, so Swift properties stay camelCase. Keys that are already camel
/// (`isSidechain`, `gitBranch`, `aiTitle`) are left untouched by that strategy and match directly.
struct LogLine: Decodable {
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

    struct Message: Decodable {
        let role: String?
        let stopReason: String?   // end_turn | tool_use | stop_sequence | null
        let content: Content?
        let usage: Usage?         // present on a completed assistant turn
    }

    /// Token accounting on a completed assistant turn. input + both cache buckets ≈ the live
    /// context-window occupancy (the same sum Claude Code's statusLine reported). Keys are snake_case
    /// in the JSON; `.convertFromSnakeCase` maps them to these camelCase properties.
    struct Usage: Decodable {
        let inputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
    }

    /// `message.content` is either a plain string (user prompt) or an array of typed blocks.
    enum Content: Decodable {
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

    struct Block: Decodable {
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
