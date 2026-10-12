import Foundation

/// Where OpenAI Codex keeps its local state, and how its files are named. Shared by the ChatGPT.app
/// Codex surface (the former Codex desktop app, bundle `com.openai.codex`), the Codex CLI/TUI and
/// `codex exec` — they all read and write the same `CODEX_HOME` (default `~/.codex`). Verified on
/// codex-cli 0.162 (see memory/codex-integration-research):
///
///   sessions/YYYY/MM/DD/rollout-<ISO ts>-<uuid v7>.jsonl   the thread transcript ("rollout")
///   archived_sessions/rollout-*.jsonl                       archived threads (flat; ignored)
///   state_5.sqlite                                          thread catalog (`threads`, `projects`, …)
///   thread-writer-locks/<thread_id>.lock                    flock held while a process has the thread loaded
///   hooks.json, config.toml                                 hook config + its trust state
///   external_agent_session_imports.json                     threads imported from Claude Code / Cursor
///
/// Pure path logic, no IO except `isInstalled`. `CCEMAPHORE_CODEX_HOME` is the test seam (checked before
/// Codex's own `CODEX_HOME`, so a diagnostic can point at a fixture tree).
enum CodexTranscriptKind: Sendable, Equatable {
    /// A live-tree rollout: `sessions/**/rollout-<ts>-<thread_id>.jsonl`.
    case thread(id: String)
    case ignored
}

enum CodexPaths {
    /// The PHYSICAL path (`realpath`): FSEvents reports physical paths, and `classify` / the lock-dir
    /// check match events by prefix against these roots — a dotfile-managed `~/.codex -> ~/dotfiles/codex`
    /// (or a `/var/…` fixture, really `/private/var/…`) would otherwise make every event classify as
    /// `.ignored` and leave mode A dead after the initial scan. A path that doesn't exist yet is kept as is.
    static var home: String {
        let env = ProcessInfo.processInfo.environment
        let raw: String
        if let p = env["CCEMAPHORE_CODEX_HOME"], !p.isEmpty { raw = p }
        else if let p = env["CODEX_HOME"], !p.isEmpty { raw = (p as NSString).expandingTildeInPath }
        else { raw = (NSHomeDirectory() as NSString).appendingPathComponent(".codex") }
        return physical(raw)
    }

    private static func physical(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    static var sessionsRoot: String { (home as NSString).appendingPathComponent("sessions") }
    static var archivedRoot: String { (home as NSString).appendingPathComponent("archived_sessions") }
    static var stateDB: String { (home as NSString).appendingPathComponent("state_5.sqlite") }
    static var writerLocksDir: String { (home as NSString).appendingPathComponent("thread-writer-locks") }
    static var hooksPath: String { (home as NSString).appendingPathComponent("hooks.json") }
    static var configPath: String { (home as NSString).appendingPathComponent("config.toml") }
    static var importsPath: String { (home as NSString).appendingPathComponent("external_agent_session_imports.json") }
    static var sessionIndexPath: String { (home as NSString).appendingPathComponent("session_index.jsonl") }

    /// Codex has been used on this machine: the live rollout tree or the state DB exists. Mirrors
    /// `StateEngine.claudeInstalled` (which keys on `~/.claude/projects`).
    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: sessionsRoot) || fm.fileExists(atPath: stateDB)
    }

    /// Map a file path to its Codex transcript kind. Only the live `sessions/` tree counts; archived
    /// rollouts, SQLite side files and anything else are ignored.
    static func classify(_ path: String, root: String = sessionsRoot) -> CodexTranscriptKind {
        guard path.hasSuffix(".jsonl"), path.hasPrefix(root + "/") else { return .ignored }
        let base = (path as NSString).lastPathComponent
        guard let id = threadId(fromRolloutName: base) else { return .ignored }
        return .thread(id: id)
    }

    /// `rollout-2026-10-08T19-29-37-01a11c22-5ef9-7282-a2d4-762ada2e6b8c.jsonl` → the trailing uuid.
    /// The timestamp prefix also contains dashes, so take the LAST 36 characters before `.jsonl` and
    /// validate them as a uuid rather than splitting on `-`.
    static func threadId(fromRolloutName name: String) -> String? {
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
        let stem = name.dropLast(".jsonl".count)
        guard stem.count > 36 else { return nil }
        let id = String(stem.suffix(36))
        return UUID(uuidString: id) != nil ? id.lowercased() : nil
    }

    /// Every rollout under the live tree (initial scan / full rescan). Bounded: only day folders whose
    /// files could matter are walked — `sinceDays` back from today — because a long-lived install
    /// accumulates hundreds of rollouts (437 on the reference machine), most of them months old.
    static func enumerateRollouts(root: String = sessionsRoot, sinceDays: Int = 3, now: Date = Date()) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        var day = Calendar.current.startOfDay(for: now)
        for _ in 0...max(0, sinceDays) {
            let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { break }
            let dir = String(format: "%@/%04d/%02d/%02d", root, y, m, d)
            if let names = try? fm.contentsOfDirectory(atPath: dir) {
                for n in names where threadId(fromRolloutName: n) != nil {
                    out.append((dir as NSString).appendingPathComponent(n))
                }
            }
            guard let prev = Calendar.current.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return out
    }

    /// Path of a thread's writer lock. Codex holds an exclusive `flock` on it for as long as some process
    /// has the thread loaded (the ChatGPT.app keeps every open thread loaded); the file itself is never
    /// deleted, so EXISTENCE means nothing — only the lock state does (see `isWriterLockHeld`).
    static func writerLockPath(threadId: String) -> String {
        (writerLocksDir as NSString).appendingPathComponent("\(threadId).lock")
    }

    /// True iff another process currently holds the thread's writer lock (⇒ the thread is loaded in a
    /// live Codex process — the Codex analogue of "the owning pid is alive"). A pure QUERY: we never take
    /// the lock ourselves, not even for an instant — Codex's own try-lock on the same file would then
    /// fail and it would believe another process owns the thread. `fcntl(F_GETLK)` reports a conflicting
    /// lock without acquiring anything; verified on macOS 27 to see `flock(LOCK_EX)` holders too
    /// (`l_type` comes back `F_WRLCK` with `l_pid == -1`, flock locks not being pid-attributed), and
    /// `F_UNLCK` means nobody holds it. nil when the lock file doesn't exist (an older Codex, or a thread
    /// never opened since the lock dir appeared) or the query fails — the caller must then fall back to
    /// age-based liveness rather than read "not held".
    static func isWriterLockHeld(threadId: String) -> Bool? {
        let path = writerLockPath(threadId: threadId)
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var probe = flock()
        probe.l_type = Int16(F_WRLCK)
        probe.l_whence = Int16(SEEK_SET)
        probe.l_start = 0
        probe.l_len = 0
        let rc = withUnsafeMutablePointer(to: &probe) { fcntl(fd, F_GETLK, $0) }
        guard rc == 0 else { return nil }
        return probe.l_type != Int16(F_UNLCK)
    }

    /// Thread ids whose lock is currently held — "open in some Codex process right now". Lists the lock
    /// dir once; cheap (a few dozen tiny files).
    static func heldWriterLocks() -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: writerLocksDir) else { return [] }
        var out = Set<String>()
        for n in names where n.hasSuffix(".lock") {
            let id = String(n.dropLast(".lock".count))
            guard UUID(uuidString: id) != nil else { continue }
            if isWriterLockHeld(threadId: id) == true { out.insert(id.lowercased()) }
        }
        return out
    }

    /// Thread ids that ChatGPT.app created by IMPORTING a Claude Code (or Cursor) session — mirrors of
    /// chats that already exist on the Claude side. Read from the import ledger; empty if absent.
    static func importedThreadIds() -> Set<String> {
        guard let data = FileManager.default.contents(atPath: importsPath),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let records = json["records"] as? [[String: Any]] else { return [] }
        return Set(records.compactMap { ($0["imported_thread_id"] as? String)?.lowercased() })
    }
}
