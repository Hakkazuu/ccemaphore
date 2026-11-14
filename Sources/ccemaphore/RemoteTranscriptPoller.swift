import Foundation

/// Remote analogue of the local FSEvents-driven transcript watch (`TranscriptWatcher`) — there is no
/// kernel API to watch a directory over SSH, so this polls each enabled `RemoteHost` on
/// `Tuning.remotePollInterval`, entirely decoupled from `StateEngine`'s local `stateTick` so one slow or
/// unreachable host can never stall local rendering.
///
/// Claude transcripts and Codex rollouts are both polled over SSH. Claude sub-agent/workflow fan-out is
/// local-only; Codex rollout parsing uses the shared classifier and remote Codex hook status is read from
/// the same status directory as Claude's.
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
    /// Latest RAW mode-B status rows per host, keyed by the namespaced id and tagged with `remoteHostId`.
    /// `StateEngine.render()` folds these into `statusBySession` so remote sessions go through the identical
    /// hook-status merge (suppressDone / demote / native-wait / compacting) as local — no more the
    /// unconditional overlay this poller used to force-apply (which false-greened a still-working chat).
    private(set) var lastStatuses: [String: [String: StatusEntry]] = [:]   // hostId -> (namespaced id -> entry)
    /// Hosts with a poll still in flight. A slow/unreachable host's SSH round-trip can outlast the poll
    /// interval; without this guard the timer would stack a second (third…) concurrent poll on the same
    /// host, multiplying SSH load on exactly the host least able to bear it. Skip a host already polling
    /// (V6). MainActor-isolated, so insert/remove need no extra synchronization.
    private var polling: Set<String> = []

    /// Per-host parse cache keyed by transcript path (F1): the decoded `[LogLine]` of a file whose mtime
    /// hasn't changed since the last poll. A cache hit means the poll neither FETCHES that file's tail
    /// (`batchTails` only requests the changed set) NOR re-decodes its JSON — only the age-dependent state
    /// is recomputed each tick. Rebuilt every poll from the current fresh set, so gone/aged-out files
    /// evict automatically. Pruned per host by `prune(hostId:)`.
    struct CacheEntry { let mtime: Date; let parsed: [LogLine] }
    private var pollCache: [String: [String: CacheEntry]] = [:]   // hostId -> (path -> entry)

    struct CodexCacheEntry: Sendable {
        let mtime: Date
        let tail: CodexTail
        let meta: CodexRolloutMeta
        let catalog: RemoteExec.CodexCatalogRow?
    }
    private var codexPollCache: [String: [String: CodexCacheEntry]] = [:]

    /// Drop one host's cached rows from every merge buffer so a subsequent `StateEngine.render()` re-fold
    /// can't resurrect its sessions after the host was removed. Keyed by `RemoteHost.id`; only that host's
    /// namespaced (`remote:<id>:*`) entries are touched — local state is never addressed here (V19).
    func prune(hostId: String) {
        lastSessions.removeValue(forKey: hostId)
        lastStatuses.removeValue(forKey: hostId)
        hostStatuses.removeValue(forKey: hostId)
        pollCache.removeValue(forKey: hostId)
        codexPollCache.removeValue(forKey: hostId)
    }

    /// Poll every enabled host once. Safe to call repeatedly on a timer; each host's failure is isolated
    /// (a dead host never throws for the others) and recorded in `hostStatuses` for the UI.
    func pollAll(onUpdate: @escaping () -> Void) {
        let hosts = RemoteHosts.load().filter(\.enabled)
        for host in hosts where !polling.contains(host.id) {
            polling.insert(host.id)
            Task { [weak self] in
                guard let self else { return }
                let result = await self.pollOnce(host: host)
                self.polling.remove(host.id)
                switch result {
                case .success(let (infos, statuses)):
                    self.lastSessions[host.id] = Dictionary(uniqueKeysWithValues: infos.map { ($0.id, $0) })
                    self.lastStatuses[host.id] = statuses
                    self.hostStatuses[host.id] = HostStatus(connected: true, lastSuccess: Date(), lastError: nil)
                case .failure(let error):
                    // Leave lastSessions/lastStatuses frozen — render() marks them offline (not stale) so
                    // the host's chats stay visible with an explicit "offline" indicator rather than
                    // vanishing, and don't pin the aggregate light.
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
        lastStatuses = lastStatuses.filter { liveIds.contains($0.key) }
        hostStatuses = hostStatuses.filter { liveIds.contains($0.key) }
        pollCache = pollCache.filter { liveIds.contains($0.key) }
        codexPollCache = codexPollCache.filter { liveIds.contains($0.key) }
    }

    /// One poll of a single host — also the implementation behind `--remote-scan`. Two ssh round-trips at
    /// most (F6): a metadata batch (fresh mtimes + all status blobs) and, only for files whose mtime moved
    /// since the last poll, a tails batch (F1). An idle-but-recent host therefore costs ONE ssh and zero
    /// re-parsing per tick. Each batch falls back to the legacy per-call path if the host's shell can't
    /// run it, so a remote quirk degrades to the proven path instead of breaking the feature. The blocking
    /// SSH work runs off the main actor; the cache read/write and the (decode-free, cheap) build stay on it.
    func pollOnce(host: RemoteHost) async -> Result<(sessions: [SessionInfo], statuses: [String: StatusEntry]), RemoteExec.SSHError> {
        let root = host.remoteProjectsRoot ?? "~/.claude/projects"
        let mins = Int(Tuning.staleWindow / 60)

        // Phase 1 (off-actor): metadata batch, legacy fallback. `-mmin` filters freshness ON THE SERVER
        // (F2) in the remote's clock domain — old history never crosses the wire, no cross-machine skew.
        let meta: RemoteExec.BatchMeta
        do {
            meta = try await Task.detached(priority: .utility) {
                if let m = try? RemoteExec.batchMeta(host, root: root, staleMinutes: mins) { return m }
                return try Self.legacyMeta(host: host, root: root, staleMinutes: mins)
            }.value
        } catch let e as RemoteExec.SSHError {
            return .failure(e)
        } catch {
            return .failure(RemoteExec.SSHError(message: error.localizedDescription, exitCode: -1))
        }

        // Diff mtimes against the cache: only new files or ones whose mtime moved need a tail this tick.
        let cache = pollCache[host.id] ?? [:]
        let changed = meta.files.filter { cache[$0.path]?.mtime != $0.mtime }.map(\.path)

        // Phase 2 (off-actor): tails of ONLY the changed set, decoded off the main actor so a first poll
        // (everything "changed") can't jank the UI. Skipped entirely when nothing changed. Legacy per-file
        // `tailFile` fallback keyed by path.
        var freshParsed: [String: [LogLine]] = [:]
        if !changed.isEmpty {
            freshParsed = await Task.detached(priority: .utility) {
                let tails: [String: Data] = (try? RemoteExec.batchTails(host, paths: changed)) ?? {
                    var m: [String: Data] = [:]
                    for p in changed where m[p] == nil {
                        if let d = try? RemoteExec.tailFile(host, path: p, window: 512 * 1024) { m[p] = d }
                    }
                    return m
                }()
                var out: [String: [LogLine]] = [:]
                for (p, d) in tails where !d.isEmpty { out[p] = Self.decodeTail(d) }
                return out
            }.value
        }

        // Build sessions. Unchanged → cached parse (F1: neither fetched nor re-decoded); changed → the
        // freshly-decoded parse. State is re-derived every tick from the parse + the current time.
        var byId: [String: SessionInfo] = [:]
        var newCache: [String: CacheEntry] = [:]
        for f in meta.files {
            guard let (uuid, slug) = Self.topLevelSessionId(path: f.path, root: root) else { continue }
            let parsed: [LogLine]
            if let c = cache[f.path], c.mtime == f.mtime { parsed = c.parsed }
            else if let p = freshParsed[f.path] { parsed = p }
            else { continue }   // changed but the tail fetch missed it this tick — retry on the next
            newCache[f.path] = CacheEntry(mtime: f.mtime, parsed: parsed)
            if let info = Self.buildSessionInfo(hostId: host.id, uuid: uuid, slug: slug, parsed: parsed, mtime: f.mtime) {
                byId[info.id] = info
            }
        }
        pollCache[host.id] = newCache   // files no longer fresh drop out of the cache (eviction)

        // Codex stores rollouts independently under ~/.codex/sessions. The current local reader also
        // tracks open writer locks, which aren't safely queryable through a portable shell; remote mode
        // discovers files written in the last three days and uses the shared rollout parser/classifier.
        let codexMetaFiles: [RemoteExec.BatchMeta.FileMeta]
        do {
            codexMetaFiles = try await Task.detached(priority: .utility) {
                try RemoteExec.findFilesWithMTime(host, root: "~/.codex/sessions", namePattern: "rollout-*.jsonl",
                                                  newerThanMinutes: 3 * 24 * 60)
                    .map { .init(path: $0.path, mtime: $0.mtime) }
            }.value
        } catch let e as RemoteExec.SSHError {
            // Codex isn't installed on every Claude remote. A missing directory is an empty result;
            // preserve Claude's successful poll if a host has an unusual find/stat implementation.
            _ = e
            codexMetaFiles = []
        } catch {
            codexMetaFiles = []
        }
        let codexCache = codexPollCache[host.id] ?? [:]
        let codexChanged = codexMetaFiles.filter { codexCache[$0.path]?.mtime != $0.mtime }.map(\.path)
        var freshCodex: [String: CodexCacheEntry] = [:]
        if !codexChanged.isEmpty {
            freshCodex = await Task.detached(priority: .utility) {
                let threadIds = Dictionary(uniqueKeysWithValues: codexChanged.compactMap { path -> (String, String)? in
                    guard let threadId = CodexPaths.threadId(fromRolloutName: (path as NSString).lastPathComponent) else { return nil }
                    return (path, threadId)
                })
                guard let files = try? RemoteExec.batchCodexFiles(host, paths: codexChanged, threadIds: threadIds) else { return [:] }
                var parsed: [String: CodexCacheEntry] = [:]
                let mtimes = Dictionary(uniqueKeysWithValues: codexMetaFiles.map { ($0.path, $0.mtime) })
                for path in codexChanged {
                    guard let remote = files[path], !remote.meta.isEmpty, !remote.tail.isEmpty,
                          let mtime = mtimes[path], let rolloutMeta = CodexRolloutParser.readMeta(data: remote.meta) else { continue }
                    let lines = TailReader.completeLines(inWindow: remote.tail,
                                                        seekedIntoMiddle: remote.size > UInt64(remote.tail.count))
                    var tail = CodexRolloutParser.parseTail(lines: lines)
                    // File mtime is the remote kernel's clock and bounds any stale/future timestamp in
                    // the rollout content, matching the Claude remote reader's clock handling.
                    if let activity = tail.lastActivity { tail.lastActivity = min(activity, mtime) }
                    parsed[path] = CodexCacheEntry(mtime: mtime, tail: tail, meta: rolloutMeta,
                                                   catalog: remote.catalog)
                }
                return parsed
            }.value
        }
        var newCodexCache: [String: CodexCacheEntry] = [:]
        typealias LiveCodex = (threadId: String, entry: CodexCacheEntry, activity: Date,
                               state: SessionState, isImport: Bool)
        var codexParents: [LiveCodex] = []
        var codexChildren: [String: [LiveCodex]] = [:]
        let now = Date()
        for file in codexMetaFiles {
            guard let entry = freshCodex[file.path] ?? codexCache[file.path], entry.mtime == file.mtime,
                  let threadId = CodexPaths.threadId(fromRolloutName: (file.path as NSString).lastPathComponent),
                  let activity = entry.tail.lastActivity else { continue }
            newCodexCache[file.path] = entry
            let isImport = entry.tail.importMarkerSeen
            if isImport && !entry.tail.nativeTurnSeen { continue }
            let state = CodexRolloutParser.state(of: entry.tail, now: now, lockHeld: nil)
            let parentId = entry.catalog?.parentThreadId ?? entry.meta.parentThreadId
            let isSubagent = entry.catalog?.isSubagent == true || entry.meta.isSubagent
            if isSubagent {
                if let parentId {
                    codexChildren[parentId, default: []].append((threadId, entry, activity, state, isImport))
                }
                continue
            }
            codexParents.append((threadId, entry, activity, state, isImport))
        }

        for parent in codexParents {
            let threadId = parent.threadId
            let entry = parent.entry
            let isImport = parent.isImport
            var state = parent.state
            var lastActivity = parent.activity
            var children: [ChildAgent] = []
            for child in codexChildren[threadId] ?? [] where child.state != .stale {
                let childEntry = child.entry
                let nick = childEntry.catalog?.agentNickname ?? childEntry.meta.agentNickname
                let title = childEntry.catalog?.title ?? childEntry.tail.lastUserMessage.map(Self.truncateCodexTitle)
                children.append(ChildAgent(
                    id: SessionInfo.remoteCodexID(hostId: host.id, threadId: child.threadId),
                    name: nick ?? title ?? String(child.threadId.prefix(8)),
                    kind: .codexSubagent,
                    state: child.state,
                    lastActivity: child.activity,
                    title: title,
                    purpose: CodexSessionStore.taskName(childEntry.meta.agentPath),
                    who: nick,
                    activity: childEntry.tail.lastAction))
                if child.state == .working, now.timeIntervalSince(child.activity) <= Tuning.subagentGrace {
                    state = .working
                    lastActivity = max(lastActivity, child.activity)
                }
            }
            if state == .stale { continue }
            if state == .done, now.timeIntervalSince(lastActivity) > Tuning.activeWindow { continue }
            let cwd = entry.tail.cwd ?? entry.meta.cwd ?? entry.tail.workspaceRoots.first
            let project = cwd.map { ($0 as NSString).lastPathComponent } ?? "Codex"
            let id = SessionInfo.remoteCodexID(hostId: host.id, threadId: threadId)
            let title = entry.catalog?.title ?? entry.tail.lastUserMessage.map(Self.truncateCodexTitle)
            var info = SessionInfo(id: id, project: project, cwd: cwd,
                                   gitBranch: entry.meta.gitBranch,
                                   title: title,
                                   state: state, lastActivity: lastActivity, context: entry.tail.context)
            info.agent = .codex
            info.origin = isImport ? .claude : .codex
            info.host = entry.meta.host ?? .codexApp
            info.hostBundleId = info.host == .codexApp ? DeepLinker.codexAppBundleId : nil
            info.remoteHostId = host.id
            info.rateLimits = entry.tail.rateLimits
            info.children = children.sorted { $0.lastActivity > $1.lastActivity }
            byId[id] = info
        }
        codexPollCache[host.id] = newCodexCache

        // RAW mode-B status rows — NO overlay here (this path used to force-apply hook state, which
        // false-greened a Stop'd-but-still-working workflow chat, V2). StateEngine.render() folds these
        // into the SAME statusBySession merge the local hooks use (suppressDone / demote / native-wait /
        // compacting), with the staleness gate applied uniformly there. Namespaced + tagged with the host.
        var statuses: [String: StatusEntry] = [:]
        for blob in meta.statuses {
            guard var entry = StatusReader.parse(data: blob.content) else { continue }
            entry.remoteHostId = host.id
            statuses[SessionInfo.remoteID(hostId: host.id, uuid: entry.id)] = entry
        }

        // Codex hook ids are `codex:<thread>` and therefore intentionally stay out of StateEngine's
        // Claude status merge. Fold the one Codex hook state that decorates a remote Codex row here,
        // using the same freshness/working guards as CodexHookOverlay. The hook file is fetched in the
        // metadata batch above; no extra SSH round-trip is needed.
        for (id, status) in statuses where status.agent == .codex && status.isCompacting {
            guard now.timeIntervalSince(status.updatedAt) <= Tuning.staleWindow,
                  var session = byId[id], session.agent == .codex, session.state == .working,
                  session.lastActivity <= status.updatedAt.addingTimeInterval(CodexHookOverlay.resolveGrace)
            else { continue }
            session.isCompacting = true
            byId[id] = session
        }
        return .success((sessions: Array(byId.values), statuses: statuses))
    }

    nonisolated private static func truncateCodexTitle(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > 120 ? String(clean.prefix(119)) + "…" : clean
    }

    /// Legacy fallback for Phase 1 when `batchMeta`'s script can't run on a host: the original find +
    /// status-glob + per-file read path, assembled into the same `BatchMeta` shape. Throws (host offline)
    /// exactly like the old `pollOnce`, so `.failure` semantics are preserved.
    nonisolated private static func legacyMeta(host: RemoteHost, root: String, staleMinutes: Int) throws -> RemoteExec.BatchMeta {
        var meta = RemoteExec.BatchMeta()
        meta.files = try RemoteExec.findFilesWithMTime(host, root: root, namePattern: "*.jsonl",
                                                       newerThanMinutes: staleMinutes)
            .map { .init(path: $0.path, mtime: $0.mtime) }
        if let statusFiles = try? RemoteExec.listGlob(host, glob: "~/.claude/status/*.json") {
            for sp in statusFiles {
                guard let d = try? RemoteExec.readFile(host, path: sp), !d.isEmpty else { continue }
                meta.statuses.append(.init(path: sp, content: d))
            }
        }
        return meta
    }

    /// The byte-safe tail decode (V24), factored out so the F1 cache can hold the decoded `[LogLine]`.
    nonisolated static func decodeTail(_ tail: Data) -> [LogLine] {
        TailReader.completeLines(inWindow: tail, seekedIntoMiddle: tail.count >= 512 * 1024)
            .compactMap(LogLine.decode)
    }

    /// `<root>/<slug>/<uuid>.jsonl` → (uuid, slug); nil for anything deeper (sub-agent/workflow paths,
    /// out of scope for remote polling — see type doc).
    nonisolated private static func topLevelSessionId(path: String, root: String) -> (uuid: String, slug: String)? {
        // `find` output on the remote is $HOME-expanded while `root` is tilde-form, so match the
        // tilde-stripped root as a directory prefix — require the trailing slash (anchored more than a
        // bare substring). Only `<root>/<slug>/<uuid>.jsonl` is a top-level session; exclude journal.jsonl
        // and reject non-UUID names, matching SessionPath.classify's `.session` rule. (Full delegation to
        // SessionPath.classify(root:) lands with WP7, which resolves the expanded remote $HOME as part of
        // the batched poll.)
        let normalizedRoot = root.hasPrefix("~") ? String(root.dropFirst()) : root
        guard let range = path.range(of: normalizedRoot + "/") else { return nil }
        let comps = String(path[range.upperBound...]).split(separator: "/").map(String.init)
        guard comps.count == 2, comps[1].hasSuffix(".jsonl"), comps[1] != "journal.jsonl" else { return nil }
        let uuid = String(comps[1].dropLast(".jsonl".count))
        guard SessionPath.isUUID(uuid) else { return nil }
        return (uuid, comps[0])
    }

    /// Derive a `SessionInfo` from a tail-window of transcript bytes — project/branch/title from the
    /// last lines, state from the SAME shared `TailClassifier` ladder the local `SessionStore` uses.
    ///
    /// `mtime` (the file's own modification time, from `findFilesWithMTime`) is the AUTHORITATIVE clock:
    /// a content-parsed timestamp can never legitimately be later than the file's last write, so it's
    /// clamped to `mtime` — a real host was observed where the JSON content's own last real-line
    /// timestamp disagreed with the file's mtime by ~17 hours (see `findFilesWithMTime`'s doc comment),
    /// which without this clamp read a two-day-stale chat as freshly active.
    nonisolated private static func buildSessionInfo(hostId: String, uuid: String, slug: String, parsed: [LogLine], mtime: Date) -> SessionInfo? {
        // `parsed` is the byte-safe tail decode (see `decodeTail`) — reused from the F1 cache on an
        // unchanged file, so this builder is decode-free and cheap enough to run every tick (state is
        // age-dependent, so it must be re-derived here rather than cached).
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

        func parseTS(_ s: String?) -> Date? {
            guard let s else { return nil }
            return ISOTime.parse(s)
        }

        let realLines = parsed.filter { ($0.type == "assistant" || $0.type == "user") && $0.timestamp != nil }
        guard let last = realLines.last, let lastTime = parseTS(last.timestamp) else { return nil }

        var lastRealTimestamp = min(lastTime, mtime)
        var lastShape = TailClassifier.shape(of: last)
        // A trailing system api_error retry means the agent is auto-retrying (working) — excluded from
        // `realLines` above (it carries no assistant/user type), so handle it same as `SessionStore`.
        if let lastAny = parsed.last, lastAny.type == "system", lastAny.subtype == "api_error" {
            lastShape = .systemRetry
            if let ts = parseTS(lastAny.timestamp) { lastRealTimestamp = max(lastRealTimestamp, min(ts, mtime)) }
        }

        // pollOnce already mtime-gated this file to within staleWindow (a stale-by-mtime file is never
        // tailed), so there is no `.stale` branch; the content timestamp is clamped to mtime above, so
        // `age` can still exceed `activeWindow` (a pure-bookkeeping write), correctly settling to
        // `.done`/`.waiting`. Same shared ladder as local (TailClassifier).
        let age = Date().timeIntervalSince(lastRealTimestamp)
        let state = TailClassifier.classify(
            shape: lastShape, age: age, hasUnpaired: TailClassifier.hasUnpairedToolUse(parsed),
            activeWindow: Tuning.activeWindow)

        return SessionInfo(
            id: SessionInfo.remoteID(hostId: hostId, uuid: uuid), project: project, cwd: cwd,
            gitBranch: gitBranch, title: title,
            state: state, lastActivity: lastRealTimestamp, remoteHostId: hostId
        )
    }
}
