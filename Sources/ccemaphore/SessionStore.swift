import Foundation

/// Owns all session state and applies the per-session working/done/waiting heuristic. An `actor` so
/// file IO and mutable maps are serialized off the main thread; the UI (`StateEngine`, @MainActor)
/// only ever receives immutable `[SessionInfo]` snapshots.
///
/// Heuristic (mode A, file-watch only), distilled from ~90 real transcripts + adversarial review:
///  - LIVE iff the last *real* line (type assistant/user with a timestamp) is within STALE_WINDOW.
///    Computed from the timestamp, never mtime — meta-record rewrites (ai-title/last-prompt) bump
///    mtime with no real activity (files seen "24 min fresh" but 3–4 days idle).
///  - WORKING iff LIVE, last real line is within ACTIVE_WINDOW, and the tail is mid-turn
///    (assistant tool_use / unfinalized stream, a just-arrived tool_result, a fresh user prompt,
///    or a system api_error retry).
///  - WAITING is NOT reliably detectable from files (the CLI writes nothing while a permission
///    prompt is on screen). Best-effort: a cooled, still-live tail ending in an UNPAIRED tool_use.
///    This is byte-identical to a slow-but-working tool — precise waiting needs the hooks mode (B).
///  - Sub-agent transcripts never count as sessions; an active sub-agent marks its PARENT working.
actor SessionStore {
    private let activeWindow: TimeInterval
    private let staleWindow: TimeInterval

    private var records: [String: SessionRecord] = [:]      // sessionId -> last classified record
    private var subagentActivity: [String: Date] = [:]      // parentId -> last time a Task sub-agent was active
    // sessionId -> (workflowId -> last fan-out-agent write). A workflow is "live" (keeps the chat
    // working) from its first agent until its completion record lands or it ages past workflowLiveWindow.
    private var liveWorkflows: [String: [String: Date]] = [:]

    private let isoMillis: ISO8601DateFormatter
    private let isoPlain: ISO8601DateFormatter

    init(activeWindow: TimeInterval = Tuning.activeWindow, staleWindow: TimeInterval = Tuning.staleWindow) {
        self.activeWindow = activeWindow
        self.staleWindow = staleWindow
        let ms = ISO8601DateFormatter()
        ms.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoMillis = ms
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        self.isoPlain = plain
    }

    // MARK: - Ingest

    func ingest(paths: [String], now: Date) -> [SessionInfo] {
        for path in Set(paths) {
            switch SessionPath.classify(path) {
            case .session(let id, let slug):
                classifySession(id: id, slug: slug, path: path, now: now)
            case .subagent(let parentId, _, let workflowId):
                if subagentIsActive(path: path, now: now) {
                    if let workflowId {
                        // Workflow fan-out agent: track per-workflow so the run's completion record can
                        // retire it precisely, rather than leaning on the coarse sub-agent grace.
                        liveWorkflows[parentId, default: [:]][workflowId] = now
                    } else {
                        subagentActivity[parentId] = now
                    }
                }
            case .workflowRecord(let sessionId, let workflowId):
                // The run finished (wf_*.json is written once, at completion) — retire it so it stops
                // holding the chat `working`, collapsing the post-workflow yellow tail at the exact edge.
                liveWorkflows[sessionId]?[workflowId] = nil
                if liveWorkflows[sessionId]?.isEmpty == true { liveWorkflows[sessionId] = nil }
            case .ignored:
                break
            }
        }
        pruneLiveWorkflows(now: now)
        pruneStale(now: now)
        return snapshot(now: now)
    }

    /// Re-derive states from stored records as time passes (no file IO) so a session crosses the
    /// ACTIVE/STALE boundaries even when nothing new is written.
    func reevaluate(now: Date) -> [SessionInfo] {
        pruneStale(now: now)
        return snapshot(now: now)
    }

    // MARK: - Snapshot

    private func snapshot(now: Date) -> [SessionInfo] {
        var ids = Set(records.keys)
        for (parentId, ts) in subagentActivity where now.timeIntervalSince(ts) <= staleWindow {
            ids.insert(parentId)
        }
        // A chat whose only live signal is a running workflow (own tail long quiet, no Task sub-agents)
        // must still surface.
        for parentId in liveWorkflows.keys where liveWorkflowActivity(parentId, now: now) != nil {
            ids.insert(parentId)
        }

        var infos: [SessionInfo] = []
        for id in ids {
            let rec = records[id]
            var resolvedState: SessionState = rec.map { state(of: $0, now: now) } ?? .stale

            // Fold work into the parent (D7) so the chat reads `working` while it's actually busy, even
            // when its own tail looks like a stalled tool_use:
            //  - a fresh Task sub-agent, grace-bounded (sub-agents fall quiet mid-task); and
            //  - a still-running workflow — live from its first fan-out agent until its completion record
            //    lands. This is what bridges a workflow's quiet stretches without flipping to "done", and
            //    (because the record retires it) lets a finished workflow settle at the exact edge instead
            //    of riding out a fixed grace.
            if let ts = subagentActivity[id], now.timeIntervalSince(ts) <= Tuning.subagentGrace {
                resolvedState = .working
            }
            if liveWorkflowActivity(id, now: now) != nil {
                resolvedState = .working
            }

            guard resolvedState != .stale else { continue }
            infos.append(SessionInfo(
                id: id,
                project: rec?.project ?? "—",
                cwd: rec?.cwd,
                gitBranch: rec?.gitBranch,
                title: rec?.title,
                state: resolvedState,
                lastActivity: rec?.lastRealTimestamp ?? liveWorkflowActivity(id, now: now) ?? subagentActivity[id] ?? now,
                context: rec?.context
            ))
        }
        return sortedForDisplay(infos)
    }

    /// Freshest still-live workflow write for a session, or nil if none within the live window. A
    /// workflow is live from its first fan-out agent until its completion record retires it; the window
    /// only backstops a run hard-killed without a record, so it can't pin the chat forever.
    private func liveWorkflowActivity(_ id: String, now: Date) -> Date? {
        guard let wfs = liveWorkflows[id] else { return nil }
        return wfs.values.filter { now.timeIntervalSince($0) <= Tuning.workflowLiveWindow }.max()
    }

    /// Forget workflows that aged past the live window (hard-killed, no completion record), bounding the
    /// map and letting the chat settle. Graceful finishes are removed directly by their record in ingest.
    private func pruneLiveWorkflows(now: Date) {
        for (sid, wfs) in liveWorkflows {
            let live = wfs.filter { now.timeIntervalSince($0.value) <= Tuning.workflowLiveWindow }
            if live.isEmpty { liveWorkflows.removeValue(forKey: sid) }
            else if live.count != wfs.count { liveWorkflows[sid] = live }
        }
    }

    /// Evict long-dead entries so `records`/`subagentActivity` don't grow unbounded over the app's
    /// lifetime — Claude Code mints a fresh UUID per chat, so without this every chat ever observed
    /// would live in the maps forever (and be walked on every 5 s tick). Behaviour-preserving: it only
    /// drops what `snapshot` already hides.
    ///  - `subagentActivity`: anything past `staleWindow` (the widest window that reads it, line ~82).
    ///  - `records`: only once the chat is TRULY gone from the UI — its own tail is stale AND no live
    ///    sub-agent/workflow is still forcing it `working` (those paths read the record's
    ///    cwd/branch/title/context for display, so a chat kept alive by them must keep its record).
    private func pruneStale(now: Date) {
        subagentActivity = subagentActivity.filter { now.timeIntervalSince($0.value) <= staleWindow }
        records = records.filter { id, rec in
            if now.timeIntervalSince(rec.lastRealTimestamp) <= staleWindow { return true }
            if let ts = subagentActivity[id], now.timeIntervalSince(ts) <= Tuning.subagentGrace { return true }
            return liveWorkflowActivity(id, now: now) != nil
        }
    }

    private func state(of r: SessionRecord, now: Date) -> SessionState {
        let age = now.timeIntervalSince(r.lastRealTimestamp)
        if age > staleWindow { return .stale }

        // A trailing tool_result means the assistant still OWES its continuation — the turn is not
        // finished, however long it pauses to think between tool calls. A genuine end-of-turn appends
        // an assistant `end_turn` line, which becomes `.doneEndTurn` instead. So this must stay
        // `working` regardless of age (until it goes stale): letting a cooled tool_result fall through
        // to `done` was the "🟢 green while still working" bug during long thinking pauses (a "Thought
        // for 66s" exceeds the 60s activeWindow, so the tail cooled and read as finished).
        if r.lastShape == .userToolResult { return .working }

        if age <= activeWindow {
            switch r.lastShape {
            case .working, .systemRetry:
                return .working
            case .userToolResult, .doneEndTurn, .other:
                break
            }
        }

        // Cooled / settled tail.
        if r.lastShape == .doneEndTurn { return .done }
        if r.hasUnpairedToolUse { return .waiting }   // best-effort "looks like it needs the user"
        return .done
    }

    // MARK: - Classification

    private func classifySession(id: String, slug: String, path: String, now: Date) {
        let parsed = TailReader.tailLines(path: path).compactMap(LogLine.decode)
        guard !parsed.isEmpty else { return }

        // Carry forward any previously-known metadata; refresh from the freshest non-nil values.
        var project = records[id]?.project ?? SessionPath.projectName(slug: slug)
        var fullCwd = records[id]?.cwd
        var branch = records[id]?.gitBranch
        var title = records[id]?.title
        for line in parsed {
            if let cwd = line.cwd, !cwd.isEmpty {
                project = (cwd as NSString).lastPathComponent
                fullCwd = cwd
            }
            if let b = line.gitBranch, !b.isEmpty { branch = b }
            if let t = line.aiTitle, !t.isEmpty { title = t }
            else if let p = line.lastPrompt, !p.isEmpty, title == nil { title = truncate(p) }
        }

        let realLines = parsed.filter {
            ($0.type == "assistant" || $0.type == "user") && $0.timestamp != nil
        }
        guard let last = realLines.last,
              let lastTime = parseTimestamp(last.timestamp) else { return }

        var record = SessionRecord(
            id: id,
            project: project,
            cwd: fullCwd,
            gitBranch: branch,
            title: title,
            lastRealTimestamp: lastTime,
            lastShape: shape(of: last),
            hasUnpairedToolUse: hasUnpairedToolUse(parsed),
            context: contextInfo(from: parsed)
        )

        // A system api_error retry as the very last line means the agent is auto-retrying (working,
        // not waiting on a human). These lines are excluded from `realLines`, so handle them here.
        if let lastAny = parsed.last, lastAny.type == "system", lastAny.subtype == "api_error" {
            record.lastShape = .systemRetry
            if let ts = parseTimestamp(lastAny.timestamp) {
                record.lastRealTimestamp = max(record.lastRealTimestamp, ts)
            }
        }

        records[id] = record
    }

    private func subagentIsActive(path: String, now: Date) -> Bool {
        let parsed = TailReader.tailLines(path: path).compactMap(LogLine.decode)
        let real = parsed.filter {
            ($0.type == "assistant" || $0.type == "user") && $0.timestamp != nil
        }
        guard let last = real.last, let ts = parseTimestamp(last.timestamp) else { return false }
        if now.timeIntervalSince(ts) > activeWindow { return false }
        if last.type == "assistant", let sr = last.message?.stopReason,
           sr == "end_turn" || sr == "stop_sequence" { return false }
        return true
    }

    // MARK: - Tail shape & tool pairing

    private func shape(of line: LogLine) -> TailShape {
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

    /// True if the last assistant line carries a tool_use whose id has no matching tool_result after it.
    private func hasUnpairedToolUse(_ lines: [LogLine]) -> Bool {
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

    // MARK: - Helpers

    private func parseTimestamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoMillis.date(from: s) ?? isoPlain.date(from: s)
    }

    private func truncate(_ s: String, _ max: Int = 60) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }

    /// Per-chat context-window occupancy from the transcript tail. The token count is the most recent
    /// assistant turn's input + cache buckets (exactly the sum Claude Code's statusLine reported); the
    /// window SIZE isn't in the transcript, so we infer it — 1M once any turn in view exceeds 200k,
    /// else the 200k default. Approximate only for a sub-200k session on the 1M model; exact otherwise.
    private func contextInfo(from lines: [LogLine]) -> ContextInfo? {
        let totals = lines.compactMap { line -> Int? in
            guard line.type == "assistant", let u = line.message?.usage else { return nil }
            return (u.inputTokens ?? 0) + (u.cacheReadInputTokens ?? 0) + (u.cacheCreationInputTokens ?? 0)
        }
        guard let used = totals.last, used > 0 else { return nil }
        let size = (totals.max() ?? used) > 200_000 ? 1_000_000 : 200_000
        return ContextInfo(usedPercent: Double(used) / Double(size) * 100,
                           sizeTokens: size, inputTokens: used)
    }
}

/// Internal per-session record: raw signals, so `state(of:now:)` can re-derive the state on a timer
/// without re-reading files.
private struct SessionRecord {
    let id: String
    let project: String
    let cwd: String?
    let gitBranch: String?
    let title: String?
    var lastRealTimestamp: Date
    var lastShape: TailShape
    var hasUnpairedToolUse: Bool
    var context: ContextInfo?
}

private enum TailShape {
    case working          // mid-turn: assistant tool_use / unfinalized stream / fresh user prompt
    case userToolResult   // tool result just arrived; agent about to continue
    case systemRetry      // api_error auto-retry
    case doneEndTurn      // clean finish
    case other
}
