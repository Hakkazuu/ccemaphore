import Foundation

/// Lenient reader for a Codex rollout transcript (`rollout-*.jsonl`). One JSON object per line:
/// `{"timestamp": ISO-8601, "ordinal"?: n, "type": …, "payload": {…}}`. Only the handful of event
/// types that carry state are interpreted; everything else is counted and ignored. Verified on
/// codex-cli 0.153–0.163 rollouts (see memory/codex-integration-research). Honest limits: Codex does NOT
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
    /// A sub-agent's task path (`/root/analysis_rag`) — its parent's name for the job. The task itself is
    /// encrypted in the rollout, so this is the only plain "what it's for" Codex records.
    let agentPath: String?
    /// Not a user chat: a spawned sub-agent, or a parent-less helper such as a guardian review
    /// (`source: {"subagent":{"other":"guardian"}}`, `thread_source: "guardian_review"`). Mirrors
    /// `CodexThreadRow.isSubagent` for a thread the catalog hasn't indexed yet: without it a fresh guardian
    /// rollout showed as a working chat of its own until the next catalog refresh.
    let isSubagent: Bool
    /// `subagent_history_start_ordinal`: a forked sub-agent rollout copies its parent's history in first;
    /// lines below this ordinal are that copy (see `CodexTail.historyStartOrdinal`).
    let historyStartOrdinal: Int?

    /// Where the thread runs, from `originator` (shared table: `SessionHost.fromCodexOriginator`). nil
    /// when the rollout doesn't say, so the catalog's originator can decide instead.
    var host: SessionHost? { SessionHost.fromCodexOriginator(originator) }
}

/// What a rollout says right now: its tail window, plus every line appended since (`readMore`).
struct CodexTail: Sendable {
    /// Timestamp of the last line (any persisted event counts as activity — Codex writes nothing idle).
    var lastActivity: Date? = nil
    /// The `task_started` turn not yet closed by `task_complete` / `turn_aborted` ⇒ a turn is running. A
    /// thread runs one turn at a time (no overlap in any 0.162–0.163 rollout once inherited history is
    /// skipped), so a newer `task_started` replaces an older unclosed one — such as the parent's running
    /// turn that a forked sub-agent rollout copies in, which its own file never closes.
    var openTurn: (id: String, startedAt: Date?)? = nil
    var openTurnId: String? { openTurn?.id }
    var openTurnStartedAt: Date? { openTurn?.startedAt }
    /// `subagent_history_start_ordinal` from the thread's own `session_meta`: lines with a lower `ordinal`
    /// are the parent's history copied into a forked sub-agent rollout, not this thread's activity.
    var historyStartOrdinal: Int? = nil
    /// Who Codex routes this thread's approval requests to (`approvals_reviewer` from the latest
    /// `thread_settings_applied` / `turn_context`): `user`, or `auto_review` (legacy `guardian_subagent`),
    /// where a guardian sub-agent decides alone and nobody is asked. nil: not seen yet.
    var approvalsReviewer: String? = nil
    /// The user answers this thread's approval prompts (Codex's default when nothing says otherwise).
    var approvalsGoToUser: Bool { !["auto_review", "guardian_subagent"].contains(approvalsReviewer ?? "user") }
    /// The thread's latest action (`AgentAction.codex`), for its sub-agent row.
    var lastAction: AgentAction? = nil
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
        var parent: String? = nil, nick: String? = nil, agentPath: String? = nil
        var tsrc: String? = p["thread_source"] as? String
        var subagentSource = false
        for candidate in [p["thread_source"], p["source"]] {
            guard let d = candidate as? [String: Any] else { continue }
            if tsrc == nil { tsrc = d.keys.first }
            if d["subagent"] != nil { subagentSource = true }
            if let sub = d["subagent"] as? [String: Any], let spawn = sub["thread_spawn"] as? [String: Any] {
                parent = (spawn["parent_thread_id"] as? String)?.lowercased()
                agentPath = (spawn["agent_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
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
            agentNickname: nick,
            agentPath: agentPath ?? (p["agent_path"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isSubagent: parent != nil || subagentSource || tsrc == "subagent" || tsrc == "guardian_review",
            historyStartOrdinal: (p["subagent_history_start_ordinal"] as? NSNumber)?.intValue)
    }

    /// A rollout bigger than this is never parsed whole by `read` (the window result stands).
    static let fullReadLimit: UInt64 = 64 * 1024 * 1024

    /// First read of a rollout: the tail window, widened to the WHOLE file when the window holds no turn
    /// boundary — or holds a running turn but not who reviews its approvals. On codex-cli 0.163 single
    /// lines run to hundreds of KB (`compacted`, tool output echoed in `item_completed`), so a running
    /// turn's `task_started` (and the `thread_settings_applied` just before it) leaves the 512 KB window
    /// within a minute or two; without it `state(of:)` could only guess from the 60 s freshness of the
    /// last write. `historyStartOrdinal` (from `readMeta`) lets a window that starts mid-file still skip a
    /// forked sub-agent's copied history. Returns the parsed tail, where `readMore` continues from, and
    /// the file size that read saw. nil ⇒ unreadable.
    static func read(path: String, historyStartOrdinal: Int? = nil) -> (tail: CodexTail, resumeAt: UInt64, size: UInt64)? {
        var seed = CodexTail()
        seed.historyStartOrdinal = historyStartOrdinal
        guard let r = TailReader.readResumable(path: path, from: nil) else { return nil }
        let t = parseTail(lines: r.lines, continuing: seed)
        let incomplete = !t.sawTurnBoundary || (t.openTurnId != nil && t.approvalsReviewer == nil)
        if incomplete, r.size > TailReader.defaultWindow, r.size <= fullReadLimit,
           let all = TailReader.readResumable(path: path, from: 0) {
            return (parseTail(lines: all.lines, continuing: seed), all.resumeAt, all.size)
        }
        return (t, r.resumeAt, r.size)
    }

    /// Continue a previous `read`: parse only the lines appended since `resumeAt` into `prior`, so a turn
    /// boundary, once seen, is never lost however much the turn writes after it. nil ⇒ the file shrank
    /// (replaced/truncated) or is unreadable — start over with `read`.
    static func readMore(path: String, after prior: CodexTail,
                         from resumeAt: UInt64) -> (tail: CodexTail, resumeAt: UInt64, size: UInt64)? {
        guard let r = TailReader.readResumable(path: path, from: resumeAt) else { return nil }
        return (parseTail(lines: r.lines, continuing: prior), r.resumeAt, r.size)
    }

    static func parseTail(lines: [String], continuing prior: CodexTail = CodexTail()) -> CodexTail {
        var t = prior
        for line in lines {
            guard let obj = decode(line) else { continue }
            t.linesParsed += 1
            let type = obj["type"] as? String ?? "?"
            let payload = obj["payload"] as? [String: Any] ?? [:]
            if t.linesParsed == 1, type == "session_meta", t.historyStartOrdinal == nil {
                // A file's first line is the thread's OWN meta (a fork's copied parent meta comes after it).
                // A value seeded from `readMeta` wins: a window starting mid-file has no own meta in it.
                t.historyStartOrdinal = (payload["subagent_history_start_ordinal"] as? NSNumber)?.intValue
            }
            if let start = t.historyStartOrdinal, let ord = (obj["ordinal"] as? NSNumber)?.intValue, ord < start { continue }
            let ts = (obj["timestamp"] as? String).flatMap(ISOTime.parse)
            if let ts { t.lastActivity = max(t.lastActivity ?? ts, ts) }
            switch type {
            case "event_msg":
                let pt = payload["type"] as? String ?? "?"
                if pt != "thread_settings_applied" { t.workLines += 1 }
                if pt == "thread_settings_applied",
                   let reviewer = (payload["thread_settings"] as? [String: Any])?["approvals_reviewer"] as? String {
                    t.approvalsReviewer = reviewer
                }
                switch pt {
                case "task_started":
                    let turn = payload["turn_id"] as? String ?? "?"
                    t.turnsSeen += 1
                    if turn.hasPrefix("external-import") { t.importMarkerSeen = true } else { t.nativeTurnSeen = true }
                    t.openTurn = (turn, ts)
                    if let w = payload["model_context_window"] as? NSNumber, w.intValue > 0 { t.modelContextWindow = w.intValue }
                case "task_complete", "turn_aborted":
                    let turn = payload["turn_id"] as? String ?? "?"
                    if t.openTurn?.id == turn { t.openTurn = nil }
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
                case "item_completed":
                    if let item = payload["item"] as? [String: Any], let action = AgentAction.codex(item: item) {
                        t.lastAction = action
                    }
                case "thread_settings_applied", "agent_reasoning", "agent_reasoning_raw_content",
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
                if let reviewer = payload["approvals_reviewer"] as? String { t.approvalsReviewer = reviewer }
                if let roots = payload["workspace_roots"] as? [String], !roots.isEmpty { t.workspaceRoots = roots }
            case "session_meta", "inter_agent_communication", "inter_agent_communication_metadata",
                 "security_risk_score", "retained_context", "realtime_item":
                break
            default:
                t.unknownTypes[type, default: 0] += 1
            }
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
