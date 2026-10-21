import Foundation
import os

/// Headless diagnostics for the Codex side (`--codex-scan`, `--codex-probe`) — the "look at it with your
/// own eyes before wiring it in" step every new data source gets. No GUI, no writes.
enum CodexDiagnostic {
    /// `ccemaphore --codex-scan` — catalog stats + the session list exactly as the engine would publish it.
    static func scan() async {
        let now = Date()
        print("codex home: \(CodexPaths.home)  installed=\(CodexPaths.isInstalled)")
        print("state db:   \(CodexPaths.stateDB)  exists=\(FileManager.default.fileExists(atPath: CodexPaths.stateDB))")
        let recent = CodexIndex.threads(updatedSince: now.addingTimeInterval(-7 * 86_400)) ?? []
        let active = recent.filter { !$0.archived }
        print("catalog: \(recent.count) thread(s) touched in 7d, \(active.count) not archived, "
              + "\(active.filter(\.isSubagent).count) sub-agent")
        let projects = CodexIndex.projects() ?? []
        print("projects: \(projects.count)")
        for p in projects.prefix(12) { print("  \(p.name)  → \(p.roots.joined(separator: ", "))") }
        let held = CodexPaths.heldWriterLocks()
        print("writer locks held: \(held.count)  \(held.map { String($0.prefix(8)) }.sorted().joined(separator: " "))")
        let imported = CodexPaths.importedThreadIds()
        print("imported-from-Claude threads: \(imported.count)")

        let store = CodexSessionStore()
        let sessions = await store.rescan(now: now).sessions
        print("\nlive Codex sessions: \(sessions.count)")
        for s in sessions {
            let age = Int(now.timeIntervalSince(s.lastActivity))
            let ctx = s.context.map { "  ctx=\(Int($0.usedPercent.rounded()))%" } ?? ""
            let rl = s.rateLimits?.primary.map { "  limit=\(Int($0.usedPercent.rounded()))%" } ?? ""
            let kids = s.children.isEmpty ? "" : "  children=\(s.children.count)"
            let origin = s.originAgent == .claude ? "  origin=claude(import)" : ""
            print("  [\(s.state.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))] "
                  + "\(s.displayName)  host=\(s.host.rawValue)  age=\(age)s  id=\(SessionInfo.parseCodexID(s.id)?.prefix(8) ?? "?")"
                  + "\(ctx)\(rl)\(kids)\(origin)"
                  + (s.title.map { "\n           \"\($0)\"" } ?? ""))
            for c in s.children {
                print(Diagnostic.childLine(c, now: now))
            }
        }
    }

    /// `ccemaphore --codex-watch [seconds]` — run the Codex store the way the GUI does (a rescan, FSEvents on
    /// the sessions tree, the lock dir and the hook status dir, the `Tuning.codexPoll` growth poll and the `Tuning.stateTick`
    /// re-evaluation) and print every change of a session's state or of its sub-agents' states. Live
    /// tracking, checked without launching the app.
    static func watch(seconds: TimeInterval) async {
        setvbuf(stdout, nil, _IOLBF, 0)   // a live feed: line-buffered even into a pipe
        let store = CodexSessionStore()
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        var last: [String: String] = [:]
        // Hook records are folded in exactly as `StateEngine.render` does, so a waiting / compacting chat
        // shows here too.
        func report(_ snapshot: CodexSnapshot, _ source: String) {
            let status = StatusReader.readAll().filter { SessionInfo.parseCodexID($0.key) != nil }
            let sessions = CodexHookOverlay.apply(snapshot, status: status, now: Date())
            var seen: [String: String] = [:]
            for s in sessions {
                let kids = s.children.sorted { $0.name < $1.name }
                    .map { "\($0.headline)=\($0.state.rawValue)" }.joined(separator: " ")
                let flags = (s.waitingKind.map { " (\($0.rawValue))" } ?? "") + (s.isCompacting ? " (compacting)" : "")
                let line = "\(s.state.rawValue)\(flags)\(kids.isEmpty ? "" : "  [\(kids)]")"
                seen[s.id] = line
                if last[s.id] != line {
                    print("\(clock.string(from: Date())) \(source.padding(toLength: 4, withPad: " ", startingAt: 0)) "
                          + "\(s.displayName) (\(SessionInfo.parseCodexID(s.id)?.prefix(8) ?? "?")): \(line)")
                }
            }
            for id in last.keys where seen[id] == nil {
                print("\(clock.string(from: Date())) \(source) \(SessionInfo.parseCodexID(id)?.prefix(8) ?? "?"): left the list")
            }
            last = seen
        }
        // FSEvents batches are drained on the poll cadence (the GUI ingests them at once — same store call).
        let events = OSAllocatedUnfairLock(initialState: [String]())
        // The status dir too: a hook record re-renders at once, as `StateEngine`'s status watcher does.
        let watchers = [CodexPaths.sessionsRoot, CodexPaths.writerLocksDir, HookHandler.statusDir].map { path in
            TranscriptWatcher(path: path, onChange: { paths in events.withLock { $0 += paths } })
        }
        watchers.forEach { $0.start() }
        report(await store.rescan(now: Date()), "scan")
        let end = Date().addingTimeInterval(seconds)
        var nextTick = Date().addingTimeInterval(Tuning.stateTick)
        while Date() < end {
            try? await Task.sleep(nanoseconds: UInt64(Tuning.codexPoll * 1_000_000_000))
            let paths = events.withLock { batch in defer { batch = [] }; return batch }
            if !paths.isEmpty { report(await store.ingest(paths: paths, now: Date()), "fsev") }
            if let s = await store.poll(now: Date()) { report(s, "poll") }
            if Date() >= nextTick {
                report(await store.reevaluate(now: Date()), "tick")
                nextTick = Date().addingTimeInterval(Tuning.stateTick)
            }
        }
        watchers.forEach { $0.stop() }
    }

    /// `ccemaphore --codex-hooks-status` — install state, Codex's trust verdict per handler of ours (with
    /// the key and both hashes, so a mismatch is diagnosable at a glance), and the last hook record.
    static func hooksStatus() {
        let st = CodexHooksInstaller.status()
        print("hooks.json: \(CodexHooksInstaller.hooksPath)")
        print("trust key:  \(CodexHooksInstaller.keyPath(CodexHooksInstaller.hooksPath))")
        print("config:     \(CodexHooksInstaller.configPath)")
        print("install: \(st.install.rawValue)  feature hooks: \(st.featureEnabled ? "on" : "OFF")  summary: \(st.summary)")
        for e in st.entries {
            let label = e.key.split(separator: ":").suffix(3).joined(separator: ":")
            print("  [\(e.trust.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))] \(label)\(e.enabled ? "" : "  (disabled in Codex)")")
            print("      current: \(e.currentHash)")
            print("      trusted: \(e.trustedHash ?? "—")")
        }
        let last = StatusReader.readAll().values.filter { $0.agent == .codex }.max { $0.updatedAt < $1.updatedAt }
        if let last {
            print("last codex hook record: \(last.lastEvent ?? "?") → \(last.state.rawValue) at \(last.updatedAt) (\(SessionInfo.parseCodexID(last.id)?.prefix(8) ?? "?"))")
        } else {
            print("last codex hook record: none on disk")
        }
    }

    /// `ccemaphore --codex-probe <rollout.jsonl>` — per-stage result for one rollout.
    static func probe(_ path: String) {
        print("file: \(path)")
        print("classify: \(CodexPaths.classify(path))")
        if let m = CodexRolloutParser.readMeta(path: path) {
            print("meta: thread=\(m.threadId ?? "?") originator=\(m.originator ?? "?") source=\(m.source ?? "?") "
                  + "cli=\(m.cliVersion ?? "?") host=\(m.host?.rawValue ?? "unknown") cwd=\(m.cwd ?? "?") branch=\(m.gitBranch ?? "-") "
                  + "threadSource=\(m.threadSource ?? "?")\(m.parentThreadId.map { " parent=\($0.prefix(8))" } ?? "")"
                  + "\(m.agentNickname.map { " nick=\($0)" } ?? "")")
        } else {
            print("meta: (session_meta not found in the first \(CodexRolloutParser.headWindow / 1024) KB)")
        }
        // The store's first read: the tail window, widened to the whole file when it holds no turn boundary.
        let historyStart = CodexRolloutParser.readMeta(path: path)?.historyStartOrdinal
        guard let (t, _, size) = CodexRolloutParser.read(path: path, historyStartOrdinal: historyStart) else {
            print("tail: unreadable"); return
        }
        let now = Date()
        print("tail: parsed=\(t.linesParsed) lines of \(size / 1024) KB turns=\(t.turnsSeen) native=\(t.nativeTurnSeen) import=\(t.importMarkerSeen)")
        print("last activity: \(t.lastActivity.map { "\($0)  (\(Int(now.timeIntervalSince($0)))s ago)" } ?? "none")")
        print("open turn: \(t.openTurnId ?? "none")\(t.openTurnStartedAt.map { "  started \($0)" } ?? "")")
        print("last turn end: \(t.lastTurnEnd ?? "-") \(t.lastTurnEndedAt.map(String.init(describing:)) ?? "")")
        print("approval_policy: \(t.approvalPolicy ?? "?")  reviewer: \(t.approvalsReviewer ?? "? (user)")"
              + "\(t.approvalsGoToUser ? "" : " → hook waits never turn it red")  cwd: \(t.cwd ?? "?")  roots: \(t.workspaceRoots)")
        print("context: \(t.context.map { "\(Int($0.usedPercent.rounded()))% of \($0.sizeTokens)" } ?? "?")")
        if let rl = t.rateLimits {
            func w(_ x: RateLimitInfo.Window?) -> String {
                guard let x else { return "-" }
                return "\(Int(x.usedPercent.rounded()))% / \(x.windowMinutes ?? 0)min reset=\(x.resetsAt.map(String.init(describing:)) ?? "?")"
            }
            print("rate limits: primary=\(w(rl.primary))  secondary=\(w(rl.secondary))")
        }
        if let id = CodexPaths.threadId(fromRolloutName: (path as NSString).lastPathComponent) {
            let held = CodexPaths.isWriterLockHeld(threadId: id)
            print("writer lock: \(held.map { $0 ? "HELD (loaded in a live process)" : "free" } ?? "no lock file")")
            let st = CodexRolloutParser.state(of: t, now: now, lockHeld: held)
            print("state → \(st.rawValue)")
            if let row = CodexIndex.threads(ids: [id])?.first {
                print("catalog: title=\"\(row.displayTitle ?? "")\" archived=\(row.archived) source=\(row.threadSource) "
                      + "originator=\(row.originator ?? "?") updated=\(row.updatedAt) project=\(row.projectId ?? "-")")
            }
        }
        if !t.unknownTypes.isEmpty {
            print("unknown types: \(t.unknownTypes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        }
    }
}

import SQLite3

extension CodexDiagnostic {
    /// `ccemaphore --codex-db-probe` — low-level SQLite open/prepare probe against the Codex catalog, with
    /// the extended error code and the OS errno. Exists because a read-only WAL open can fail for reasons
    /// (shm permissions, VFS temp dir) that only show up inside THIS process's environment.
    static func dbProbe() {
        let path = CodexPaths.stateDB
        print("sqlite \(String(cString: sqlite3_libversion()))  path=\(path)")
        let fm = FileManager.default
        print("-wal exists=\(fm.fileExists(atPath: path + "-wal"))  -shm exists=\(fm.fileExists(atPath: path + "-shm"))"
              + "  (no -wal ⇒ CodexIndex reads immutable)")
        print("TMPDIR=\(ProcessInfo.processInfo.environment["TMPDIR"] ?? "-")  SQLITE_TMPDIR=\(ProcessInfo.processInfo.environment["SQLITE_TMPDIR"] ?? "-")")
        for (label, flags) in [("ro|nomutex", SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX),
                               ("ro", SQLITE_OPEN_READONLY),
                               ("rw", SQLITE_OPEN_READWRITE),
                               ("ro|uri immutable", SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)] {
            var db: OpaquePointer?
            let target = label.contains("uri") ? "file:\(path)?immutable=1" : path
            let rc = sqlite3_open_v2(target, &db, flags, nil)
            guard rc == SQLITE_OK, let db else { print("\(label): open rc=\(rc)"); continue }
            var st: OpaquePointer?
            let prc = sqlite3_prepare_v2(db, "SELECT count(*) FROM threads", -1, &st, nil)
            if prc == SQLITE_OK, let st {
                let src = sqlite3_step(st)
                print("\(label): OK count=\(sqlite3_column_int64(st, 0)) step=\(src)")
                sqlite3_finalize(st)
            } else {
                print("\(label): prepare rc=\(prc) ext=\(sqlite3_extended_errcode(db)) errno=\(sqlite3_system_errno(db)) msg=\(String(cString: sqlite3_errmsg(db)))")
            }
            sqlite3_close(db)
        }
    }
}
