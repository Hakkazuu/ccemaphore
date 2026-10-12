import Foundation

/// Lenient reader for a Codex rollout transcript (`rollout-*.jsonl`). One JSON object per line:
/// `{"timestamp": ISO-8601, "ordinal"?: n, "type": …, "payload": {…}}`. Only the handful of event
/// types that carry state are interpreted; everything else is counted and ignored. Verified on
/// codex-cli 0.153–0.162 rollouts (see memory/codex-integration-research). Honest limits: Codex does NOT
/// persist approval requests or `request_user_input` waits into the rollout, so this reader can tell
/// working / done / interrupted — never "waiting for the user". That signal needs hooks (phase 3).
///
/// Per-line decoding is `JSONSerialization` into `[String: Any]` with per-field optional casts, so one
/// unexpectedly-typed field never drops the line (the same stance as `LogLine`).
struct CodexRolloutMeta: Sendable {
    let threadId: String?
    let cwd: String?
    let originator: String?
    let source: String?
    let cliVersion: String?
    let gitBranch: String?
    let threadSource: String?      // "user" | "subagent" | nil
    let parentThreadId: String?    // sub-agent threads only
    let agentNickname: String?

    /// Where the thread runs, from `originator` (shared table: `SessionHost.fromCodexOriginator`). nil
    /// when the rollout doesn't say, so the catalog's originator can decide instead.
    var host: SessionHost? { SessionHost.fromCodexOriginator(originator) }
}

/// What the tail of a rollout says right now.
struct CodexTail: Sendable {
    /// Timestamp of the last line (any persisted event counts as activity — Codex writes nothing idle).
    var lastActivity: Date? = nil
    /// `turn_id` of a `task_started` not yet closed by `task_complete` / `turn_aborted` ⇒ a turn is running.
    var openTurnId: String? = nil
    var openTurnStartedAt: Date? = nil
    var lastTurnEndedAt: Date? = nil
    var lastTurnEnd: String? = nil          // "task_complete" | "turn_aborted"
    var turnsSeen = 0
    /// A turn whose id is NOT an `external-import-*` placeholder — i.e. real Codex work happened here.
    var nativeTurnSeen = false
    /// The thread was created by ChatGPT.app's Import (Claude Code / Cursor) feature.
    var importMarkerSeen = false
    var approvalPolicy: String? = nil
    var workspaceRoots: [String] = []
    var cwd: String? = nil
    var modelContextWindow: Int? = nil
    var context: ContextInfo? = nil
    var rateLimits: RateLimitInfo? = nil
    var lastUserMessage: String? = nil
    /// Payload/line types this reader didn't recognise — surfaced by `--codex-probe` so a format change
    /// is visible instead of silently degrading.
    var unknownTypes: [String: Int] = [:]
    var linesParsed = 0
    /// Lines that are TURN WORK (model output, tool calls/results, token counts) — as opposed to
    /// bookkeeping (`session_meta`, `thread_settings_applied`). Lets `state(of:)` recognise a turn whose
    /// `task_started` scrolled out of the tail window: fresh work with no turn boundary in view is a turn.
    var workLines = 0
    /// Any `task_started` / `task_complete` / `turn_aborted` was inside the window.
    var sawTurnBoundary: Bool { turnsSeen > 0 || lastTurnEnd != nil }
}

enum CodexRolloutParser {
    /// Head window large enough to hold the (big — it embeds the system prompt) `session_meta` line.
    static let headWindow = 512 * 1024

    /// The thread's `session_meta` — always the FIRST line of a rollout. Read once per thread (cached by
    /// the store); the catalog carries the same facts, so this is the fallback when the DB is unreadable.
    static func readMeta(path: String) -> CodexRolloutMeta? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: headWindow), !data.isEmpty else { return nil }
        guard let nl = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }   // meta line longer than the window → skip
        let line = String(decoding: data[data.startIndex..<nl], as: UTF8.self)
        guard let obj = decode(line), obj["type"] as? String == "session_meta",
              let p = obj["payload"] as? [String: Any] else { return nil }
        let git = p["git"] as? [String: Any]
        // Sub-agent parentage lives in a `{"subagent":{"thread_spawn":{…}}}` object — under `source` on
        // 0.15x rollouts (with `thread_source` = "subagent"), under `thread_source` on others. Accept both.
        var parent: String? = nil, nick: String? = nil
        var tsrc: String? = p["thread_source"] as? String
        for candidate in [p["thread_source"], p["source"]] {
            guard let d = candidate as? [String: Any] else { continue }
            if tsrc == nil { tsrc = d.keys.first }
            if let sub = d["subagent"] as? [String: Any], let spawn = sub["thread_spawn"] as? [String: Any] {
                parent = (spawn["parent_thread_id"] as? String)?.lowercased()
                nick = (spawn["agent_nickname"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (spawn["agent_path"] as? String).map { ($0 as NSString).lastPathComponent }
            }
        }
        return CodexRolloutMeta(
            // `id` is THIS thread; `session_id` is the ROOT session (differs for sub-agent threads).
            threadId: ((p["id"] ?? p["session_id"]) as? String)?.lowercased(),
            cwd: str(p["cwd"]),
            originator: str(p["originator"]),
            source: str(p["source"]),
            cliVersion: str(p["cli_version"]),
            gitBranch: str(git?["branch"]),
            threadSource: tsrc,
            parentThreadId: parent,
            agentNickname: nick)
    }

    /// Parse the tail window of a rollout (line-aware, see `TailReader`).
    static func tail(path: String, window: UInt64 = TailReader.defaultWindow) -> CodexTail {
        parseTail(lines: TailReader.tailLines(path: path, window: window))
    }

    static func parseTail(lines: [String]) -> CodexTail {
        var t = CodexTail()
        var openTurns: [String: Date] = [:]        // turn_id → started (insertion order kept via array below)
        var openOrder: [String] = []
        for line in lines {
            guard let obj = decode(line) else { continue }
            t.linesParsed += 1
            let ts = (obj["timestamp"] as? String).flatMap(ISOTime.parse)
            if let ts { t.lastActivity = max(t.lastActivity ?? ts, ts) }
            let type = obj["type"] as? String ?? "?"
            let payload = obj["payload"] as? [String: Any] ?? [:]
            switch type {
            case "event_msg":
                let pt = payload["type"] as? String ?? "?"
                if pt != "thread_settings_applied" { t.workLines += 1 }
                switch pt {
                case "task_started":
                    let turn = payload["turn_id"] as? String ?? "?"
                    t.turnsSeen += 1
                    if turn.hasPrefix("external-import") { t.importMarkerSeen = true } else { t.nativeTurnSeen = true }
                    openTurns[turn] = ts ?? Date.distantPast
                    openOrder.append(turn)
                    if let w = payload["model_context_window"] as? NSNumber, w.intValue > 0 { t.modelContextWindow = w.intValue }
                case "task_complete", "turn_aborted":
                    let turn = payload["turn_id"] as? String ?? "?"
                    openTurns.removeValue(forKey: turn)
                    openOrder.removeAll { $0 == turn }
                    t.lastTurnEndedAt = ts ?? t.lastTurnEndedAt
                    t.lastTurnEnd = pt
                case "token_count":
                    applyTokenCount(payload, to: &t, at: ts)
                case "user_message":
                    if let m = str(payload["message"]), !m.hasPrefix("[external unsupported block") {
                        t.lastUserMessage = m
                    }
                case "agent_message":
                    if str(payload["message"]) == "<EXTERNAL SESSION IMPORTED>" { t.importMarkerSeen = true }
                case "item_completed", "thread_settings_applied", "agent_reasoning", "agent_reasoning_raw_content",
                     "patch_apply_end", "context_compacted", "mcp_tool_call_end", "web_search_end",
                     "image_generation_end", "subagent_activity", "exec_command_end", "compaction":
                    break
                default:
                    t.unknownTypes["event_msg/\(pt)", default: 0] += 1
                }
            case "response_item", "token_usage_record", "compacted", "world_state":
                t.workLines += 1
            case "turn_context":
                t.workLines += 1
                if let c = str(payload["cwd"]) { t.cwd = c }
                if let ap = payload["approval_policy"] { t.approvalPolicy = describePolicy(ap) }
                if let roots = payload["workspace_roots"] as? [String], !roots.isEmpty { t.workspaceRoots = roots }
            case "session_meta", "inter_agent_communication", "inter_agent_communication_metadata",
                 "security_risk_score", "retained_context", "realtime_item":
                break
            default:
                t.unknownTypes[type, default: 0] += 1
            }
        }
        if let last = openOrder.last {
            t.openTurnId = last
            if let d = openTurns[last], d != .distantPast { t.openTurnStartedAt = d }
        }
        return t
    }

    /// Working / done for an already-parsed tail. `lockHeld` is the writer-lock state (nil = unknown):
    ///  - an open turn with the lock held, or recent activity, is `working`;
    ///  - an open turn whose process is GONE (lock free) and that has been silent past `activeWindow` is a
    ///    crashed/killed turn — `done`, never a yellow pinned until `staleWindow`;
    ///  - no open turn → `done`; older than `staleWindow` → `stale` (the caller may still surface a
    ///    lock-held thread the user has open).
    static func state(of t: CodexTail, now: Date, lockHeld: Bool?,
                      activeWindow: TimeInterval = Tuning.activeWindow,
                      staleWindow: TimeInterval = Tuning.staleWindow) -> SessionState {
        guard let last = t.lastActivity else { return .stale }
        let age = now.timeIntervalSince(last)
        if age > staleWindow { return .stale }
        if t.openTurnId != nil {
            if lockHeld == false, age > activeWindow { return .done }
            return .working
        }
        // No turn boundary in the window at all, yet fresh turn work: a long agentic turn whose
        // `task_started` scrolled past the tail window. Codex writes nothing while idle, so recent work
        // lines with no `task_complete` after them mean the turn is still running.
        if !t.sawTurnBoundary, t.workLines > 0, age <= activeWindow { return .working }
        return .done
    }

    // MARK: - Helpers

    private static func applyTokenCount(_ payload: [String: Any], to t: inout CodexTail, at ts: Date?) {
        if let info = payload["info"] as? [String: Any] {
            if let w = info["model_context_window"] as? NSNumber, w.intValue > 0 { t.modelContextWindow = w.intValue }
            if let last = info["last_token_usage"] as? [String: Any] {
                let total = (last["total_tokens"] as? NSNumber)?.intValue ?? 0
                let reasoning = (last["reasoning_output_tokens"] as? NSNumber)?.intValue ?? 0
                let used = max(0, total - reasoning)
                if used > 0, let window = t.modelContextWindow, window > 0 {
                    t.context = ContextInfo(usedPercent: Double(used) / Double(window) * 100,
                                            sizeTokens: window, inputTokens: used)
                }
            }
        }
        if let rl = payload["rate_limits"] as? [String: Any] {
            func window(_ v: Any?) -> RateLimitInfo.Window? {
                guard let d = v as? [String: Any], let pct = (d["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                let mins = (d["window_minutes"] as? NSNumber)?.intValue
                let resets = (d["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                return RateLimitInfo.Window(usedPercent: pct, windowMinutes: mins, resetsAt: resets)
            }
            let p = window(rl["primary"]), s = window(rl["secondary"])
            if p != nil || s != nil {
                t.rateLimits = RateLimitInfo(primary: p, secondary: s, observedAt: ts ?? Date())
            }
        }
    }

    /// `approval_policy` is a string (`never` / `on-request`) or an object (`{"granular": {…}}`).
    private static func describePolicy(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let d = v as? [String: Any], let k = d.keys.first { return k }
        return "?"
    }

    private static func str(_ v: Any?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func decode(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
