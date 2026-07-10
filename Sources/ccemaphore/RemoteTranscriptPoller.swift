import Foundation

/// Remote analogue of the local FSEvents-driven transcript watch (`TranscriptWatcher`) — there is no
/// kernel API to watch a directory over SSH, so this polls each enabled `RemoteHost` on
/// `Tuning.remotePollInterval`, entirely decoupled from `StateEngine`'s local `stateTick` so one slow or
/// unreachable host can never stall local rendering.
///
/// Only top-level session transcripts (`<slug>/<uuid>.jsonl`) are polled — sub-agent/workflow fan-out
/// folding (`SessionPath`'s `.subagent`/`.workflowRecord` cases) is a local-only refinement, out of scope
/// here; a remote session's state is derived from its own top-level transcript tail plus (if the hook
/// shim is installed) its `~/.claude/status` file, same graceful mode-A/mode-B layering as local.
@MainActor
final class RemoteTranscriptPoller: ObservableObject {
    struct HostStatus: Equatable {
        var connected: Bool = false
        var lastSuccess: Date? = nil
        var lastError: String? = nil
    }

    @Published private(set) var hostStatuses: [String: HostStatus] = [:]
    /// Latest known sessions per host, keyed by the SAME namespaced id `SessionInfo` uses — read by
    /// `StateEngine.render()` to fold into the local merge without blocking on a live SSH round-trip.
    private(set) var lastSessions: [String: [String: SessionInfo]] = [:]   // hostId -> (namespaced id -> info)

    /// Poll every enabled host once. Safe to call repeatedly on a timer; each host's failure is isolated
    /// (a dead host never throws for the others) and recorded in `hostStatuses` for the UI.
    func pollAll(onUpdate: @escaping () -> Void) {
        let hosts = RemoteHosts.load().filter(\.enabled)
        for host in hosts {
            Task { [weak self] in
                let sessions = await Self.pollOnce(host: host)
                guard let self else { return }
                switch sessions {
                case .success(let infos):
                    self.lastSessions[host.id] = Dictionary(uniqueKeysWithValues: infos.map { ($0.id, $0) })
                    self.hostStatuses[host.id] = HostStatus(connected: true, lastSuccess: Date(), lastError: nil)
                case .failure(let error):
                    var s = self.hostStatuses[host.id] ?? HostStatus()
                    s.connected = false
                    s.lastError = error.localizedDescription
                    self.hostStatuses[host.id] = s
                }
                onUpdate()
            }
        }
        // Hosts that were disabled/removed since the last pass shouldn't linger in the merge buffer.
        let liveIds = Set(hosts.map(\.id))
        lastSessions = lastSessions.filter { liveIds.contains($0.key) }
        hostStatuses = hostStatuses.filter { liveIds.contains($0.key) }
    }

    /// One synchronous-from-the-caller's-perspective poll of a single host — also the implementation
    /// behind `--remote-scan`. Runs off the main actor (SSH round-trips can take seconds).
    nonisolated static func pollOnce(host: RemoteHost) async -> Result<[SessionInfo], RemoteExec.SSHError> {
        do {
            let root = host.remoteProjectsRoot ?? "~/.claude/projects"
            let files = try RemoteExec.findFilesWithMTime(host, root: root, namePattern: "*.jsonl")
            var byId: [String: SessionInfo] = [:]
            let now = Date()
            for (path, mtime) in files {
                // Skip anything the FILESYSTEM already says is stale before paying for a tail fetch —
                // both a performance win (no SSH round-trip for old history) and the correctness fix for
                // a session whose JSON content disagreed with its own mtime (see `findFilesWithMTime`'s
                // doc comment): the file is never even opened, so a bogus content timestamp can't apply.
                guard now.timeIntervalSince(mtime) <= Tuning.staleWindow else { continue }
                guard let (uuid, slug) = topLevelSessionId(path: path, root: root) else { continue }
                guard let data = try RemoteExec.tailFile(host, path: path, window: 512 * 1024), !data.isEmpty else { continue }
                guard let info = buildSessionInfo(hostId: host.id, uuid: uuid, slug: slug, tail: data, mtime: mtime) else { continue }
                byId[info.id] = info
            }
            // Best-effort status overlay: if the hook shim isn't installed yet, this is simply empty and
            // sessions fall back to the mode-A-only heuristic above — same degrade path as a local session
            // with hooks off.
            if let statusFiles = try? RemoteExec.listGlob(host, glob: "~/.claude/status/*.json") {
                for statusPath in statusFiles {
                    guard let data = try? RemoteExec.readFile(host, path: statusPath), !data.isEmpty,
                          let entry = StatusReader.parse(data: data),
                          now.timeIntervalSince(entry.updatedAt) <= Tuning.staleWindow else { continue }
                    let namespaced = "remote:\(host.id):\(entry.id)"
                    guard var info = byId[namespaced] else { continue }
                    info.state = entry.state
                    info.isCompacting = entry.isCompacting
                    info.host = entry.host
                    info.hostBundleId = entry.hostBundleId
                    info.lastEvent = entry.lastEvent
                    info.lastActivity = max(info.lastActivity, entry.updatedAt)
                    byId[namespaced] = info
                }
            }
            return .success(Array(byId.values))
        } catch let e as RemoteExec.SSHError {
            return .failure(e)
        } catch {
            return .failure(RemoteExec.SSHError(message: error.localizedDescription, exitCode: -1))
        }
    }

    /// `<root>/<slug>/<uuid>.jsonl` → (uuid, slug); nil for anything deeper (sub-agent/workflow paths,
    /// out of scope for remote polling — see type doc).
    nonisolated private static func topLevelSessionId(path: String, root: String) -> (uuid: String, slug: String)? {
        let normalizedRoot = root.hasPrefix("~") ? String(root.dropFirst()) : root
        guard let range = path.range(of: normalizedRoot) else { return nil }
        let rel = String(path[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let comps = rel.split(separator: "/").map(String.init)
        guard comps.count == 2, comps[1].hasSuffix(".jsonl") else { return nil }
        let uuid = String(comps[1].dropLast(".jsonl".count))
        guard SessionPath.isUUID(uuid) else { return nil }
        return (uuid, comps[0])
    }

    /// Tail shape, mirroring `SessionStore`'s private `TailShape`/`shape(of:)`/`state(of:)` (that actor's
    /// machinery is file-path- and actor-isolated, so it can't be called directly from here — this is a
    /// deliberate byte-for-byte re-derivation of the same classification, not an approximation, so a
    /// remote chat's dot matches what the local heuristic would show for the identical transcript tail).
    private enum TailShape { case working, userToolResult, systemRetry, doneEndTurn, other }

    nonisolated private static func shape(of line: LogLine) -> TailShape {
        if line.type == "assistant" {
            switch line.message?.stopReason {
            case "end_turn", "stop_sequence": return .doneEndTurn
            case "tool_use": return .working
            case .none: return .working
            default: return .other
            }
        }
        if line.type == "user" {
            let blocks = line.message?.content?.blocks ?? []
            if blocks.contains(where: { $0.type == "tool_result" }) { return .userToolResult }
            return .working
        }
        return .other
    }

    /// True if the last assistant line carries a `tool_use` whose id has no matching `tool_result` after
    /// it — mirrors `SessionStore.hasUnpairedToolUse`.
    nonisolated private static func hasUnpairedToolUse(_ lines: [LogLine]) -> Bool {
        guard let i = lines.lastIndex(where: { $0.type == "assistant" }) else { return false }
        let toolIds = (lines[i].message?.content?.blocks ?? []).compactMap { $0.type == "tool_use" ? $0.id : nil }
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

    /// Derive a `SessionInfo` from a tail-window of transcript bytes — project/branch/title from the
    /// last lines, state from the SAME shape-based classification `SessionStore.state(of:)` uses locally.
    ///
    /// `mtime` (the file's own modification time, from `findFilesWithMTime`) is the AUTHORITATIVE clock:
    /// a content-parsed timestamp can never legitimately be later than the file's last write, so it's
    /// clamped to `mtime` — a real host was observed where the JSON content's own last real-line
    /// timestamp disagreed with the file's mtime by ~17 hours (see `findFilesWithMTime`'s doc comment),
    /// which without this clamp read a two-day-stale chat as freshly active.
    nonisolated private static func buildSessionInfo(hostId: String, uuid: String, slug: String, tail: Data, mtime: Date) -> SessionInfo? {
        guard let text = String(data: tail, encoding: .utf8) else { return nil }
        let parsed = text.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { LogLine.decode(String($0)) }
        guard !parsed.isEmpty else { return nil }

        var cwd: String?
        var gitBranch: String?
        var title: String?
        for line in parsed {
            if let c = line.cwd, !c.isEmpty { cwd = c }
            if let b = line.gitBranch, !b.isEmpty { gitBranch = b }
            if let t = line.aiTitle, !t.isEmpty { title = t }
            else if let p = line.lastPrompt, !p.isEmpty, title == nil { title = p }
        }
        let project = cwd.map { ($0 as NSString).lastPathComponent } ?? SessionPath.projectName(slug: slug)

        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let isoPlain = Date.ISO8601FormatStyle()
        func parseTS(_ s: String?) -> Date? {
            guard let s else { return nil }
            return (try? iso.parse(s)) ?? (try? isoPlain.parse(s))
        }

        let realLines = parsed.filter { ($0.type == "assistant" || $0.type == "user") && $0.timestamp != nil }
        guard let last = realLines.last, let lastTime = parseTS(last.timestamp) else { return nil }

        var lastRealTimestamp = min(lastTime, mtime)
        var lastShape = shape(of: last)
        // A trailing system api_error retry means the agent is auto-retrying (working) — excluded from
        // `realLines` above (it carries no assistant/user type), so handle it same as `SessionStore`.
        if let lastAny = parsed.last, lastAny.type == "system", lastAny.subtype == "api_error" {
            lastShape = .systemRetry
            if let ts = parseTS(lastAny.timestamp) { lastRealTimestamp = max(lastRealTimestamp, min(ts, mtime)) }
        }

        // The mtime-based freshness gate already ran in `pollOnce` before this function was even called
        // (a stale-by-mtime file is never tailed), so `age > staleWindow` can't happen here — but the
        // clamp above means it's still possible for CONTENT to look older than mtime allows (e.g. a
        // pure-bookkeeping write that touched the file without a new real turn); that's fine, it just
        // means `age` (from the clamped, content-derived timestamp) can exceed `activeWindow` while the
        // file itself is still within `staleWindow`, correctly falling through to `.done`/`.waiting` below.
        let now = Date()
        let age = now.timeIntervalSince(lastRealTimestamp)
        let state: SessionState
        if lastShape == .userToolResult {
            // The assistant still owes its continuation, however long it pauses to "think" between tool
            // calls — this must stay `working` regardless of age (until mtime ages past staleWindow,
            // already excluded by the caller). This is the exact case that was falling through to `.done`
            // before: a long thinking pause after a tool result.
            state = .working
        } else if age <= Tuning.activeWindow, lastShape == .working || lastShape == .systemRetry {
            state = .working
        } else if lastShape == .doneEndTurn {
            state = .done
        } else if hasUnpairedToolUse(parsed) {
            state = .waiting
        } else {
            state = .done
        }

        return SessionInfo(
            id: "remote:\(hostId):\(uuid)", project: project, cwd: cwd, gitBranch: gitBranch, title: title,
            state: state, lastActivity: lastRealTimestamp, remoteHostId: hostId
        )
    }
}
