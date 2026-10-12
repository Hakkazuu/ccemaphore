import Foundation

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
        let sessions = await store.rescan(now: now)
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
                print("           └ \(c.state.rawValue) \(c.name)  age=\(Int(now.timeIntervalSince(c.lastActivity)))s")
            }
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
        let lines = TailReader.tailLines(path: path)
        let t = CodexRolloutParser.parseTail(lines: lines)
        let now = Date()
        print("tail: lines=\(lines.count) parsed=\(t.linesParsed) turns=\(t.turnsSeen) native=\(t.nativeTurnSeen) import=\(t.importMarkerSeen)")
        print("last activity: \(t.lastActivity.map { "\($0)  (\(Int(now.timeIntervalSince($0)))s ago)" } ?? "none")")
        print("open turn: \(t.openTurnId ?? "none")\(t.openTurnStartedAt.map { "  started \($0)" } ?? "")")
        print("last turn end: \(t.lastTurnEnd ?? "-") \(t.lastTurnEndedAt.map(String.init(describing:)) ?? "")")
        print("approval_policy: \(t.approvalPolicy ?? "?")  cwd: \(t.cwd ?? "?")  roots: \(t.workspaceRoots)")
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
