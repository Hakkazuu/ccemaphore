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
        guard !hosts.isEmpty else { onUpdate([]); return }
        Task { [weak self] in
            var all: [PermissionBroker.PendingRequest] = []
            await withTaskGroup(of: (RemoteHost, [PermissionBroker.PendingRequest]).self) { group in
                for host in hosts {
                    group.addTask { (host, await Self.fetchPending(host: host)) }
                }
                for await (host, reqs) in group {
                    self?.requestHosts.merge(reqs.map { ($0.requestId, host) }, uniquingKeysWith: { a, _ in a })
                    all.append(contentsOf: reqs)
                }
            }
            onUpdate(all)
        }
    }

    /// Slack added on top of the shim's own `POLL_TIMEOUT` (240s, `RemoteHookShim.source`'s
    /// `POLL_TIMEOUT`) before we distrust a still-present pending file — covers the round-trip time for
    /// the shim to notice its own deadline and clean up, not a second independent timeout.
    nonisolated private static let staleGraceSeconds: TimeInterval = 30

    nonisolated private static func fetchPending(host: RemoteHost) async -> [PermissionBroker.PendingRequest] {
        guard let names = try? RemoteExec.listGlob(host, glob: "~/.claude/ccemaphore/pending/*.json") else { return [] }
        var out: [PermissionBroker.PendingRequest] = []
        let decoder = JSONDecoder()
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let isoPlain = Date.ISO8601FormatStyle()
        let now = Date()
        for name in names {
            guard let data = try? RemoteExec.readFile(host, path: name),
                  var req = try? decoder.decode(PermissionBroker.PendingRequest.self, from: data) else { continue }
            // The remote hook process that owns this file gives up after `Tuning.permissionPollTimeout`
            // (240s) no matter what — so a file OLDER than that (+ a little slack) can only be a leftover
            // the owning python process never got to clean up (SIGKILLed, host lost power, etc.), not a
            // genuinely still-blocking wait. Without this check, a phantom pending request could sit in
            // the ribbon (with live-looking Allow/Deny buttons that do nothing, since nothing is listening
            // on the remote end anymore) forever — this is what was observed live.
            if let created = (try? iso.parse(req.createdAt)) ?? (try? isoPlain.parse(req.createdAt)),
               now.timeIntervalSince(created) > Tuning.permissionPollTimeout + staleGraceSeconds {
                continue
            }
            req.remoteHostId = host.id
            // The remote hook shim only knows the plain transcript uuid — namespace it to match
            // `SessionInfo.id` for this session (see `PendingRequest.sessionId`'s doc comment), so
            // `StateEngine.render()`'s "a live pending request forces its session red" rule actually
            // finds this session in `byId` instead of silently missing a differently-shaped key.
            req.sessionId = "remote:\(host.id):\(req.sessionId)"
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
