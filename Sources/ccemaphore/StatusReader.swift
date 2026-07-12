import Foundation

/// One mode-B status file (~/.claude/status/<id>.json), written by the hook handler.
struct StatusEntry: Sendable {
    let id: String
    let state: SessionState
    let project: String
    let cwd: String?
    let updatedAt: Date
    /// The hook event that wrote this file (e.g. "permission", "stop", "pre"). Lets `render()` tell a
    /// live interactive `waiting` from a dangling one left by a killed permission-broker process.
    let lastEvent: String?
    /// The `PreCompact` hook wrote `state:"compacting"` — a sub-state of `working` (see
    /// `SessionInfo.isCompacting`). We store the state as `.working` and raise this flag instead, so
    /// nothing downstream has to learn a 5th `SessionState` case.
    let isCompacting: Bool
    /// PID of the owning Claude Code / agent process (recorded by the hook, see `ProcTree`). Lets
    /// `render()` reap a chat the instant its process dies — a closed window drops off the light at once
    /// instead of lingering ~30 min until `staleWindow`. nil for older status files / non-hook writers.
    let ownerPid: Int32?
    /// Where the session runs (IDE vs. terminal), inferred by the hook (`ProcTree.sessionContext`).
    /// Drives where "перейти в чат" jumps. `.unknown` for older files / an unclassifiable host.
    let host: SessionHost
    /// The host app's bundle id when known (e.g. `com.googlecode.iterm2`) — lets the GUI raise a terminal
    /// app Claude Code can't deep-link into by tab. nil for older files / a bundle-less host (tmux/login).
    let hostBundleId: String?
    /// Monotonic count of NON-broker events written to this file (see `HookHandler.writeStatus`). The
    /// blocking permission broker snapshots it before its wait and treats any later increase as "the turn
    /// advanced" — catching a `pre`/`post` whose `last_event` was overwritten by another broker's write
    /// before the next poll. nil for files written by older builds (⇒ the broker falls back to the
    /// `last_event` check alone). `nonBrokerEvent` names that last non-broker event, for the decision log.
    let nonBrokerSeq: Int?
    let nonBrokerEvent: String?
    /// Per-origin tag. nil for a LOCAL status file (`StatusReader.readAll`); set to the owning
    /// `RemoteHost.id` when `RemoteTranscriptPoller` folds a remote host's status into the SAME
    /// `statusBySession` merge — so local-only behaviours (pid-reap via `ProcTree`) can gate on
    /// `remoteHostId == nil` while every other status rule (demote / suppressDone / native-wait /
    /// compacting) serves remote sessions for free. Defaulted so the memberwise init is unchanged.
    var remoteHostId: String? = nil
}

enum StatusReader {
    /// Read every status file in the dir. Tiny files; nonisolated so it can run off the main actor.
    static func readAll(dir: String = HookHandler.statusDir) -> [String: StatusEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [:] }
        var out: [String: StatusEntry] = [:]
        for name in names where name.hasSuffix(".json") {
            if let entry = parse(path: (dir as NSString).appendingPathComponent(name)) {
                out[entry.id] = entry
            }
        }
        return out
    }

    /// Read a single session's status file (`<dir>/<sessionId>.json`). Used by the blocking permission
    /// broker to notice — from its own separate process — that the chat advanced past our `permission`
    /// wait (i.e. the user answered in Cursor's own dialog), so it can drop the request promptly.
    static func readOne(sessionId: String, dir: String = HookHandler.statusDir) -> StatusEntry? {
        parse(path: (dir as NSString).appendingPathComponent("\(sessionId).json"))
    }

    /// Decode one status file into a `StatusEntry`; nil on any missing/garbled field.
    private static func parse(path: String) -> StatusEntry? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parse(data: data)
    }

    /// Same decode, from already-fetched bytes — used for local files above, and by
    /// `RemoteTranscriptPoller` to parse a remote status file's bytes (fetched over SSH) with the
    /// identical field mapping, so the two sources can never silently drift apart.
    static func parse(data: Data) -> StatusEntry? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = json["session_id"] as? String,
              let stateRaw = json["state"] as? String,
              let updatedRaw = json["updated_at"] as? String,
              let updated = parseISO(updatedRaw)
        else { return nil }
        // "compacting" isn't a `SessionState` — it's a `working` sub-state carried by a flag, so decode it
        // ourselves rather than failing `SessionState(rawValue:)` (which would drop the whole file).
        let isCompacting = (stateRaw == "compacting")
        let state: SessionState
        if isCompacting { state = .working }
        else if let s = SessionState(rawValue: stateRaw) { state = s }
        else { return nil }
        let cwd = (json["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let project = (json["project"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? cwd.map { ($0 as NSString).lastPathComponent } ?? "—"
        let lastEvent = (json["last_event"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let ownerPid = (json["pid"] as? NSNumber)?.int32Value
        let host = (json["host"] as? String).flatMap(SessionHost.init(rawValue:)) ?? .unknown
        let hostBundleId = (json["host_app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let nonBrokerSeq = (json["nb_seq"] as? NSNumber)?.intValue
        let nonBrokerEvent = (json["nb_event"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return StatusEntry(id: id, state: state, project: project, cwd: cwd,
                           updatedAt: updated, lastEvent: lastEvent,
                           isCompacting: isCompacting, ownerPid: ownerPid,
                           host: host, hostBundleId: hostBundleId,
                           nonBrokerSeq: nonBrokerSeq, nonBrokerEvent: nonBrokerEvent)
    }

    private static func parseISO(_ s: String) -> Date? { ISOTime.parse(s) }
}
