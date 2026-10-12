import Foundation
import SQLite3
import os

/// One row of Codex's thread catalog (`state_5.sqlite` → `threads`). The catalog is what ChatGPT.app's
/// sidebar is built from, so reading it gives us the SAME titles, cwd, archive state and project
/// grouping the user sees there — no guessing from file names.
struct CodexThreadRow: Sendable {
    let id: String
    let rolloutPath: String
    let cwd: String
    /// Auto title (usually the first user message, trimmed). May be empty.
    let title: String
    /// The thread's display name — AI-generated or user-renamed (`thread/name/set`). nil if unnamed.
    let name: String?
    let archived: Bool
    /// `user` | `subagent` | "" (older rows).
    let threadSource: String
    /// `Codex Desktop` / `codex_work_desktop` (ChatGPT.app), `codex-tui`, `codex exec`, …
    let originator: String?
    /// `vscode` for app threads, or a JSON blob for sub-agent threads (see `parentThreadId`).
    let sourceRaw: String
    let gitBranch: String?
    let createdAt: Date
    let updatedAt: Date
    let projectId: String?
    let tokensUsed: Int
    /// For a sub-agent thread: the spawning parent (parsed from `source` JSON
    /// `{"subagent":{"thread_spawn":{"parent_thread_id":…,"agent_nickname":…}}}`). nil for user threads
    /// AND for parent-less helpers (`{"subagent":{"other":"guardian"}}`), which are hidden.
    let parentThreadId: String?
    let agentNickname: String?

    var isSubagent: Bool { parentThreadId != nil || threadSource == "subagent" || sourceRaw.hasPrefix("{") }

    /// What to show as the chat's title: the name if set, else the auto title, else nil.
    var displayTitle: String? {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return String(t.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
    }
}

/// A user-defined project in ChatGPT.app's sidebar (`projects` + `project_roots`): a name and the
/// folders it spans. The seed for ccemaphore's product groups.
struct CodexProject: Sendable, Equatable {
    let id: String
    let name: String
    let roots: [String]
}

/// Read-only access to Codex's SQLite catalog. Rules, because the DB is live and owned by another
/// process (WAL mode, written by ChatGPT.app / the CLI):
///  - open `SQLITE_OPEN_READONLY`, never write, never hold a connection across calls — one short
///    transaction per query and close;
///  - while the DB has no `-wal` file, open it `immutable` instead (why: `withRetry`);
///  - a short busy timeout (the writer holds brief locks during checkpoints);
///  - any failure → empty result, logged once per process. Mode A must keep working from the rollout
///    files alone when the DB is unreadable; the catalog only ADDS titles/projects/archive state.
/// The schema grows with every Codex release (61 migrations so far), so we select named columns only
/// and fall back to a minimal column set if the full one fails to prepare.
enum CodexIndex {
    /// First failure per process logs at warn level, the rest at debug (see `warn`). A lock rather than a
    /// bare static: the catalog is read from the Codex store actor AND from `UsageProvider`'s detached task.
    private static let warnedOnce = OSAllocatedUnfairLock(initialState: false)

    /// Row filter, rendered per column set: the full schema has `updated_at_ms`, the minimal one (older
    /// Codex) only `updated_at` — a WHERE naming the newer column would defeat the fallback SELECT.
    private enum Filter {
        case all
        case updatedSince(ms: Int64)
        case ids(list: String)

        func sql(minimal: Bool) -> String {
            switch self {
            case .all:
                return ""
            case .updatedSince(let ms):
                return minimal ? " WHERE updated_at * 1000 >= \(ms)"
                               : " WHERE coalesce(updated_at_ms, updated_at * 1000) >= \(ms)"
            case .ids(let list):
                return " WHERE lower(id) IN (\(list))"
            }
        }
    }

    /// nil ⇒ the catalog could not be read right now (keep whatever you had); [] ⇒ genuinely no rows.
    static func threads(updatedSince: Date?, path: String = CodexPaths.stateDB) -> [CodexThreadRow]? {
        let filter: Filter = updatedSince.map { .updatedSince(ms: Int64($0.timeIntervalSince1970 * 1000)) } ?? .all
        return query(path: path, filter: filter)
    }

    /// Rows for specific thread ids (lock-held threads that are older than the recency window).
    static func threads(ids: Set<String>, path: String = CodexPaths.stateDB) -> [CodexThreadRow]? {
        guard !ids.isEmpty else { return [] }
        // Thread ids are uuids (validated by the callers) — safe to inline as quoted literals.
        let list = ids.filter { UUID(uuidString: $0) != nil }.map { "'\($0.lowercased())'" }.joined(separator: ",")
        guard !list.isEmpty else { return [] }
        return query(path: path, filter: .ids(list: list))
    }

    static func projects(path: String = CodexPaths.stateDB) -> [CodexProject]? {
        var names: [String: (name: String, position: Int64)] = [:]
        var roots: [String: [(Int64, String)]] = [:]
        let ok = withRetry(path: path) { db in
            guard run(db, "SELECT id, name, position FROM projects", { st in
                guard let id = text(st, 0), let name = text(st, 1) else { return }
                names[id] = (name, sqlite3_column_int64(st, 2))
            }) else { return false }
            return run(db, "SELECT project_id, position, path FROM project_roots") { st in
                guard let pid = text(st, 0), let p = text(st, 2) else { return }
                roots[pid, default: []].append((sqlite3_column_int64(st, 1), p))
            }
        }
        guard ok else { return nil }
        return names.sorted { $0.value.position < $1.value.position }.map { id, v in
            CodexProject(id: id, name: v.name, roots: (roots[id] ?? []).sorted { $0.0 < $1.0 }.map(\.1))
        }
    }

    /// Open + run `body` with a fresh connection, retrying a few times on the transient failures a live
    /// WAL database produces while its writer checkpoints (`SQLITE_BUSY`, and `SQLITE_CANTOPEN` on the
    /// -shm/-wal files — observed once on the reference machine right after ChatGPT.app truncated the WAL).
    ///
    /// Codex's SQLite deletes the -wal and -shm whenever its last connection closes, which is most of the
    /// time, and a read-only connection can't open a WAL database without them: it fails the first
    /// statement with `SQLITE_CANTOPEN` and creates nothing (macOS's SQLite 3.54, in this app and in
    /// `sqlite3 -readonly` alike). No -wal on disk means every commit is already in the main file, so the
    /// file is then read `immutable`: no locks, no WAL, nothing created next to Codex's files. A CANTOPEN
    /// with the -wal present (it lost its -shm) retries `immutable` too; that read can miss the WAL's newest
    /// commits until the next refresh.
    /// `body` returns false when a statement failed to prepare/step. True ⇒ the results are trustworthy.
    private static func withRetry(path: String, attempts: Int = 3, _ body: (OpaquePointer) -> Bool) -> Bool {
        var cantOpen = false
        for attempt in 0..<attempts {
            let immutable = cantOpen || !FileManager.default.fileExists(atPath: path + "-wal")
            if let db = open(path, immutable: immutable) {
                let ok = body(db)
                cantOpen = !ok && sqlite3_errcode(db) == SQLITE_CANTOPEN
                sqlite3_close(db)
                if ok { return true }
            }
            if attempt + 1 < attempts { usleep(60_000 * UInt32(attempt + 1)) }
        }
        return false
    }

    // MARK: - Query

    private static let fullColumns = """
        id, rollout_path, cwd, title, name, archived, coalesce(thread_source, ''), originator, source, \
        git_branch, coalesce(created_at_ms, created_at * 1000), coalesce(updated_at_ms, updated_at * 1000), \
        project_id, tokens_used
        """
    private static let minimalColumns = """
        id, rollout_path, cwd, title, NULL, archived, '', NULL, source, NULL, created_at * 1000, \
        updated_at * 1000, NULL, tokens_used
        """

    private static func query(path: String, filter: Filter) -> [CodexThreadRow]? {
        var rows: [CodexThreadRow] = []
        let collect: (OpaquePointer) -> Void = { st in
            guard let id = text(st, 0), let rollout = text(st, 1) else { return }
            let sourceRaw = text(st, 8) ?? ""
            let (parent, nick) = parseSubagentSource(sourceRaw)
            rows.append(CodexThreadRow(
                id: id.lowercased(),
                rolloutPath: rollout,
                cwd: text(st, 2) ?? "",
                title: text(st, 3) ?? "",
                name: text(st, 4).flatMap { $0.isEmpty ? nil : $0 },
                archived: sqlite3_column_int64(st, 5) != 0,
                threadSource: text(st, 6) ?? "",
                originator: text(st, 7).flatMap { $0.isEmpty ? nil : $0 },
                sourceRaw: sourceRaw,
                gitBranch: text(st, 9).flatMap { $0.isEmpty ? nil : $0 },
                createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, 10)) / 1000),
                updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, 11)) / 1000),
                projectId: text(st, 12).flatMap { $0.isEmpty ? nil : $0 },
                tokensUsed: Int(sqlite3_column_int64(st, 13)),
                parentThreadId: parent,
                agentNickname: nick))
        }
        let ok = withRetry(path: path) { db in
            rows.removeAll()
            if run(db, "SELECT \(fullColumns) FROM threads\(filter.sql(minimal: false))", collect) { return true }
            rows.removeAll()
            return run(db, "SELECT \(minimalColumns) FROM threads\(filter.sql(minimal: true))", collect)
        }
        return ok ? rows : nil
    }

    /// `{"subagent":{"thread_spawn":{"parent_thread_id":"…","agent_nickname":"…",…}}}` → (parent, nick).
    static func parseSubagentSource(_ raw: String) -> (String?, String?) {
        guard raw.hasPrefix("{"), let data = raw.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sub = json["subagent"] as? [String: Any],
              let spawn = sub["thread_spawn"] as? [String: Any] else { return (nil, nil) }
        let parent = (spawn["parent_thread_id"] as? String)?.lowercased()
        let nick = (spawn["agent_nickname"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (spawn["agent_path"] as? String).map { ($0 as NSString).lastPathComponent }
        return (parent, nick)
    }

    // MARK: - SQLite plumbing (read-only, short-lived)

    private static func open(_ path: String, immutable: Bool) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        let rc = immutable
            ? sqlite3_open_v2(URL(fileURLWithPath: path).absoluteString + "?immutable=1", &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nil)
            : sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            warn("cannot open \(path) (rc=\(rc))")
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 250)
        return db
    }

    /// Prepare + step a statement, calling `row` per result row. Returns false if the statement failed
    /// to prepare (unknown column on an older/newer schema) so the caller can try a fallback.
    @discardableResult
    private static func run(_ db: OpaquePointer, _ sql: String, _ row: (OpaquePointer) -> Void) -> Bool {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            warn("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        defer { sqlite3_finalize(st) }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { row(st); continue }
            if rc != SQLITE_DONE {
                warn("step rc=\(rc): \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            break
        }
        return true
    }

    private static func text(_ st: OpaquePointer, _ col: Int32) -> String? {
        guard let p = sqlite3_column_text(st, col) else { return nil }
        return String(cString: p)
    }

    private static func warn(_ msg: String) {
        // Once per process at warn level (a transient CANTOPEN is retried and usually recovers); every
        // occurrence at debug so a persistent failure stays diagnosable from the log.
        let first = warnedOnce.withLock { seen -> Bool in
            if seen { return false }
            seen = true
            return true
        }
        guard first else { Log.codex.debug("state DB: \(msg)"); return }
        Log.codex.warn("state DB: \(msg) — retrying; if persistent, the Codex catalog is unavailable and rollout files alone drive mode A")
    }
}
