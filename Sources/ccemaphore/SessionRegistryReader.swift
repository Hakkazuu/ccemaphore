import Foundation

/// Claude Code's own live session registry — one `~/.claude/sessions/<pid>.json` per running `claude`
/// process (Claude Code ≥ 2.1.29x; verified on 2.1.293 desktop / 2.1.294 Cursor builds, see
/// memory/claude-session-registry). Claude Code writes it itself, from inside the agent process, so it
/// is the most authoritative and cheapest state source we have:
///
///   `status`          busy | shell | idle | waiting     (+ `waitingFor` when waiting:
///                     "permission prompt" | "input needed")
///   `entrypoint`      claude-desktop | claude-vscode | cli | …   → the host, without a process-tree walk
///   `name`/`nameSource` the session's display name ("user" = typed by the user; "derived" = `<dir>-xx`)
///   `cwd`             the LAUNCH folder — stable, unlike a hook's `cwd` that wanders after `cd`
///   `kind`            interactive | bg | daemon | daemon-worker
///   `hostSessionId`   the desktop app's `local_<uuid>` handle (its deep-link id)
///
/// Files of exited processes are reaped by Claude Code; we still gate on `pid` liveness so a crash can't
/// leave a ghost. The schema is UNDOCUMENTED: every field is decoded leniently, an unknown status reads
/// as nil, and a garbled file is skipped rather than failing the batch. `CCEMAPHORE_REGISTRY_DIR` is the
/// test seam. Sidecar `<pid>.<hash>.key` files (socket auth) and `.sock` paths are never read.
struct RegistryEntry: Sendable {
    enum Status: String, Sendable { case busy, shell, idle, waiting }

    let pid: Int32
    let sessionId: String
    let cwd: String
    let name: String?
    let nameSource: String?
    let entrypoint: String?
    let kind: String?
    let status: Status?
    let waitingFor: String?
    let statusUpdatedAt: Date?
    let updatedAt: Date?
    let startedAt: Date?
    let hostSessionId: String?
    let version: String?

    /// `name` only when the USER typed it (`/rename`, `-n`, the desktop title field). A `derived` name
    /// is Claude's own `<folder>-<2 chars>` placeholder, which adds nothing over the folder we already show.
    var userName: String? {
        guard nameSource == "user", let name, !name.isEmpty else { return nil }
        return name
    }

    /// The host this entry runs in, from `entrypoint`. `cli` and unknown entrypoints resolve to
    /// `.unknown` here — a real terminal vs. an editor's integrated terminal is still the hook's
    /// process-tree call (`ProcTree.classifyHost`), which the status file then refines.
    var host: SessionHost {
        switch entrypoint {
        case "claude-desktop": return .desktop
        case "claude-vscode":  return .ide
        default:               return .unknown
        }
    }

    /// `kind` → is this a `claude --bg` background agent (shown with a marker)?
    var isBackground: Bool { kind == "bg" }
    /// Daemons never appear in the chat list (they are infrastructure, not conversations).
    var isHidden: Bool { kind == "daemon" || kind == "daemon-worker" }

    var waitingKind: WaitingKind? {
        guard status == .waiting else { return nil }
        if let w = waitingFor?.lowercased(), w.contains("input") { return .input }
        return .permission
    }

    /// Traffic-light state for this entry. `idle` reads as `done` — the same convention the hooks use
    /// (`SessionStart` also writes `done`: registered, nothing pending). `shell` is a user-driven shell
    /// turn (`!` mode) — the agent isn't working, so it reads `done` too. nil ⇒ unknown status, no claim.
    var sessionState: SessionState? {
        switch status {
        case .busy:    return .working
        case .waiting: return .waiting
        case .idle, .shell: return .done
        case .none:    return nil
        }
    }
}

enum SessionRegistryReader {
    static var dir: String {
        if let p = ProcessInfo.processInfo.environment["CCEMAPHORE_REGISTRY_DIR"], !p.isEmpty { return p }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".claude/sessions")
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: dir) }

    /// All LIVE entries keyed by session id. "Live" = the owning pid still exists (EPERM counts as alive,
    /// see `ProcTree.isAlive`). When two files claim the same session id (a resumed session whose old
    /// process is still winding down), the freshest `statusUpdatedAt`/`updatedAt` wins.
    static func readAll(dir: String = dir) -> [String: RegistryEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [:] }
        var out: [String: RegistryEntry] = [:]
        for name in names where name.hasSuffix(".json") && !name.contains(".key") {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: path), let e = parse(data: data) else { continue }
            guard ProcTree.isAlive(e.pid) else { continue }
            if let prev = out[e.sessionId], freshness(prev) >= freshness(e) { continue }
            out[e.sessionId] = e
        }
        return out
    }

    private static func freshness(_ e: RegistryEntry) -> Date {
        e.statusUpdatedAt ?? e.updatedAt ?? e.startedAt ?? .distantPast
    }

    /// Lenient decode of one registry file. Timestamps are epoch MILLISECONDS (as Claude Code writes
    /// them); a non-numeric value just nils that one field.
    static func parse(data: Data) -> RegistryEntry? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (json["pid"] as? NSNumber)?.int32Value, pid > 1,
              let sid = json["sessionId"] as? String, !sid.isEmpty
        else { return nil }
        func str(_ k: String) -> String? { (json[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func millis(_ k: String) -> Date? {
            guard let n = (json[k] as? NSNumber)?.doubleValue, n > 0 else { return nil }
            return Date(timeIntervalSince1970: n / 1000)
        }
        return RegistryEntry(
            pid: pid,
            sessionId: sid,
            cwd: str("cwd") ?? "",
            name: str("name"),
            nameSource: str("nameSource"),
            entrypoint: str("entrypoint"),
            kind: str("kind"),
            status: str("status").flatMap(RegistryEntry.Status.init(rawValue:)),
            waitingFor: str("waitingFor"),
            statusUpdatedAt: millis("statusUpdatedAt"),
            updatedAt: millis("updatedAt"),
            startedAt: millis("startedAt"),
            hostSessionId: str("hostSessionId"),
            version: str("version"))
    }

    /// `ccemaphore --registry-dump` — print every registry file (live AND dead pids, so a stale leftover
    /// is visible) the way the engine would read it.
    static func dump() {
        let fm = FileManager.default
        print("registry dir: \(dir)  exists=\(exists)")
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { print("(unreadable)"); return }
        let now = Date()
        var rows: [(RegistryEntry, Bool)] = []
        for name in names.sorted() where name.hasSuffix(".json") && !name.contains(".key") {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: path) else { continue }
            guard let e = parse(data: data) else { print("  \(name): UNPARSEABLE"); continue }
            rows.append((e, ProcTree.isAlive(e.pid)))
        }
        for (e, alive) in rows.sorted(by: { freshness($0.0) > freshness($1.0) }) {
            let age = e.statusUpdatedAt.map { "\(Int(now.timeIntervalSince($0)))s" } ?? "?"
            let st = e.status?.rawValue ?? "?"
            let wf = e.waitingFor.map { " waitingFor=\"\($0)\"" } ?? ""
            let nm = e.name.map { " name=\"\($0)\"(\(e.nameSource ?? "?"))" } ?? ""
            print("  pid=\(e.pid)\(alive ? "" : "(DEAD)") sid=\(e.sessionId.prefix(8)) \(st)\(wf) age=\(age) "
                  + "entry=\(e.entrypoint ?? "?") kind=\(e.kind ?? "?") host=\(e.host.rawValue)\(nm) "
                  + "cwd=\(e.cwd) v=\(e.version ?? "?")\(e.hostSessionId.map { " hostSid=\($0)" } ?? "")")
        }
        if rows.isEmpty { print("  (no entries)") }
    }
}
