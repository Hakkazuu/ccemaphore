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
    /// parentId → childId → what we know about that sub-agent / workflow agent, for the expandable row
    /// (`SessionInfo.children`). Informational: the parent's working/done fold above stays the authority.
    private var children: [String: [String: ChildRecord]] = [:]
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
                // One tail read + decode serves both the child record and the parent's working fold.
                let parsed = TailReader.tailLines(path: path).compactMap(LogLine.decode)
                let tail = subagentTail(parsed, now: now)
                noteChild(parentId: parentId, path: path, workflowId: workflowId, tail: tail)
                if tail?.active == true {
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
            var viaChildren = false
            if let ts = subagentActivity[id], now.timeIntervalSince(ts) <= Tuning.subagentGrace {
                viaChildren = resolvedState != .working
                resolvedState = .working
            }
            if liveWorkflowActivity(id, now: now) != nil {
                viaChildren = viaChildren || resolvedState != .working
                resolvedState = .working
            }

            guard resolvedState != .stale else { continue }
            var info = SessionInfo(
                id: id,
                project: rec?.project ?? "—",
                cwd: rec?.cwd,
                gitBranch: rec?.gitBranch,
                title: rec?.title,
                state: resolvedState,
                lastActivity: rec?.lastRealTimestamp ?? liveWorkflowActivity(id, now: now) ?? subagentActivity[id] ?? now,
                context: rec?.context
            )
            info.children = childAgents(of: id, now: now)
            info.workingViaChildren = viaChildren
            infos.append(info)
        }
        return sortedForDisplay(infos)
    }

    /// The parent's sub-agents seen within `staleWindow`, freshest first. A child is `working` while its
    /// own tail is mid-turn and recent (the same test that feeds the parent's fold), else `done`.
    private func childAgents(of parentId: String, now: Date) -> [ChildAgent] {
        guard let kids = children[parentId] else { return [] }
        return kids.compactMap { id, c -> ChildAgent? in
            guard now.timeIntervalSince(c.lastActivity) <= staleWindow else { return nil }
            let working = c.active && now.timeIntervalSince(c.lastActivity) <= Tuning.subagentGrace
            return ChildAgent(id: id, name: c.name, kind: c.kind, state: working ? .working : .done,
                              lastActivity: c.lastActivity, title: c.title)
        }.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Record (or refresh) one sub-agent transcript under its parent. The child's id is the `agent-<id>`
    /// file stem; its title is the Task prompt (the transcript's first user line), read once from the file
    /// head — the parent's `Task` tool_use carries the human description, but that lives in the PARENT's
    /// transcript, not here, so the prompt's first line is the best self-contained label we have.
    private func noteChild(parentId: String, path: String, workflowId: String?, tail: (lastTs: Date, active: Bool)?) {
        guard let tail else { return }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let childId = stem.hasPrefix("agent-") ? String(stem.dropFirst("agent-".count)) : stem
        var rec = children[parentId]?[childId] ?? ChildRecord(
            name: workflowId.map { "\($0) · \(childId.prefix(6))" } ?? String(childId.prefix(8)),
            kind: workflowId == nil ? .subagent : .workflow,
            lastActivity: tail.lastTs, active: tail.active, title: nil, titleResolved: false)
        rec.lastActivity = max(rec.lastActivity, tail.lastTs)
        rec.active = tail.active
        if !rec.titleResolved {
            // One head read per child once its first line is complete: that line is the Task prompt or it
            // isn't. A file still being flushed (FSEvents fires on creation, before the large first user
            // line is fully written) is simply re-read on the next event instead of being marked resolved.
            switch Self.firstPrompt(path: path) {
            case .pending:
                break
            case .none:
                rec.titleResolved = true
            case .prompt(let p):
                rec.title = truncate(p)
                rec.titleResolved = true
            }
        }
        children[parentId, default: [:]][childId] = rec
    }

    /// (last real timestamp, is the agent mid-turn right now) for an already-decoded sub-agent tail. nil
    /// when the tail has no real line. Shared by the child record and the parent's working fold.
    private func subagentTail(_ parsed: [LogLine], now: Date) -> (lastTs: Date, active: Bool)? {
        let real = parsed.filter { ($0.type == "assistant" || $0.type == "user") && $0.timestamp != nil }
        guard let last = real.last, let ts = parseTimestamp(last.timestamp) else { return nil }
        var active = now.timeIntervalSince(ts) <= activeWindow
        if last.type == "assistant", let sr = last.message?.stopReason, sr == "end_turn" || sr == "stop_sequence" {
            active = false
        }
        return (ts, active)
    }

    /// What the head of a sub-agent transcript says about its Task prompt.
    private enum FirstLine {
        /// The first line isn't fully flushed yet — ask again on the next event.
        case pending
        /// A complete first line that is not a user prompt (or one too long to be a label).
        case none
        case prompt(String)
    }

    /// The first user line's text (the Task prompt) from the head of a sub-agent transcript.
    private static func firstPrompt(path: String) -> FirstLine {
        guard let h = FileHandle(forReadingAtPath: path) else { return .pending }
        defer { try? h.close() }
        let cap = 64 * 1024
        guard let data = try? h.read(upToCount: cap), !data.isEmpty else { return .pending }
        guard let nl = data.firstIndex(of: UInt8(ascii: "\n")) else {
            return data.count >= cap ? .none : .pending
        }
        let line = String(decoding: data[data.startIndex..<nl], as: UTF8.self)
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              obj["type"] as? String == "user",
              let msg = obj["message"] as? [String: Any] else { return .none }
        if let text = msg["content"] as? String { return .prompt(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let blocks = msg["content"] as? [[String: Any]],
           let t = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String {
            return .prompt(t.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .none
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
        children = children.compactMapValues { kids in
            let live = kids.filter { now.timeIntervalSince($0.value.lastActivity) <= staleWindow }
            return live.isEmpty ? nil : live
        }
        records = records.filter { id, rec in
            if now.timeIntervalSince(rec.lastRealTimestamp) <= staleWindow { return true }
            if let ts = subagentActivity[id], now.timeIntervalSince(ts) <= Tuning.subagentGrace { return true }
            return liveWorkflowActivity(id, now: now) != nil
        }
    }

    private func state(of r: SessionRecord, now: Date) -> SessionState {
        let age = now.timeIntervalSince(r.lastRealTimestamp)
        if age > staleWindow { return .stale }
        // Stale gate applied; the live-tail ladder is shared with the remote poller (see TailClassifier).
        return TailClassifier.classify(
            shape: r.lastShape, age: age, hasUnpaired: r.hasUnpairedToolUse, activeWindow: activeWindow)
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
            lastShape: TailClassifier.shape(of: last),
            hasUnpairedToolUse: TailClassifier.hasUnpairedToolUse(parsed),
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

/// One sub-agent / workflow agent under a parent chat (see `SessionStore.noteChild`).
private struct ChildRecord {
    var name: String
    var kind: ChildAgent.Kind
    var lastActivity: Date
    var active: Bool
    var title: String?
    var titleResolved: Bool
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
    var lastShape: TailShape          // shared enum — see TailClassifier
    var hasUnpairedToolUse: Bool
    var context: ContextInfo?
}
