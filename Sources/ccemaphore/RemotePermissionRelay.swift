import Foundation

/// Real-time relay for permission decisions on remote sessions. No persistent daemon beyond `sshd`:
///
///  - Discovery is POLLED (`Tuning.remotePendingPoll`, ~2s): list+fetch `~/.claude/ccemaphore/pending/
///    *.json` on each enabled host — the exact same `PermissionBroker.PendingRequest` shape the remote
///    hook shim writes (`RemoteHookShim`), so no separate remote-side decode is needed.
///  - The DECISION is relayed in REAL TIME: `decide(host:requestId:decision:)` fires a fresh one-shot SSH
///    command the instant the user clicks Allow/Deny/All, not queued behind the next poll tick — a fresh
///    connection (no session reuse, see `RemoteExec`'s doc comment on why) typically still lands in well
///    under a second on a reachable LAN/VPN host.
@MainActor
final class RemotePermissionRelay: ObservableObject {
    /// requestId -> host that owns it, so a decision made from the ribbon can be routed back without the
    /// caller needing to know which host a given `PendingRequest` came from ahead of time.
    private var requestHosts: [String: RemoteHost] = [:]

    /// Poll every enabled host's pending directory once; returns the current full remote pending set
    /// (across all hosts) via `onUpdate`, tagged with `remoteHostId`.
    func pollAll(onUpdate: @escaping ([PermissionBroker.PendingRequest]) -> Void) {
        let hosts = RemoteHosts.load().filter(\.enabled)
        guard !hosts.isEmpty else { requestHosts.removeAll(); onUpdate([]); return }
        Task { [weak self] in
            var all: [PermissionBroker.PendingRequest] = []
            var fresh: [String: RemoteHost] = [:]
            await withTaskGroup(of: (RemoteHost, [PermissionBroker.PendingRequest]).self) { group in
                for host in hosts {
                    group.addTask {
                        Self.touchBeacon(host: host)
                        return (host, await Self.fetchPending(host: host))
                    }
                }
                for await (host, reqs) in group {
                    for r in reqs { fresh[r.requestId] = host }
                    all.append(contentsOf: reqs)
                }
            }
            // REBUILD (not merge) from this pass's live set: a request that's been decided/consumed since
            // the last poll drops out of the routing map instead of accumulating for the GUI's whole life
            // (F3). The rebuild lands BEFORE onUpdate, so `autoDecideRemote`'s immediate `decide()` for an
            // auto-allowed request still finds its host. A request only leaves the live set once its ribbon
            // is already gone, so no in-flight click can lose its route.
            self?.requestHosts = fresh
            onUpdate(all)
        }
    }

    /// Slack added on top of the shim's own `POLL_TIMEOUT` (240s, `RemoteHookShim.source`'s
    /// `POLL_TIMEOUT`) before we distrust a still-present pending file — covers the round-trip time for
    /// the shim to notice its own deadline and clean up, not a second independent timeout.
    nonisolated private static let staleGraceSeconds: TimeInterval = 30

    /// Touch a per-host liveness beacon the remote hook shim reads (see `RemoteHookShim`'s `beacon_fresh`)
    /// to decide whether it's worth BLOCKING for a decision: a fresh beacon means this Mac is up and
    /// actively polling the host, so a click WILL be relayed; a stale/absent one means nobody will answer,
    /// so the shim hands straight to Claude's native prompt instead of freezing for its full timeout. The
    /// remote analogue of the local `AppPresence` readiness beacon. One tiny extra SSH exec per host per
    /// poll tick — WP7's batching (F6) can later fold it into the same round-trip as the pending glob.
    nonisolated private static func touchBeacon(host: RemoteHost) {
        _ = try? RemoteExec.run(host, command: "mkdir -p ~/.claude/ccemaphore && touch ~/.claude/ccemaphore/mac-beacon")
    }

    nonisolated private static func fetchPending(host: RemoteHost) async -> [PermissionBroker.PendingRequest] {
        guard let names = try? RemoteExec.listGlob(host, glob: "~/.claude/ccemaphore/pending/*.json") else { return [] }
        // Which requests already have a `.decision` written (by our relay) that the shim hasn't consumed
        // yet — skip them so a just-clicked ribbon can't flash back in the gap before the remote cleanup
        // lands (the local `listPending` skip-decided rule, bug3a, now applied remotely too). One extra
        // glob per poll.
        let decidedIds = Set(((try? RemoteExec.listGlob(host, glob: "~/.claude/ccemaphore/pending/*.decision")) ?? [])
            .map { ($0 as NSString).lastPathComponent }
            .filter { $0.hasSuffix(".decision") }
            .map { String($0.dropLast(".decision".count)) })
        var out: [PermissionBroker.PendingRequest] = []
        let decoder = JSONDecoder()
        let now = Date()
        for name in names {
            guard let data = try? RemoteExec.readFile(host, path: name),
                  var req = try? decoder.decode(PermissionBroker.PendingRequest.self, from: data) else { continue }
            // Shared liveness predicate: skip a decided-but-not-consumed request, and age out an orphan the
            // owning shim never cleaned up (it gives up after its own POLL_TIMEOUT; +grace covers the
            // round-trip). Identical rules to local `listPending` via `PermissionBroker.isPendingLive`.
            guard PermissionBroker.isPendingLive(
                    createdAt: req.createdAt,
                    staleAfter: Tuning.permissionPollTimeout + staleGraceSeconds,
                    hasDecision: decidedIds.contains(req.requestId), now: now)
            else { continue }
            req.remoteHostId = host.id
            // The remote hook shim only knows the plain transcript uuid — namespace it to match
            // `SessionInfo.id` for this session (see `PendingRequest.sessionId`'s doc comment), so
            // `StateEngine.render()`'s "a live pending request forces its session red" rule actually
            // finds this session in `byId` instead of silently missing a differently-shaped key.
            req.sessionId = SessionInfo.remoteID(hostId: host.id, uuid: req.sessionId)
            out.append(req)
        }
        return out
    }

    /// Relay the user's decision immediately over a fresh SSH round-trip — see type doc. Retries once on
    /// failure since a click must never silently vanish while the remote hook is still blocking.
    func decide(requestId: String, decision: PermissionBroker.Decision, onFailure: ((String) -> Void)? = nil) {
        guard let host = requestHosts[requestId] else { return }
        let path = "~/.claude/ccemaphore/pending/\(requestId).decision"
        Task {
            for attempt in 0..<2 {
                do {
                    try await Self.writeDecision(host: host, path: path, decision: decision)
                    return
                } catch {
                    if attempt == 1 { onFailure?(error.localizedDescription) }
                }
            }
        }
    }

    nonisolated private static func writeDecision(host: RemoteHost, path: String, decision: PermissionBroker.Decision) async throws {
        try RemoteExec.writeFile(host, path: path, data: Data(decision.rawValue.utf8))
    }
}
