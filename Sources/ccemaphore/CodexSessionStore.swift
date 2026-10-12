import Foundation

/// Owns all Codex thread state (mode A for Codex — nothing installed, read-only). The Codex twin of
/// `SessionStore`: an `actor`, file IO off the main thread, immutable `[SessionInfo]` snapshots out.
///
/// Three local sources are joined per thread id (see memory/codex-integration-research):
///  - the rollout TAIL (`CodexRolloutParser`) → working / done / interrupted, context %, rate limits;
///  - the SQLite catalog (`CodexIndex`) → titles, cwd, archive flag, projects, sub-agent parentage;
///  - the writer LOCK (`CodexPaths.isWriterLockHeld`) → "loaded in a live Codex process", the analogue
///    of Claude's owner-pid liveness: a thread whose lock is released and whose turn is over drops off
///    the light at once, like a closed Claude window.
///
/// Sub-agent threads (spawned by a parent via `thread_spawn`) are never sessions of their own: they fold
/// into the parent as `ChildAgent`s (the expandable row) and keep the parent `working` while they run.
/// Threads ChatGPT.app created by IMPORTING a Claude Code session are mirrors of chats we already show
/// from `~/.claude/projects`: hidden entirely unless the user continued them in Codex, in which case they
/// stay badged as Claude (`origin = .claude`) per the product decision.
actor CodexSessionStore {
    private struct Record {
        let id: String
        var path: String
        var meta: CodexRolloutMeta?
        var tail: CodexTail
        var row: CodexThreadRow?
        var lockHeld: Bool?
        /// A native Codex turn was observed in THIS thread at some point. Sticky: the tail only sees the
        /// last 512 KB, so a long turn whose `task_started` scrolled out would otherwise re-hide a
        /// continued import mid-work.
        var nativeTurnSeen = false
    }

    private let activeWindow: TimeInterval
    private let staleWindow: TimeInterval
    private var records: [String: Record] = [:]
    private var rows: [String: CodexThreadRow] = [:]
    private var projects: [CodexProject] = []
    private var importedIds: Set<String> = []
    private var lastCatalogRefresh: Date = .distantPast
    /// How often the catalog (SQLite) is re-read on the tick path. FSEvents on the rollout tree is the
    /// fast path for state; the catalog only feeds titles / archive / parentage, which change slowly.
    private let catalogRefreshInterval: TimeInterval = 30

    init(activeWindow: TimeInterval = Tuning.activeWindow, staleWindow: TimeInterval = Tuning.staleWindow) {
        self.activeWindow = activeWindow
        self.staleWindow = staleWindow
    }

    /// Projects from ChatGPT.app's sidebar (for product grouping). Refreshed with the catalog.
    var knownProjects: [CodexProject] { projects }

    // MARK: - Ingest

    /// Full (re)scan: refresh the catalog + import ledger + locks, then (re)read every candidate thread's
    /// tail. Candidates = catalog rows touched within `staleWindow` ∪ rollouts written in the last days
    /// (a brand-new thread the catalog hasn't indexed yet) ∪ every thread whose writer lock is held (open
    /// in the app, however old). Archived rows are dropped.
    func rescan(now: Date) -> [SessionInfo] {
        refreshCatalog(now: now, force: true)
        var candidates: [String: String] = [:]   // id → rollout path
        for (id, row) in rows where !row.archived && now.timeIntervalSince(row.updatedAt) <= staleWindow {
            candidates[id] = resolvePath(row.rolloutPath)
        }
        for path in CodexPaths.enumerateRollouts(now: now) {
            if case .thread(let id) = CodexPaths.classify(path), candidates[id] == nil, rows[id]?.archived != true {
                candidates[id] = path
            }
        }
        let held = CodexPaths.heldWriterLocks()
        // A held lock on a thread the recency window doesn't cover (a week-old thread reopened from the
        // sidebar, no new rollout line yet) — fetch its row by id, the catalog refresh only knows
        // recent ∪ tracked threads.
        let unknownHeld = held.filter { candidates[$0] == nil && rows[$0] == nil }
        if !unknownHeld.isEmpty, let extra = CodexIndex.threads(ids: unknownHeld) {
            for r in extra { rows[r.id] = r }
        }
        for id in held where candidates[id] == nil {
            if let row = rows[id], !row.archived { candidates[id] = resolvePath(row.rolloutPath) }
        }
        // Threads we already track stay candidates while their file exists (an older thread whose day
        // folder is outside the walk, during a moment the catalog is unreadable) — `snapshot` ages them out.
        for (id, rec) in records where candidates[id] == nil && FileManager.default.fileExists(atPath: rec.path) {
            candidates[id] = rec.path
        }
        records = records.filter { candidates[$0.key] != nil }
        for (id, path) in candidates { read(id: id, path: path, lockHeld: held.contains(id)) }
        return snapshot(now: now)
    }

    /// FSEvents batch over the rollout tree (and the lock dir): re-read only the touched threads.
    func ingest(paths: [String], now: Date) -> [SessionInfo] {
        refreshCatalog(now: now, force: false)
        var touched = false
        for path in Set(paths) {
            if case .thread(let id) = CodexPaths.classify(path) {
                guard rows[id]?.archived != true else { continue }
                read(id: id, path: path, lockHeld: CodexPaths.isWriterLockHeld(threadId: id))
                touched = true
            } else if path.hasPrefix(CodexPaths.writerLocksDir) {
                // A lock file appeared/changed: the thread was (re)opened — make sure it's a candidate.
                let name = (path as NSString).lastPathComponent
                guard name.hasSuffix(".lock") else { continue }
                let id = String(name.dropLast(".lock".count)).lowercased()
                guard UUID(uuidString: id) != nil, records[id] == nil else { continue }
                // Ask the catalog for THIS id (a reopened old thread is outside the recency window a
                // full refresh covers — and a full refresh per lock event would be a pointless DB read).
                if rows[id] == nil, let extra = CodexIndex.threads(ids: [id]) {
                    for r in extra { rows[r.id] = r }
                }
                if let row = rows[id], !row.archived {
                    read(id: id, path: resolvePath(row.rolloutPath), lockHeld: CodexPaths.isWriterLockHeld(threadId: id))
                    touched = true
                }
            }
        }
        if !touched { refreshLocks() }
        return snapshot(now: now)
    }

    /// Time passes (the 5 s tick): re-check locks (cheap), re-derive states, age things out.
    func reevaluate(now: Date) -> [SessionInfo] {
        refreshCatalog(now: now, force: false)
        refreshLocks()
        return snapshot(now: now)
    }

    // MARK: - Reading

    private func read(id: String, path: String, lockHeld: Bool?) {
        let tail = CodexRolloutParser.tail(path: path)
        guard tail.linesParsed > 0 else { return }
        var rec = records[id] ?? Record(id: id, path: path, meta: nil, tail: tail, row: rows[id], lockHeld: lockHeld)
        rec.path = path
        rec.tail = tail
        rec.row = rows[id]
        rec.lockHeld = lockHeld
        rec.nativeTurnSeen = rec.nativeTurnSeen || tail.nativeTurnSeen
        if rec.meta == nil { rec.meta = CodexRolloutParser.readMeta(path: path) }
        records[id] = rec
    }

    /// Re-probe the writer locks of TRACKED threads only (a pure `F_GETLK` query, see
    /// `CodexPaths.isWriterLockHeld`): a handful of files per tick, never the whole lock dir (that happens
    /// only in `rescan`). nil (no lock file) is preserved so age-based liveness stays in charge.
    private func refreshLocks() {
        for id in records.keys {
            records[id]?.lockHeld = CodexPaths.isWriterLockHeld(threadId: id)
        }
    }

    private func refreshCatalog(now: Date, force: Bool) {
        guard force || now.timeIntervalSince(lastCatalogRefresh) >= catalogRefreshInterval else { return }
        lastCatalogRefresh = now
        // A failed read (nil) keeps the previous snapshot: titles/parentage going blank for a tick would be
        // worse than being 30 s stale, and the rollout files still drive state meanwhile.
        guard let recent = CodexIndex.threads(updatedSince: now.addingTimeInterval(-staleWindow * 48)) else {
            Log.codex.debug("catalog refresh skipped (DB unreadable) — keeping \(rows.count) cached row(s)")
            return
        }
        var m: [String: CodexThreadRow] = [:]
        for r in recent { m[r.id] = r }
        // Tracked threads can be arbitrarily old (opened from the sidebar) — fetch their rows explicitly.
        let tracked = Set(records.keys).subtracting(m.keys)
        for r in CodexIndex.threads(ids: tracked) ?? [] { m[r.id] = r }
        rows = m
        if let p = CodexIndex.projects() { projects = p }
        importedIds = CodexPaths.importedThreadIds()
        for id in records.keys { records[id]?.row = m[id] }
    }

    /// The catalog stores rollout paths absolute; tolerate a relocated `CODEX_HOME` by re-rooting a path
    /// that no longer exists under the current sessions root.
    private func resolvePath(_ p: String) -> String {
        if FileManager.default.fileExists(atPath: p) { return p }
        if let r = p.range(of: "/sessions/") {
            let rel = String(p[r.upperBound...])
            return (CodexPaths.sessionsRoot as NSString).appendingPathComponent(rel)
        }
        return p
    }

    // MARK: - Snapshot

    private func snapshot(now: Date) -> [SessionInfo] {
        // Sub-agent threads → children of their parent (by catalog parentage, else the rollout's own meta).
        var childrenByParent: [String: [(Record, String?)]] = [:]
        var parents: [Record] = []
        for rec in records.values {
            if let parent = rec.row?.parentThreadId ?? rec.meta?.parentThreadId {
                childrenByParent[parent, default: []].append((rec, rec.row?.agentNickname ?? rec.meta?.agentNickname))
            } else if rec.row?.isSubagent == true || rec.meta?.threadSource == "subagent" {
                continue   // parent-less helper thread (guardian etc.) — never a chat
            } else {
                parents.append(rec)
            }
        }

        var infos: [SessionInfo] = []
        for rec in parents {
            let isImport = importedIds.contains(rec.id) || rec.tail.importMarkerSeen
            if isImport && !rec.nativeTurnSeen { continue }   // a pure mirror of a Claude chat → hidden
            // No timestamp anywhere (format drift + catalog miss) → nothing to age by → not listed, rather
            // than a row pinned at "0s" forever.
            guard var lastActivity = rec.tail.lastActivity ?? rec.row?.updatedAt else { continue }
            var state = CodexRolloutParser.state(of: rec.tail, now: now, lockHeld: rec.lockHeld,
                                                 activeWindow: activeWindow, staleWindow: staleWindow)

            var children: [ChildAgent] = []
            for (child, nick) in childrenByParent[rec.id] ?? [] {
                let cs = CodexRolloutParser.state(of: child.tail, now: now, lockHeld: child.lockHeld,
                                                  activeWindow: activeWindow, staleWindow: staleWindow)
                guard cs != .stale else { continue }
                let cl = child.tail.lastActivity ?? now
                children.append(ChildAgent(id: SessionInfo.codexID(threadId: child.id),
                                           name: nick ?? child.row?.displayTitle ?? String(child.id.prefix(8)),
                                           kind: .codexSubagent, state: cs, lastActivity: cl,
                                           title: child.row?.displayTitle))
                // A running child keeps the parent working (the same fold as Claude's Task sub-agents).
                if cs == .working, now.timeIntervalSince(cl) <= Tuning.subagentGrace {
                    state = .working
                    lastActivity = max(lastActivity, cl)
                }
            }
            // A thread the user still has open stays listed (as done) even past the recency window, the
            // way a resumed-but-idle Claude desktop session does; a closed, finished thread drops at once.
            if state == .stale {
                guard rec.lockHeld == true else { continue }
                state = .done
            }
            if state == .done, rec.lockHeld == false,
               now.timeIntervalSince(lastActivity) > activeWindow { continue }

            let cwd = rec.row?.cwd.nonEmpty ?? rec.tail.cwd ?? rec.meta?.cwd ?? rec.tail.workspaceRoots.first
            let project = cwd.map { ($0 as NSString).lastPathComponent }
                ?? rec.row?.displayTitle ?? "Codex"
            let title = rec.row?.displayTitle ?? rec.tail.lastUserMessage.map { truncate($0) }
            var info = SessionInfo(
                id: SessionInfo.codexID(threadId: rec.id),
                project: project,
                cwd: cwd,
                gitBranch: rec.row?.gitBranch ?? rec.meta?.gitBranch,
                title: title,
                state: state,
                lastActivity: lastActivity,
                context: rec.tail.context)
            info.agent = .codex
            info.origin = isImport ? .claude : .codex
            // The rollout's own originator first, the catalog's as the fallback (both nil-able, so an
            // unlisted originator in one source still lets the other decide).
            info.host = rec.meta?.host ?? SessionHost.fromCodexOriginator(rec.row?.originator) ?? .unknown
            info.hostBundleId = info.host == .codexApp ? DeepLinker.codexAppBundleId : nil
            info.children = children.sorted { $0.lastActivity > $1.lastActivity }
            info.rateLimits = rec.tail.rateLimits
            // The catalog's running `tokens_used` is the per-thread figure available without ccusage; the
            // engine overlays ccusage's priced total (ccusage ≥ 20 reads Codex rollouts too) when it has
            // one. Cost stays 0 here — the row shows tokens instead of "$0.00" in that case.
            if let used = rec.row?.tokensUsed, used > 0 {
                info.tokens = TokenUsage(totalTokens: used)
            }
            infos.append(info)
        }
        return sortedForDisplay(infos)
    }

    private func truncate(_ s: String, _ max: Int = 60) -> String {
        let one = s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? s
        return one.count <= max ? one : String(one.prefix(max)) + "…"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
