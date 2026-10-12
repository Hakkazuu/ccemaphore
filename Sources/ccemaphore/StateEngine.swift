import SwiftUI

/// Drives the UI: wires the FSEvents watcher + periodic timers into the `SessionStore` and
/// `UsageProvider`, and publishes the session list (with tokens), aggregate color, and daily history.
@MainActor
final class StateEngine: ObservableObject {
    /// Single shared instance — the menu-bar content and the history window observe the same engine.
    static let shared = StateEngine()

    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var color: AggregateColor = .gray
    @Published private(set) var days: [DayStat] = []
    @Published private(set) var hooksInstalled = false
    @Published private(set) var permissionHookInstalled = false
    /// Accessibility trust (System Settings ▸ Privacy ▸ Accessibility). Kept for the `--ax-dump`
    /// diagnostic and any future per-tab feature; the notification-suppression path it once fed was
    /// removed with the toasts. Cheap to query, so it's refreshed on the tick.
    @Published private(set) var accessibilityGranted = false
    /// Non-nil when the last hook install/uninstall failed — surfaced in the popover so a failed
    /// write to the user's settings.json is never a silent no-op. Kept unrendered (`message`), so the
    /// note on screen follows a language switch.
    @Published private(set) var lastHookError: HookOpError?

    /// Why the last hook install / uninstall didn't happen.
    enum HookOpError {
        /// Refused: running from the mounted DMG / an App Translocation copy.
        case blockedTransient
        /// The `op.*` operation `opKey` threw `error`.
        case failed(opKey: String, error: Error)

        /// The panel text in the current language (a system error's own text follows the macOS language).
        var message: String {
            switch self {
            case .blockedTransient: return L("settings.hooks.blockedTransient")
            case .failed(let opKey, let error): return Lf("error.hookOp", L(opKey), error.localizedDescription)
            }
        }
    }
    /// Interactive permission requests the broker hook is currently blocking on. Rendered in the popover
    /// as actionable [Allow once]/[Allow all]/[Deny] rows — a reliable surface that doesn't depend on
    /// catching a transient banner. Newest first.
    @Published private(set) var pendingRequests: [PermissionBroker.PendingRequest] = []
    /// Chats parked on a native prompt (a handed-off permission or a question tool) — surfaced as the
    /// informational "→ open chat" ribbon that persists until answered. See `AttentionItem`.
    @Published private(set) var attentionSessions: [AttentionItem] = []
    /// Transient "this chat just finished" notices — the green completion ribbon at the light (the
    /// in-widget replacement for the old done toast). Fired on the →done edge, auto-expiring. Newest first.
    @Published private(set) var completionNotices: [CompletionNotice] = []
    /// User-curated commands the permission hook auto-approves (no dialog, no ribbon). Surfaced + edited
    /// in Настройки; the hook reads the backing `trusted.json` directly on each call. See `TrustedCommands`.
    @Published private(set) var trustedCommands: [TrustedCommands.Entry] = []
    /// Per-host connection status for the "Remote Hosts" UI (connected/error/last-seen). Keyed by
    /// `RemoteHost.id`. Populated by `remotePoller`'s poll loop — see `Tuning.remotePollInterval`.
    @Published private(set) var remoteHostStatuses: [String: RemoteTranscriptPoller.HostStatus] = [:]
    /// The configured remote host list, for the "Remote Hosts" settings section — reloaded after every
    /// CRUD op so the UI (a plain value list, not a live file watch) stays in sync with `remote_hosts.json`.
    @Published private(set) var remoteHosts: [RemoteHost] = []
    /// Per-host "Test Connection" outcome, keyed by `RemoteHost.id` — transient UI feedback, not persisted.
    @Published private(set) var remoteTestResults: [String: Result<String, RemoteExec.SSHError>] = [:]
    /// Outcome of an async remote hook install, in a Sendable form so it can cross the `Task.detached`
    /// boundary that runs the blocking ssh work (a bare `any Error` isn't Sendable). Carries the failure
    /// message for the row's red caption; `.installed` drives the green one.
    enum RemoteHookInstallResult: Sendable { case installed; case failed(String) }
    /// Per-host "Install hooks" outcome, keyed by `RemoteHost.id` — transient UI feedback (V27), so the
    /// button no longer looks like it silently did nothing. Not persisted.
    @Published private(set) var remoteHooksInstallResults: [String: RemoteHookInstallResult] = [:]
    /// False when `~/.claude/projects` doesn't exist — Claude Code was never installed (or never run) on
    /// this machine, so an empty session list means "nothing to watch", not "all quiet". Drives the
    /// panel's "Claude Code не найден" hint. Specifically the projects dir, NOT `~/.claude`: we create
    /// the latter ourselves (status dir, presence beacon, hook install), so it proves nothing. No
    /// re-arm needed on install: FSEvents happily pre-arms on a nonexistent path (verified empirically)
    /// and fires once Claude Code first runs, so the tick + event re-checks flip this back promptly.
    @Published private(set) var claudeInstalled = true
    /// False until `~/.codex` shows signs of Codex (live rollout tree or state DB). Drives the Codex
    /// settings row's caption; nothing Codex-side is watched while false. Re-checked on the tick so a
    /// first Codex run after launch starts the watchers without a restart.
    @Published private(set) var codexInstalled = false
    /// ChatGPT.app's own sidebar projects (`projects` + `project_roots`) — the seed for product groups.
    @Published private(set) var codexProjects: [CodexProject] = []
    /// Live (pid-alive) entries in Claude Code's session registry — the diagnostics row's count.
    @Published private(set) var registryLiveCount = 0
    /// Codex hooks (`~/.codex/hooks.json`): installed / permission hook / Codex's trust verdict for the
    /// current file bytes (see `CodexHooksInstaller.trustState`). Trust is re-read on the tick because the
    /// user grants it inside the ChatGPT app, outside our process.
    @Published private(set) var codexHooksInstalled = false
    @Published private(set) var codexPermissionHookInstalled = false
    @Published private(set) var codexHooksTrust: CodexHooksInstaller.TrustState = .notInstalled
    /// Effective product groups (manual ∪ Codex projects ∪ auto), recomputed on every render from the
    /// live session set; `manualGroups` is the user-edited subset the settings list shows with ✕.
    @Published private(set) var productGroups: [ProductGroup] = []
    @Published private(set) var manualGroups: [ProductGroup] = []

    private let store = SessionStore()
    private let codexStore = CodexSessionStore()
    /// Latest Codex snapshot (mode A for Codex), folded into `render()` under `codex:<id>` keys.
    private var codexSessions: [SessionInfo] = []
    /// Each source has completed its first full scan. `render()` prunes the remembered expanded-row set
    /// only after that: the launch-time renders triggered by the status/registry refreshes run BEFORE the
    /// transcript ingest lands and would otherwise wipe the persisted set on every launch.
    private var firstClaudeScanDone = false
    private var firstCodexScanDone = false
    /// Claude Code's own session registry, keyed by session id (see `SessionRegistryReader`).
    private var registry: [String: RegistryEntry] = [:]
    private var registryWatcher: TranscriptWatcher?
    private var codexWatcher: TranscriptWatcher?
    private var codexLockWatcher: TranscriptWatcher?
    private let usage = UsageProvider()
    private let remotePoller = RemoteTranscriptPoller()
    private let remotePermissionRelay = RemotePermissionRelay()
    private var watcher: TranscriptWatcher?
    private var statusWatcher: TranscriptWatcher?
    private var pendingWatcher: TranscriptWatcher?
    private var stateTimer: Timer?
    private var usageTimer: Timer?
    private var remotePollTimer: Timer?
    private var remotePendingTimer: Timer?
    /// Latest remote pending requests (all hosts), merged into `pendingRequests` on every render.
    private var remotePendingRequests: [PermissionBroker.PendingRequest] = []
    /// Latest LOCAL pending requests, kept separately so `recomputePending` can merge it with
    /// `remotePendingRequests` without either poll loop clobbering the other's contribution.
    private var localPendingRequests: [PermissionBroker.PendingRequest] = []
    /// Namespaced remote session ids the user has blessed with "Allow all in chat". The remote hook shim
    /// deliberately keeps NO allow-all/trusted memory of its own (unlike the local broker's in-hook
    /// short-circuit) — that authority lives here, on the Mac: `autoDecideRemote` relays an instant
    /// `allow` for any subsequently-polled request from one of these sessions (or one matching a trusted
    /// command), before it ever reaches a ribbon. The remote parity of `PermissionBroker.isAllowAll` /
    /// `TrustedCommands.isTrusted`. Pruned per-host by `removeRemoteHost`.
    private var remoteAllowAll: Set<String> = []
    /// Runs only while `watchIDELog` is on AND a pending request has a `toolUseId` — polls the IDE log to
    /// drop the ribbon the moment the user answers in the IDE's own dialog. See `IDELogWatcher`.
    private var ideLogTimer: Timer?
    /// Per-toolUseId poll counters + a one-shot warn guard for the IDE-log canary (see `pollIDELog`):
    /// if we poll many rounds for a request that never resolves via the IDE log while a FRESH log lacks
    /// the dispatch marker, Cursor likely changed the format → warn once (with samples). Cleared on disarm.
    private var ideLogPolls: [String: Int] = [:]
    private var ideLogWarned: Set<String> = []
    private static let ideLogCanaryPolls = 8   // ~8s at Tuning.ideLogPoll before flagging a likely format change

    private let staleWindow = Tuning.staleWindow

    private var rawSessions: [SessionInfo] = []
    private var usageBySession: [String: TokenUsage] = [:]
    private var statusBySession: [String: StatusEntry] = [:]

    /// Sessions with a live broker permission request — kept so `render()` can force them red (ground
    /// truth) and `decidePermission` can clear them. (The done/waiting-notification bookkeeping that
    /// used to live here was removed with the toast notifications.)
    private var activePendingSessions: Set<String> = []

    /// Broker "native wait" status events — the chat is genuinely blocked on the user in Cursor's OWN
    /// dialog: a question tool (`question-native`, no allow/deny to make) or a handed-off permission
    /// (`permission-native`, the wait window elapsed / widget hidden). These carry NO pending file, so
    /// they are NOT in `activePendingSessions` — yet they are just as much GROUND TRUTH. `render()` must
    /// force them red, or mode A's still-warm "working" tail (an unpaired tool_use reads `working` for
    /// `activeWindow` seconds) clobbers them via the fresher-wins merge (that race showed as a red flash
    /// that vanished for ~60 s, then reappeared once mode A's tail finally cooled to `waiting`). See the
    /// taxonomy in docs/permission-and-waiting-fixes-plan.md. Kept in sync with the broker's
    /// `brokerStatusEvents` and the `AttentionItem` kinds below.
    private static let nativeWaitEvents: Set<String> = ["question-native", "permission-native"]

    /// Per-chat state as of the last render, so `manageCompletions` can fire a done notice exactly on the
    /// working/waiting → done EDGE. `completionSeeded` suppresses the first render (don't announce chats
    /// already finished at launch); `lastCompletionFiredAt` debounces a flapping chat.
    private var lastDisplayState: [String: SessionState] = [:]
    private var completionSeeded = false
    private var lastCompletionFiredAt: [String: Date] = [:]

    init() {
        start()
    }

    private func start() {
        let root = SessionPath.projectsRoot
        refreshClaudePresence()

        // Initial state scan + initial usage fetch (independent). The Task inherits this @MainActor
        // isolation, so apply(_:) runs on the main actor with no explicit hop.
        Task {
            let snap = await store.ingest(paths: SessionPath.enumerateTranscripts(root: root), now: Date())
            firstClaudeScanDone = true
            apply(snap)
        }
        Task { await refreshUsage() }
        // Startup GC of stale broker + usage files left by a killed hook or an ended session, plus the
        // status dir (a killed window leaves a status file no reap/tombstone reclaimed). Both ALSO
        // re-run on the slow usage cadence (see `refreshUsage` — together with the pending-set
        // reconciliation) so a long-lived GUI doesn't accumulate either.
        Task.detached { PermissionBroker.sweep() }
        Task.detached { HookHandler.sweepStale() }
        // Refresh our own hook entries so their baked-in absolute path tracks THIS build (e.g. after the
        // app moves from a DerivedData build to /Applications). Refresh-only — never resurrects entries
        // the user removed, never writes when nothing changed.
        // On the MAIN actor (not detached) so this read-modify-write of settings.json is serialized with
        // the user-triggered install/uninstall ops (runHookOp is @MainActor) — they share the file, and
        // an interleaved write would otherwise lose one side's change (last-writer-wins on the whole
        // document). healInstalled is refresh-only + cheap and no-ops when nothing changed, so running it
        // on-actor at launch is fine.
        // NOT from a transient location (the mounted DMG, an App Translocation copy): that would re-point
        // every hook at a path that vanishes once the DMG is ejected (each hook then exits 127).
        let transientLocation = UpdateSupport.isTransientLocation()
        if transientLocation {
            Log.settings.warn("hook self-heal skipped: running from a transient location (\(Bundle.main.bundlePath))")
        } else {
            Task { @MainActor in
                do { try HooksInstaller.healInstalled() }
                catch { Log.settings.warn("hook self-heal skipped: \(error.localizedDescription)") }
            }
        }
        // Publish a presence beacon immediately (ready=false until the pending watcher is up) so the
        // blocking permission hook can tell we're alive even during these first startup moments.
        syncPresence()

        let watcher = TranscriptWatcher(path: root, onChange: { [weak self] paths in
            guard let self else { return }
            Task { await self.handle(paths) }
        }, onFullRescan: { [weak self] in
            // FSEvents coalesced/dropped events: the path list is incomplete, so re-read everything.
            guard let self else { return }
            Task { await self.fullRescan() }
        })
        watcher.start()
        self.watcher = watcher

        // Mode B: watch ~/.claude/status for precise state written by our hooks.
        hooksInstalled = HooksInstaller.isInstalled()
        permissionHookInstalled = HooksInstaller.isPermissionHookInstalled()
        trustedCommands = TrustedCommands.load()
        manualGroups = ProductGroups.loadManual()
        remoteHosts = RemoteHosts.load()
        accessibilityGranted = FocusResolver.accessibilityGranted
        let statusDir = HookHandler.statusDir
        try? FileManager.default.createDirectory(atPath: statusDir, withIntermediateDirectories: true)
        Task { await refreshStatus() }
        let statusWatcher = TranscriptWatcher(path: statusDir) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshStatus() }
        }
        statusWatcher.start()
        self.statusWatcher = statusWatcher

        // Interactive permission requests from the broker hook.
        let pendingDir = PermissionBroker.pendingDir
        try? FileManager.default.createDirectory(atPath: pendingDir, withIntermediateDirectories: true)
        Task { await refreshPending() }
        let pendingWatcher = TranscriptWatcher(path: pendingDir) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshPending() }
        }
        pendingWatcher.start()
        self.pendingWatcher = pendingWatcher
        // The pending watcher + the initial scan above guarantee we'll observe any request — so the hook
        // can now safely block on us. Flip the beacon to ready.
        presenceReady = true
        syncPresence()

        // Claude Code's own session registry (busy / idle / waiting, names, entrypoint) — the primary
        // state source when present (see `SessionRegistryReader`). FSEvents pre-arms on a nonexistent
        // dir, so an older Claude Code that never writes it costs nothing and needs no re-arm.
        Task { await refreshRegistry() }
        let registryWatcher = TranscriptWatcher(path: SessionRegistryReader.dir) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshRegistry() }
        }
        registryWatcher.start()
        self.registryWatcher = registryWatcher

        // Codex (ChatGPT.app / Codex CLI) — mode A over ~/.codex. Gated by the setting AND presence, so a
        // machine without Codex never even starts the watchers.
        refreshCodexPresence()
        startCodexIfEnabled()
        refreshCodexHookState()
        // Self-heal the Codex hook commands too (binary moved) — refresh-only, and only when installed,
        // because any byte changed in hooks.json makes Codex ask the user to trust it again. Never from a
        // transient location (see the Claude heal above).
        if (codexHooksInstalled || codexPermissionHookInstalled) && !transientLocation {
            Task { @MainActor in
                do { try CodexHooksInstaller.healInstalled() }
                catch { Log.codex.warn("codex hook self-heal skipped: \(error.localizedDescription)") }
                refreshCodexHookState()
            }
        }

        // Re-derive states as ACTIVE/STALE windows elapse even without new writes.
        stateTimer = Timer.scheduledTimer(withTimeInterval: Tuning.stateTick, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.tick() }
        }
        // ccusage is expensive — refresh on a slow cadence, never per FSEvents tick.
        usageTimer = Timer.scheduledTimer(withTimeInterval: Tuning.usageRefresh, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshUsage() }
        }

        // Remote hosts: no FSEvents/hook-file-watch equivalent across SSH, so both are polled on their own
        // timers, fully decoupled from the local `stateTimer`/`pendingWatcher` above — a slow or
        // unreachable host can only stall its OWN poll tick, never local rendering. Gated: with no enabled
        // host the two remote timers aren't even scheduled, so a user with zero remote hosts pays nothing
        // for the SSH feature — no 2s pollRemotePending → recomputePending → render() storm on battery
        // (V29/F5). CRUD toggles them via start/stopRemoteTimers.
        startRemoteTimers()
    }

    /// Schedule the two remote poll timers IFF at least one host is enabled; a no-op (and tears any
    /// existing timers down) otherwise. Idempotent — safe to call from `init` and every host CRUD path.
    private func startRemoteTimers() {
        guard RemoteHosts.load().contains(where: \.enabled) else { stopRemoteTimers(); return }
        if remotePollTimer == nil {
            let t = Timer.scheduledTimer(withTimeInterval: Tuning.remotePollInterval, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.pollRemoteSessions() }
            }
            t.tolerance = Tuning.remotePollInterval * 0.2   // let the OS coalesce ticks (state doesn't need exact timing)
            remotePollTimer = t
            pollRemoteSessions()
        }
        if remotePendingTimer == nil {
            let t = Timer.scheduledTimer(withTimeInterval: Tuning.remotePendingPoll, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.pollRemotePending() }
            }
            t.tolerance = Tuning.remotePendingPoll * 0.2
            remotePendingTimer = t
            pollRemotePending()
        }
    }

    /// Tear down the remote poll timers (no enabled hosts) so their cadence stops entirely.
    private func stopRemoteTimers() {
        remotePollTimer?.invalidate(); remotePollTimer = nil
        remotePendingTimer?.invalidate(); remotePendingTimer = nil
    }

    private func pollRemoteSessions() {
        remotePoller.pollAll { [weak self] in
            guard let self else { return }
            self.remoteHostStatuses = self.remotePoller.hostStatuses
            self.render()
        }
    }

    private func pollRemotePending() {
        remotePermissionRelay.pollAll { [weak self] reqs in
            guard let self else { return }
            self.remotePendingRequests = self.autoDecideRemote(reqs)
            self.recomputePending()
        }
    }

    /// Filter freshly-polled remote pending requests: anything the user has already blessed for this
    /// remote session ("Allow all in chat" ⇒ `remoteAllowAll`) or that matches a persistent trusted-command
    /// rule is relayed `allow` at once and dropped from the set that reaches a ribbon — the remote parity
    /// of the local in-hook allow-all / trusted-command short-circuit (`PermissionBroker.runHook`), which
    /// likewise never shows a ribbon for these. Runs ONLY over remote requests (each carries `remoteHostId`
    /// by construction — the relay only ever produces remote ones), so a LOCAL pending can never reach it.
    /// Idempotent across ticks: once we write a `.decision`, `RemotePermissionRelay.fetchPending`'s
    /// skip-decided filter (V21) drops the request on the next poll, so it's relayed at most once.
    private func autoDecideRemote(_ reqs: [PermissionBroker.PendingRequest]) -> [PermissionBroker.PendingRequest] {
        guard !reqs.isEmpty, !(remoteAllowAll.isEmpty && trustedCommands.isEmpty) else { return reqs }
        var visible: [PermissionBroker.PendingRequest] = []
        for req in reqs {
            let allowAll = remoteAllowAll.contains(req.sessionId)
            let trusted = allowAll ? false
                : TrustedCommands.isTrusted(tool: req.tool, input: Self.trustedInput(tool: req.tool, detail: req.detail))
            if allowAll || trusted {
                Log.permissions.info("remote auto-allow tool=\(req.tool) sid=…\(req.sessionId.suffix(12)) "
                    + "(\(allowAll ? "allow-all" : "trusted"))")
                remotePermissionRelay.decide(requestId: req.requestId, decision: .allowOnce)
            } else {
                visible.append(req)
            }
        }
        return visible
    }

    /// Best-effort reconstruction of the `tool_input` dict `TrustedCommands.isTrusted` needs, from the
    /// single `detail` string the remote shim sends (it collapses command/file_path/url/notebook_path into
    /// one field — `RemoteHookShim.summarize`). Keyed on the tool so `detail` lands under the SAME key the
    /// matcher reads for that tool (Bash→command, WebFetch→url, file tools→file_path); an unknown tool maps
    /// to nil so only a whole-tool-trust entry (empty pattern, which never consults input) can auto-allow
    /// it — no key we might mis-map into a false allow. Faithful: for these tools `detail` IS exactly the
    /// field the local matcher would inspect, so a remote auto-allow can never be broader than the local
    /// one on the same command.
    private static func trustedInput(tool: String, detail: String?) -> [String: Any]? {
        guard let detail, !detail.isEmpty else { return nil }
        switch tool {
        case "Bash": return ["command": detail]
        case "WebFetch": return ["url": detail]
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit": return ["file_path": detail]
        default: return nil
        }
    }

    /// Force a full re-scan + usage refresh (the "Обновить" button).
    func forceRefresh() {
        let root = SessionPath.projectsRoot
        refreshClaudePresence()
        refreshCodexPresence()
        Task {
            registry = await Task.detached { SessionRegistryReader.readAll() }.value
            registryLiveCount = registry.count
            if codexWatcher != nil { await rescanCodex(render: false) }
            apply(await store.ingest(paths: SessionPath.enumerateTranscripts(root: root), now: Date()))
            await refreshUsage()
        }
    }

    var workingCount: Int { sessions.filter { $0.state == .working }.count }
    var waitingCount: Int { sessions.filter { $0.state == .waiting }.count }
    var doneCount: Int { sessions.filter { $0.state == .done }.count }
    /// Working chats that are compacting their context right now — drives the tower's compacting chip.
    var compactingCount: Int { sessions.filter { $0.state == .working && $0.isCompacting }.count }

    private func handle(_ paths: [String]) async {
        refreshClaudePresence()   // the very first event may BE the projects dir appearing
        apply(await store.ingest(paths: paths, now: Date()))
    }

    /// Full re-read of every transcript — recovery path after FSEvents coalesces/drops events (the
    /// per-file callback list is then incomplete, so a targeted ingest would miss real changes).
    private func fullRescan() async {
        let root = SessionPath.projectsRoot
        apply(await store.ingest(paths: SessionPath.enumerateTranscripts(root: root), now: Date()))
    }

    private func tick() async {
        accessibilityGranted = FocusResolver.accessibilityGranted   // reflect a just-granted permission
        refreshClaudePresence()
        refreshCodexPresence()
        if codexWatcher == nil { startCodexIfEnabled() }   // Codex appeared / was enabled since launch
        if codexInstalled { refreshCodexHookState() }        // trust is granted inside the ChatGPT app
        // Registry re-read on the tick too (not only on FSEvents): a dozen tiny files + a kill(0) each —
        // cheap — and it's what notices a pid that died without Claude Code reaping its file.
        registry = await Task.detached { SessionRegistryReader.readAll() }.value
        registryLiveCount = registry.count
        if codexWatcher != nil { codexSessions = await codexStore.reevaluate(now: Date()) }
        apply(await store.reevaluate(now: Date()))
    }

    /// One stat() per call — cheap enough for the tick cadence.
    private func refreshClaudePresence() {
        let exists = FileManager.default.fileExists(atPath: SessionPath.projectsRoot)
        if exists != claudeInstalled { claudeInstalled = exists }
    }

    private func refreshCodexPresence() {
        let exists = CodexPaths.isInstalled
        if exists != codexInstalled { codexInstalled = exists }
    }

    /// Recomputed only when hooks.json or config.toml actually changed (mtime+size stamp), so the 5 s tick
    /// costs two stat() calls, not re-parsing both files plus a SHA-256. Publishes only on change.
    private var codexHookFilesStamp: String?
    private func refreshCodexHookState(force: Bool = false) {
        let stamp = [CodexHooksInstaller.hooksPath, CodexHooksInstaller.configPath].map { path -> String in
            guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return "-" }
            let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(m):\((a[.size] as? NSNumber)?.int64Value ?? 0)"
        }.joined(separator: "|")
        guard force || stamp != codexHookFilesStamp else { return }
        codexHookFilesStamp = stamp
        let installed = CodexHooksInstaller.isInstalled()
        let perm = CodexHooksInstaller.isPermissionHookInstalled()
        let trust = CodexHooksInstaller.trustState()
        if installed != codexHooksInstalled { codexHooksInstalled = installed }
        if perm != codexPermissionHookInstalled { codexPermissionHookInstalled = perm }
        if trust != codexHooksTrust {
            Log.codex.info("codex hooks trust: \(codexHooksTrust) → \(trust)")
            codexHooksTrust = trust
        }
    }

    // MARK: - Codex hooks (install/remove in ~/.codex/hooks.json)

    func installCodexHooks() {
        guard !refuseHookInstallFromTransientLocation("op.installCodexHooks") else { return }
        runHookOp("op.installCodexHooks") { try CodexHooksInstaller.install() }
    }
    func uninstallCodexHooks() { runHookOp("op.uninstallCodexHooks") { try CodexHooksInstaller.uninstall() } }
    func installCodexPermissionHook() {
        guard !refuseHookInstallFromTransientLocation("op.installCodexPermission") else { return }
        runHookOp("op.installCodexPermission") { try CodexHooksInstaller.installPermissionHook() }
    }
    func uninstallCodexPermissionHook() { runHookOp("op.uninstallCodexPermission") { try CodexHooksInstaller.uninstallPermissionHook() } }

    private func refreshRegistry() async {
        registry = await Task.detached { SessionRegistryReader.readAll() }.value
        registryLiveCount = registry.count
        render()
    }

    // MARK: - Codex (mode A over ~/.codex)

    /// Start the Codex watchers iff enabled + installed + not already running. Idempotent.
    private func startCodexIfEnabled() {
        guard WidgetSettings.shared.codexEnabled, codexInstalled, codexWatcher == nil else { return }
        Task { await rescanCodex(render: true) }
        let w = TranscriptWatcher(path: CodexPaths.sessionsRoot, onChange: { [weak self] paths in
            guard let self else { return }
            Task { await self.handleCodex(paths) }
        }, onFullRescan: { [weak self] in
            guard let self else { return }
            Task { await self.rescanCodex(render: true) }
        })
        w.start()
        codexWatcher = w
        // Lock files are created when a thread is (re)opened in a Codex process and never deleted; the
        // store re-checks lock STATE on every tick, this watcher just makes a freshly-opened old thread
        // appear without waiting for that tick.
        let lw = TranscriptWatcher(path: CodexPaths.writerLocksDir) { [weak self] paths in
            guard let self else { return }
            Task { await self.handleCodex(paths) }
        }
        lw.start()
        codexLockWatcher = lw
        Log.codex.info("codex watch started (home=\(CodexPaths.home))")
    }

    private func stopCodex() {
        codexWatcher?.stop(); codexWatcher = nil
        codexLockWatcher?.stop(); codexLockWatcher = nil
        codexSessions = []
        codexProjects = []   // Codex-sourced product groups go with it
        render()
        Log.codex.info("codex watch stopped")
    }

    /// The Settings toggle. Persists the choice and starts/stops the watchers at once.
    func setCodexEnabled(_ on: Bool) {
        WidgetSettings.shared.codexEnabled = on
        if on { refreshCodexPresence(); startCodexIfEnabled() } else { stopCodex() }
    }

    private func handleCodex(_ paths: [String]) async {
        codexSessions = await codexStore.ingest(paths: paths, now: Date())
        render()
    }

    private func rescanCodex(render doRender: Bool) async {
        codexSessions = await codexStore.rescan(now: Date())
        firstCodexScanDone = true
        codexProjects = await codexStore.knownProjects
        if doRender { render() }
    }

    private func refreshUsage() async {
        await usage.refresh()
        usageBySession = await usage.bySession
        days = await usage.days
        render()
        // Piggyback the periodic status-dir GC on this slow cadence (off-actor) so ~/.claude/status
        // can't grow unbounded over a long-lived GUI (one file per Claude Code session/UUID), and the
        // broker-file GC (leftover .decision files / long-idle allow-all markers) alongside it.
        Task.detached { HookHandler.sweepStale() }
        Task.detached { PermissionBroker.sweep() }
        // Reconcile the pending set on the same cadence. FSEvents on the pending dir is the fast path,
        // but it is not guaranteed delivery: a dropped delete event (or a pendingDir stream that failed
        // to start) used to leave a decided/orphaned request's ribbon force-redding its chat FOREVER —
        // nothing else ever re-listed the directory. This 45 s re-list (which also runs `listPending`'s
        // age-based orphan GC) is the backstop that bounds any such ghost at one cadence tick.
        await refreshPending()
    }

    private func refreshStatus() async {
        statusBySession = await Task.detached { StatusReader.readAll() }.value
        render()
    }

    private func refreshPending() async {
        localPendingRequests = await Task.detached { PermissionBroker.listPending() }.value
        recomputePending()
        updateIDELogWatch()
    }

    /// Merge local + remote pending requests into the published set. Called whenever EITHER side's poll
    /// loop refreshes (`refreshPending` for local, `pollRemotePending` for remote) so neither clobbers
    /// the other's latest contribution.
    private func recomputePending() {
        let all = localPendingRequests + remotePendingRequests
        // Nothing pending now AND nothing was pending last pass → no change, so skip the render(). Without
        // this the 2s remote pending poll re-renders the whole UI twice a second for a host that has no
        // outstanding request. If either is non-empty there's real work: publish it, or clear one that
        // just resolved. `activePendingSessions.isEmpty` is the faithful "was empty" signal — it's set in
        // lockstep with `pendingRequests` from the same `all` on every prior pass (V29).
        if all.isEmpty && activePendingSessions.isEmpty { return }
        activePendingSessions = Set(all.map(\.sessionId))
        // Newest first so the most recent request sits at the top of the ribbon/panel's list.
        pendingRequests = all.sorted { $0.createdAt > $1.createdAt }
        // Keep the displayed state consistent with the pending set: the render() backstop downgrades a
        // permission `waiting` that has no live request, so a real request appearing/clearing must
        // re-render (this path doesn't otherwise trigger one). The ribbon at the light surfaces the
        // request now — no notification is posted (toasts were removed from the product).
        render()
    }

    // MARK: - IDE-log watch (early permission resolution — WidgetSettings.watchIDELog, on by default)

    /// Start/stop the IDE-log poll based on the setting + whether any pending request is joinable (has a
    /// `toolUseId`). Idempotent — safe to call from `refreshPending` and when the setting toggles.
    func updateIDELogWatch() {
        let on = WidgetSettings.shared.watchIDELog
        // Publish the setting to the blocking hook via a file marker (it can't read our UserDefaults), so
        // the hook only pays the toolUseId reconstruction cost when the feature is on. Write only on change.
        let markerExists = PermissionBroker.isWatchIDELogEnabled()
        if on, !markerExists {
            // A failed write must not be silent: without the marker the broker never reconstructs a
            // toolUseId, the poll never arms, and the default-on headline feature (ribbon drops at IDE
            // approval) silently degrades to completion-time — with the canary never running either.
            // Retried every refreshPending, so a persistent failure keeps warning (that's the point).
            do {
                try FileManager.default.createDirectory(atPath: PermissionBroker.baseDir, withIntermediateDirectories: true)
                try "1".write(toFile: PermissionBroker.watchMarker, atomically: true, encoding: .utf8)
            } catch {
                Log.watcher.warn("IDE-log marker write failed: \(error.localizedDescription) "
                    + "— early permission resolution stays off")
            }
        } else if !on, markerExists {
            do { try FileManager.default.removeItem(atPath: PermissionBroker.watchMarker) }
            catch {
                Log.watcher.warn("IDE-log marker remove failed: \(error.localizedDescription) "
                    + "— broker will keep paying toolUseId reconstruction")
            }
        }
        let want = on && pendingRequests.contains { $0.toolUseId != nil }
        if want, ideLogTimer == nil {
            let t = Timer.scheduledTimer(withTimeInterval: Tuning.ideLogPoll, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { await self.pollIDELog() }
            }
            ideLogTimer = t
            Log.watcher.info("IDE-log watch armed (\(pendingRequests.filter { $0.toolUseId != nil }.count) request(s), poll \(Int(Tuning.ideLogPoll))s)")
        } else if !want, let t = ideLogTimer {
            t.invalidate(); ideLogTimer = nil
            ideLogPolls.removeAll(); ideLogWarned.removeAll()
            Log.watcher.info("IDE-log watch disarmed")
        }
    }

    private func pollIDELog() async {
        let ids = Set(pendingRequests.compactMap(\.toolUseId))
        guard !ids.isEmpty else { updateIDELogWatch(); return }
        for id in ids { ideLogPolls[id, default: 0] += 1 }
        let resolved = await Task.detached { IDELogWatcher.resolvedIds(ids) }.value

        let hitReqs = pendingRequests.filter { $0.toolUseId.map(resolved.contains) ?? false }
        if !hitReqs.isEmpty {
            for req in hitReqs { PermissionBroker.resolveExternally(requestId: req.requestId) }
            // Optimistically drop the ribbon now; the broker's cleanup + the pending-dir watcher reconcile
            // the authoritative state within a poll (~200 ms), and render()'s dangling-permission backstop
            // demotes the status to working meanwhile.
            let hitReqIds = Set(hitReqs.map(\.requestId))
            pendingRequests.removeAll { hitReqIds.contains($0.requestId) }
            // Also prune the cached local/remote sets, or the next recomputePending (the 2s remote tick, or
            // a pending-dir FSEvent) rebuilds `pendingRequests` from the stale cache and RESURRECTS the
            // just-resolved ribbon (V14). `decidePermission` already prunes these; `pollIDELog` was missed.
            localPendingRequests.removeAll { hitReqIds.contains($0.requestId) }
            remotePendingRequests.removeAll { hitReqIds.contains($0.requestId) }
            activePendingSessions = Set(pendingRequests.map(\.sessionId))
            Log.watcher.info("IDE-log resolved \(hitReqs.count) request(s) early (before completion) "
                + "[\(hitReqs.compactMap { $0.toolUseId.map { String($0.prefix(12)) } }.joined(separator: ","))]")
            render()
        }

        // Canary — surface a probable Cursor-format change in OUR logs so the parser can be updated. Fires
        // once per request that has been polled `ideLogCanaryPolls` rounds without an IDE-log resolution:
        //  • fresh log, marker absent  → WARN + sample lines (the current format to adapt to);
        //  • fresh log, marker present → DEBUG (our toolUseId just wasn't matched — an id-join gap);
        //  • no fresh log              → DEBUG (IDE idle — expected, not a format problem).
        let stale = ids.subtracting(resolved)
            .filter { (ideLogPolls[$0] ?? 0) >= Self.ideLogCanaryPolls && !ideLogWarned.contains($0) }
        if !stale.isEmpty {
            ideLogWarned.formUnion(stale)
            let staleList = stale.map { String($0.prefix(12)) }.sorted().joined(separator: ",")
            let diag = await Task.detached { () -> (fresh: Bool, marker: Bool, samples: [String]) in
                let logs = IDELogWatcher.candidateLogs()
                guard !logs.isEmpty else { return (false, false, []) }
                let marker = IDELogWatcher.sawDispatchMarker()
                return (true, marker, marker ? [] : IDELogWatcher.markerSamples())
            }.value
            if !diag.fresh {
                Log.watcher.debug("IDE-log canary: no fresh IDE log (IDE idle?) — nothing to detect [\(staleList)]")
            } else if diag.marker {
                Log.watcher.debug("IDE-log canary: dispatch marker present but toolUseId unmatched [\(staleList)]")
            } else {
                Log.watcher.warn("IDE-log: no `tool_dispatch_start` in a FRESH IDE log after "
                    + "\(Self.ideLogCanaryPolls)+ polls — Cursor format may have changed. Run "
                    + "`ccemaphore --ide-log-probe` to inspect. Recent lines:"
                    + (diag.samples.isEmpty ? " (none)" : diag.samples.map { "\n    \($0)" }.joined()))
            }
        }

        // Prune counters/guards for ids no longer pending (resolved by us OR by the completion fallback).
        let live = Set(pendingRequests.compactMap(\.toolUseId))
        ideLogPolls = ideLogPolls.filter { live.contains($0.key) }
        ideLogWarned = ideLogWarned.intersection(live)
        updateIDELogWatch()
    }

    private func apply(_ snap: [SessionInfo]) {
        rawSessions = snap
        render()
    }

    /// Local hook status merged with every reachable remote host's status (keyed by the namespaced id,
    /// tagged with `remoteHostId`). `render()`/`hostInfo` read THIS so remote sessions flow through the
    /// exact same status rules as local, while local keys stay untouched — remote keys are namespaced, so
    /// disjoint from local uuids, and a local id resolves to exactly the same entry as before.
    private var mergedStatus: [String: StatusEntry] {
        var m = statusBySession
        for hostStatuses in remotePoller.lastStatuses.values {
            for (id, st) in hostStatuses { m[id] = st }
        }
        return m
    }

    /// Merge mode A (file-watch) with mode B (hook status, precise), attach tokens, recompute color.
    /// On conflict the FRESHER signal wins: a recent Notification(waiting) overrides a stale mode-A
    /// "working", and a brand-new turn's writes override a stale hook "done".
    private func render() {
        let now = Date()
        var byId: [String: SessionInfo] = [:]
        for s in rawSessions { byId[s.id] = s }

        // Fold in the latest cached remote poll SESSIONS (mode-A state only). Safe unconditionally: remote
        // ids live in the `"remote:<hostId>:<uuid>"` namespace (see `SessionInfo.remoteID`), which can
        // never collide with a local uuid.
        for hostSessions in remotePoller.lastSessions.values {
            for (id, s) in hostSessions { byId[id] = s }
        }
        // Codex threads (mode A over ~/.codex) — `codex:<thread_id>` keys, disjoint by construction.
        for s in codexSessions { byId[s.id] = s }

        // Local hook status folded with every reachable remote host's status. Iterating THIS merged map
        // instead of `statusBySession` IS the remote-normalization: a remote session now goes through the
        // identical merge below (suppressDone / demote / native-wait / compacting), while local sessions
        // resolve to exactly the same entries as before (remote keys are namespaced, disjoint).
        let status = mergedStatus
        for (id, st) in status {
            guard now.timeIntervalSince(st.updatedAt) <= staleWindow else { continue }
            // The permission broker writes `waiting` only while a request is actually pending. If its
            // hook process was SIGKILLed before it could reset (which skips the timeout reset), the
            // file is left at waiting/permission with no live request — treat that as `working` so a
            // continued/finished chat doesn't sit stuck red. A genuine interactive wait still has its
            // pending request in `activePendingSessions`, so this never hides a real one.
            var hookState = st.state
            if hookState == .waiting, st.lastEvent == "permission", !activePendingSessions.contains(id) {
                hookState = .working
            }
            if var a = byId[id] {
                if a.cwd == nil { a.cwd = st.cwd }
                // A `done` vs `working` conflict between the two signals ALWAYS resolves to `working` — a
                // false "done" (🟢 while still working) is the worst failure for this app. Two mirror rules:
                //  - suppressDone: a hook `done` must NOT bury a mode-A `working`. The `Stop` hook fires
                //    when the MAIN agent finishes, but a sub-agent / workflow fan-out the transcript still
                //    sees as `working` keeps going — the false "завершено" on workflow chats.
                //  - preferHookWorking: a hook `working` (prompt/pre fired, no `Stop` yet) must NOT be
                //    buried by a mode-A `done`. In Cursor's agent mode the in-turn assistant response is
                //    NOT streamed into the .jsonl, so the transcript tail cools to "done" mid-turn (the
                //    user prompt is the trailing line for the whole turn) — the false "🟢 green while still
                //    working". The hook is the reliable signal; it flips to `done` the instant `Stop` fires.
                // Everything else follows fresher-wins.
                let suppressDone = (hookState == .done && a.state == .working)
                let preferHookWorking = (hookState == .working && a.state == .done)
                if preferHookWorking {
                    a.state = .working
                    a.lastActivity = max(a.lastActivity, st.updatedAt)
                } else if !suppressDone, st.updatedAt >= a.lastActivity {
                    a.state = hookState
                    a.lastActivity = st.updatedAt
                }
                byId[id] = a
            } else if SessionInfo.parseCodexID(id) == nil {
                // A status file with no matching session yet (transcript not tailed) still surfaces the
                // chat; carry `remoteHostId` so a remote-only chat is tagged correctly (offline / pid-reap
                // exclusion / deep-link) instead of looking local.
                // A CODEX status file never creates a row on its own: the Codex store owns a thread's
                // listing (a finished, closed thread drops at once by design), so a hook record only
                // overlays a row that exists — otherwise a `codex-<id>.json` left by `stop` would
                // resurrect the thread as a Claude-badged row for the whole stale window.
                byId[id] = SessionInfo(id: id, project: st.project, cwd: st.cwd, gitBranch: nil,
                                       title: nil, state: hookState, lastActivity: st.updatedAt,
                                       remoteHostId: st.remoteHostId)
            }
        }

        // Host (IDE vs. terminal) is immutable for a session's life and known only to mode B (mode A
        // can't see the process tree), so stamp it from ANY status record — even one past `staleWindow`.
        // A "перейти в чат" jump to a chat whose last hook event is a while old still needs the right app.
        for (id, st) in status where byId[id] != nil {
            byId[id]?.host = st.host
            byId[id]?.hostBundleId = st.hostBundleId
        }

        // Claude Code's OWN session registry (see `SessionRegistryReader`): the agent's word on busy /
        // idle / waiting, its launch folder, its user-given name and where it runs. For working/done it
        // outranks both the transcript tail and the hook status — those are inferences about the same
        // process, this is the process reporting — with two carve-outs: a chat kept `working` by a live
        // sub-agent / workflow stays working (the registry describes the MAIN agent, which can sit idle
        // while its children run), and the ground-truth force-red rules below still apply after it (they
        // only ever make a chat redder). A long-idle open tab with no recent activity stays out of the
        // list, as before: only busy/waiting entries, recently-changed ones, or ones already listed count.
        if WidgetSettings.shared.useSessionRegistry {
            for (sid, e) in registry {
                guard !e.isHidden, let regState = e.sessionState,
                      let stamp = e.statusUpdatedAt ?? e.updatedAt ?? e.startedAt else { continue }
                // Staleness gate, like every other source: an entry whose status hasn't changed for twice the
                // stale window (a frozen/suspended `claude`, a slept laptop) stops asserting anything — the
                // transcript/hook sources below age out on their own, so the row disappears instead of being
                // pinned yellow or red forever. (2× because one long tool run can legitimately sit `busy`
                // past `staleWindow`.)
                guard now.timeIntervalSince(stamp) <= staleWindow * 2 else { continue }
                let recent = now.timeIntervalSince(stamp) <= staleWindow
                guard regState != .done || recent || byId[sid] != nil else { continue }
                var a = byId[sid] ?? SessionInfo(id: sid, project: (e.cwd as NSString).lastPathComponent,
                                                  cwd: e.cwd.isEmpty ? nil : e.cwd, gitBranch: nil, title: nil,
                                                  state: regState, lastActivity: stamp)
                // The registry describes the MAIN agent, which sits idle while sub-agents / a workflow run:
                // the transcript fold (`workingViaChildren`, which carries the sub-agent grace and the
                // workflow live window) is the authority for "something is still running here".
                let childrenWorking = a.workingViaChildren || a.children.contains { $0.state == .working }
                a.state = (regState == .done && childrenWorking) ? .working : regState
                a.waitingKind = regState == .waiting ? e.waitingKind : nil
                a.lastActivity = max(a.lastActivity, stamp)
                if !e.cwd.isEmpty {
                    a.cwd = e.cwd
                    a.project = (e.cwd as NSString).lastPathComponent
                }
                if let name = e.userName { a.title = name }
                if e.host != .unknown {
                    a.host = e.host
                    if e.host == .desktop { a.hostBundleId = DeepLinker.claudeDesktopBundleId }
                }
                a.hostSessionId = e.hostSessionId
                a.isBackground = e.isBackground
                byId[sid] = a
            }
        }

        // A live permission request is GROUND TRUTH: the broker is blocking on it right now, so the chat
        // needs the user → force it red, whatever the status file says. This closes a two-process race:
        // the broker writes `waiting`, then the `pre` heartbeat of the SAME chat's next/parallel tool
        // writes `working` to the same status file a moment later and clobbers it (last-write-wins across
        // hook processes) — which used to paint a chat with a pending prompt yellow. Cleared the instant
        // the broker GCs the pending on decision/handoff; a handed-off `permission-native` wait then
        // keeps it red via the downgrade rule above. (Pairs with that rule: in-pending → red here;
        // not-in-pending + dangling `permission` → demoted to working there.)
        for id in activePendingSessions where byId[id] != nil {
            byId[id]?.state = .waiting
        }

        // A fresh broker "native wait" (question-native / permission-native) is ALSO ground truth — the
        // broker deliberately wrote it because the chat is blocked on the user in Cursor's own dialog.
        // Unlike a live request it has no pending file (so it's not in `activePendingSessions`), which
        // is exactly why it used to lose the fresher-wins merge above to mode A's still-warm `working`
        // tail. Force it red here, on the SAME ground-truth tier as a live pending. Cleared automatically
        // when the next hook event (the resumed tool's `pre`/`post`, the turn's `stop`) overwrites
        // `last_event` to a non-wait event, or when the status ages past `staleWindow`.
        for (id, st) in status where byId[id] != nil {
            guard st.state == .waiting, now.timeIntervalSince(st.updatedAt) <= staleWindow,
                  let ev = st.lastEvent, Self.nativeWaitEvents.contains(ev) else { continue }
            byId[id]?.state = .waiting
        }

        // Compacting decorates a `working` chat (mode B `PreCompact`). Applied AFTER the pending override
        // so a live permission request (→ red) always outranks the compacting chip on the same chat.
        for (id, st) in status where st.isCompacting {
            guard now.timeIntervalSince(st.updatedAt) <= staleWindow else { continue }
            if byId[id]?.state == .working { byId[id]?.isCompacting = true }
        }

        var list = Array(byId.values)
        for i in list.indices {
            // ccusage (≥ 20) prices Codex threads too, keyed `codex:<thread_id>` like the row. When it
            // has no figure yet, keep the one the Codex store put there (the catalog's running count)
            // instead of blanking the cell; Claude rows start with nil, so nothing changes for them.
            if let u = usageBySession[list[i].id] { list[i].tokens = u }
        }
        list.removeAll { $0.state == .stale }
        // Reap a chat whose owning process is gone (window closed / session killed / Ctrl-C'd) instead of
        // holding it on the light until `staleWindow` (30 min). Requires a fresh, pid-bearing mode-B
        // record with a confirmed-DEAD owner:
        //  - a settled `done` (incl. the `SessionEnd` tombstone) drops the instant its process exits —
        //    the clean terminal exit (`/exit`, Ctrl-D);
        //  - a `working`/`waiting` chat killed mid-turn (no `SessionEnd`, e.g. the terminal window closed
        //    or the turn was Ctrl-C'd) drops too, but ONLY if it has ALSO gone quiet past `activeWindow`.
        //    A live chat emits `pre`/`post` heartbeats that keep `updatedAt` fresh AND keeps its pid
        //    alive, so this can't hide one that's genuinely running even if the pid were mis-derived; the
        //    narrow window (dead pid + >60 s silent) is an actually-exited session. A long single tool
        //    (no `post` for minutes) stays safe because its pid is still alive → the guard never fires.
        list.removeAll { s in
            // pid-reap is LOCAL-only: never run `ProcTree.isAlive` on a remote host's pid (it belongs to
            // another machine). `remoteHostId == nil` gates it — remote sessions are offline-marked / aged
            // instead, never reaped by local process liveness.
            guard registry[s.id] == nil,   // listed in the registry ⇒ its process is alive (a resumed chat may carry an older status pid)
                  let st = status[s.id], st.remoteHostId == nil, let pid = st.ownerPid,
                  now.timeIntervalSince(st.updatedAt) <= staleWindow,
                  !ProcTree.isAlive(pid) else { return false }
            if s.state == .done { return true }
            return now.timeIntervalSince(st.updatedAt) > Tuning.activeWindow
        }
        // V3: mark a session whose remote host is currently UNREACHABLE as offline — its state is a frozen
        // last-known snapshot, so it must not pin the aggregate light (see `aggregate`) and the UI shows it
        // "offline" rather than freezing a stale colour or silently dropping it.
        let offlineHosts = Set(remotePoller.hostStatuses.filter { !$0.value.connected }.keys)
        if !offlineHosts.isEmpty {
            for i in list.indices where list[i].remoteHostId.map(offlineHosts.contains) ?? false {
                list[i].isOffline = true
            }
        }
        // Product groups: resolve against THIS render's live set (auto-suggestions need the live cwds), then
        // stamp each chat with its group root for the "by product" panel mode.
        let groups = ProductGroups.resolve(manual: manualGroups, codex: codexProjects, sessions: list)
        if groups != productGroups { productGroups = groups }
        for i in list.indices {
            let g = ProductGroups.group(for: list[i].cwd, in: groups)
            list[i].productRoot = g?.root
            list[i].productGroupIsAuto = g?.source == .auto
        }
        sessions = sortedForDisplay(list)
        // Keep the remembered "expanded" set bounded to chats that still exist — but only once every
        // active source has completed its first scan (see `firstClaudeScanDone`), and never for Codex ids
        // while Codex is off (re-enabling it restores their chevrons).
        if firstClaudeScanDone, codexWatcher == nil || firstCodexScanDone {
            var keep = Set(sessions.map(\.id))
            if codexWatcher == nil {
                keep.formUnion(WidgetSettings.shared.expandedSessionIDs.filter { SessionInfo.parseCodexID($0) != nil })
            }
            WidgetSettings.shared.pruneExpandedSessions(keeping: keep)
        }

        // Log per-session state transitions with their raw inputs BEFORE `manageCompletions` rolls
        // `lastDisplayState` forward — this is the signal that was missing when the question-native /
        // permission flap was diagnosed only from aggregate-color churn. Reads the previous snapshot.
        logStateTransitions(status: status)

        // Attention items: red chats parked on a native prompt (`permission-native`/`question-native`),
        // whose fresh status carries that event and which have NO live pending request (those get the
        // actionable decision ribbon instead). Persist until the next hook event flips them off waiting.
        attentionSessions = sessions.compactMap { s -> AttentionItem? in
            guard s.state == .waiting, !s.isOffline, !activePendingSessions.contains(s.id) else { return nil }
            // Both local and remote status now live in the merged `status` map (remote folded in via
            // `mergedStatus`), so this reads ONE path — the previous `else if s.isRemote` special-case
            // (which had to look at `SessionInfo.lastEvent`) is gone. A remote chat parked on a native
            // prompt gets its "→ open chat" ribbon through the exact same computation as local.
            let kind: AttentionItem.Kind
            if let st = status[s.id], now.timeIntervalSince(st.updatedAt) <= staleWindow,
               let ev = st.lastEvent, Self.nativeWaitEvents.contains(ev) {
                kind = ev == "question-native" ? .question : .permission
            } else if let w = s.waitingKind {
                // No hook record (hooks off, or a host where the broker took its no-wait path and never
                // wrote) but Claude Code's registry says the chat waits on the user — same ribbon.
                kind = w == .input ? .question : .permission
            } else {
                return nil
            }
            return AttentionItem(id: s.id, cwd: s.cwd, project: s.project,
                                 branch: s.gitBranch ?? "", kind: kind)
        }

        let newColor = aggregate(sessions)
        if newColor != color {
            Log.watcher.info("aggregate \(color.rawValue) → \(newColor.rawValue) "
                + "(sessions=\(sessions.count) working=\(workingCount) waiting=\(waitingCount) done=\(doneCount))")
        }
        color = newColor

        manageCompletions(now: now)
    }

    /// Log a session's rendered state change together with the RAW inputs that produced it (mode A tail
    /// state, mode B hook state+event, live-pending membership). Transitions are far rarer than the
    /// per-tool `pre`/`post` heartbeat, so this stays at info without flooding — and it's exactly what
    /// makes a merge race legible after the fact: a native wait losing to a warm mode-A `working`, a
    /// false done, a flap all read straight from the log instead of needing a live re-catch. Diffs
    /// against `lastDisplayState` (the previous render's snapshot, rolled forward by `manageCompletions`,
    /// which runs right after this).
    private func logStateTransitions(status: [String: StatusEntry]) {
        guard completionSeeded else { return }   // first render seeds the snapshot; nothing to diff yet
        let rawById = Dictionary(rawSessions.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        for s in sessions {
            guard let prev = lastDisplayState[s.id], prev != s.state else { continue }
            let modeA = rawById[s.id]?.rawValue ?? "—"
            let hook = status[s.id].map { "\($0.state.rawValue)/\($0.lastEvent ?? "?")" } ?? "—"
            let pending = activePendingSessions.contains(s.id) ? "yes" : "no"
            let reg = registry[s.id].map { "\($0.status?.rawValue ?? "?")\($0.waitingFor.map { "/\($0)" } ?? "")" } ?? "—"
            Log.watcher.info("state sid=\(sidTag(s.id)) \(prev.rawValue)→\(s.state.rawValue) "
                + "(modeA=\(modeA) hook=\(hook) registry=\(reg) pending=\(pending) agent=\(s.agent.rawValue))")
        }
    }

    // MARK: - Completion notices (the "chat finished" ribbon at the light)

    /// Mint a transient "done" notice on the working/waiting → done EDGE (once per episode), and clear
    /// notices that expired or whose chat resumed. This is the redesign's in-widget replacement for the
    /// old done toast — the ribbon + chime are driven off `completionNotices` (see FloatingWidgetController).
    private func manageCompletions(now: Date) {
        // Expire finished notices (they auto-clear after the window; the 5 s tick bounds the lag).
        completionNotices.removeAll { now.timeIntervalSince($0.createdAt) > Tuning.doneNoticeWindow }

        let byId = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Fire only on a genuine →done transition. Skip the first render (don't announce chats already
        // finished at launch) and debounce a flapping chat (done→working→done) within the window.
        if completionSeeded {
            for s in sessions where s.state == .done {
                guard let prev = lastDisplayState[s.id], prev == .working || prev == .waiting else { continue }
                if let last = lastCompletionFiredAt[s.id], now.timeIntervalSince(last) < Tuning.doneNoticeWindow { continue }
                lastCompletionFiredAt[s.id] = now
                if !completionNotices.contains(where: { $0.id == s.id }) {
                    completionNotices.insert(
                        CompletionNotice(id: s.id, cwd: s.cwd, project: s.project,
                                         branch: s.gitBranch ?? "", createdAt: now),
                        at: 0)
                    Log.watcher.info("chat finished sid=\(sidTag(s.id)) project=\(s.project) → done notice")
                    // Precise auto-dismiss at exactly `doneNoticeWindow`, so the card vanishes in step with
                    // the ribbon's countdown bar (the render-based expiry above is only a coarse backstop
                    // bounded by the tick). `ifCreatedAt` makes it a no-op if a resume/tap cleared this
                    // notice first, or a NEW episode replaced it — it only ever removes THIS one.
                    let sid = s.id, created = now
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(Tuning.doneNoticeWindow * 1_000_000_000))
                        self?.dismissCompletion(sid, ifCreatedAt: created)
                    }
                }
            }
        }
        // Drop a notice whose chat resumed (a new turn started) — it's no longer "done".
        completionNotices.removeAll { n in
            if let cur = byId[n.id] { return cur.state != .done }
            return false   // chat left the list (reaped/stale) → let it expire on its own timer
        }

        // Roll state forward for the next render's edge detection; bound the debounce map.
        lastDisplayState = Dictionary(sessions.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        lastCompletionFiredAt = lastCompletionFiredAt.filter { now.timeIntervalSince($0.value) < Tuning.doneNoticeWindow * 3 }
        completionSeeded = true
    }

    /// Dismiss a "done" notice — the user jumped to that chat from its ribbon, or its countdown elapsed.
    /// `ifCreatedAt` (used by the scheduled auto-dismiss) removes the notice ONLY if it's still the same
    /// episode's, so a newer notice for the same chat isn't cleared out from under the user.
    func dismissCompletion(_ sessionId: String, ifCreatedAt: Date? = nil) {
        completionNotices.removeAll { $0.id == sessionId && (ifCreatedAt == nil || $0.createdAt == ifCreatedAt) }
    }

    /// Host + bundle id for a session, from its mode-B status (the sole authority on host). `.unknown`/nil
    /// when there's no status record — `DeepLinker` then falls back to the Cursor path. Used by the ribbon
    /// "перейти в чат" actions, whose `RibbonItem`s carry only a session id.
    func hostInfo(for sessionId: String) -> (host: SessionHost, bundleId: String?, hostSessionId: String?) {
        // The registry knows the host for desktop/IDE chats even with hooks off, plus the desktop app's
        // own session handle for its deep link.
        if let e = registry[sessionId], e.host != .unknown {
            let bundle = e.host == .desktop ? DeepLinker.claudeDesktopBundleId : mergedStatus[sessionId]?.hostBundleId
            return (e.host, bundle, e.hostSessionId)
        }
        if SessionInfo.parseCodexID(sessionId) != nil {
            let s = codexSessions.first { $0.id == sessionId }
            return (s?.host ?? .codexApp, s?.hostBundleId ?? DeepLinker.codexAppBundleId, nil)
        }
        // Merged so a remote session (namespaced id) resolves too — DeepLinker forks on `remoteHostId`
        // before reaching here for remotes, but keeping this on the same map avoids a local-only gap.
        guard let st = mergedStatus[sessionId] else { return (.unknown, nil, registry[sessionId]?.hostSessionId) }
        return (st.host, st.hostBundleId, registry[sessionId]?.hostSessionId)
    }

    // MARK: - Hooks (mode B install/remove)

    func installHooks() {
        guard !refuseHookInstallFromTransientLocation("op.installHooks") else { return }
        runHookOp("op.installHooks") { try HooksInstaller.install() }
    }
    func uninstallHooks() { runHookOp("op.uninstallHooks") { try HooksInstaller.uninstall() } }
    func installPermissionHook() {
        guard !refuseHookInstallFromTransientLocation("op.installPermission") else { return }
        runHookOp("op.installPermission") { try HooksInstaller.installPermissionHook() }
    }

    /// Installing from the mounted DMG / an App Translocation copy would bake a path into settings.json
    /// (or hooks.json) that disappears with the DMG — every hook would then fail. Refuse with a visible
    /// reason; uninstall stays allowed. True when refused.
    private func refuseHookInstallFromTransientLocation(_ opKey: String) -> Bool {
        guard UpdateSupport.isTransientLocation() else { return false }
        lastHookError = .blockedTransient
        Log.settings.warn("hook op \(opKey) refused: running from a transient location (\(Bundle.main.bundlePath))")
        return true
    }
    func uninstallPermissionHook() { runHookOp("op.uninstallPermission") { try HooksInstaller.uninstallPermissionHook() } }

    /// Prompt for Accessibility (opens the System Settings deep-link). Retained for the `--ax-dump`
    /// diagnostic / a future per-tab feature — no longer tied to notification suppression.
    func requestAccessibility() {
        _ = FocusResolver.requestAccessibility()
        accessibilityGranted = FocusResolver.accessibilityGranted
    }

    // MARK: - Presence beacon (lets the blocking permission hook know the GUI is alive & able to answer)

    private var presenceReady = false
    private var widgetVisible = false
    private var lastPresence: AppPresence.WrittenState?

    /// Republish the presence beacon if our (ready, widget-visible) pair changed. Idempotent and cheap,
    /// so it's safe to call from the 5 s tick — it only writes the file when something changed.
    private func syncPresence() {
        let next = AppPresence.WrittenState(ready: presenceReady, widgetVisible: widgetVisible)
        guard lastPresence != next else { return }
        lastPresence = next
        AppPresence.write(next)
    }

    /// The floating light was shown or hidden. Republished into the beacon so the blocking permission
    /// hook gives a real wait window while the light (and thus the answerable ribbon) is on screen, and
    /// barely stalls the agent when it's hidden. Also force-refresh the pending list on show so the
    /// ribbon reflects the live set immediately (FSEvents can lag a beat).
    func setWidgetVisible(_ visible: Bool) {
        guard widgetVisible != visible else { return }
        widgetVisible = visible
        syncPresence()
        if visible { Task { await refreshPending() } }
    }

    /// Record the user's choice for an interactive permission request (popover buttons). Writes the
    /// decision the blocking hook is polling for, then optimistically drops it from the list so the row
    /// disappears at once (the pending-dir watcher reconciles the authoritative state right after).
    func decidePermission(_ req: PermissionBroker.PendingRequest, _ decision: PermissionBroker.Decision) {
        if req.remoteHostId != nil {
            // "Allow all in chat" on a remote request: remember it HERE (the shim keeps no such memory) so
            // `autoDecideRemote` relays an instant allow for every later request from this session. The
            // remote parity of the local broker's `setAllowAll`.
            if decision == .allowAll { remoteAllowAll.insert(req.sessionId) }
            remotePermissionRelay.decide(requestId: req.requestId, decision: decision) { [weak self] message in
                guard let self else { return }
                // The relay retried and still couldn't reach the host — the click never got to the remote
                // hook (still blocking). Don't let it vanish silently: re-surface the request so the ribbon
                // comes back with live buttons to retry (the next poll reconciles if it did in fact land).
                Log.settings.warn("remote decision relay failed for req=\(req.requestId.prefix(8)): \(message)")
                if !self.remotePendingRequests.contains(where: { $0.requestId == req.requestId }) {
                    self.remotePendingRequests.append(req)
                    self.recomputePending()
                }
            }
            remotePendingRequests.removeAll { $0.requestId == req.requestId }
        } else {
            PermissionBroker.decide(requestId: req.requestId, decision)
            localPendingRequests.removeAll { $0.requestId == req.requestId }
        }
        pendingRequests.removeAll { $0.requestId == req.requestId }
        if !pendingRequests.contains(where: { $0.sessionId == req.sessionId }) {
            activePendingSessions.remove(req.sessionId)
        }
        render()
    }

    // MARK: - Trusted commands (auto-allow via the permission hook)

    /// Add a trusted tool/command pattern (empty tool ⇒ any; empty pattern ⇒ any use of that tool). The
    /// hook reads the backing file on its next call, so this takes effect immediately.
    func addTrustedCommand(tool: String, pattern: String) {
        trustedCommands = TrustedCommands.add(tool: tool, pattern: pattern)
        Log.settings.info("trusted add tool=\(tool.isEmpty ? "*" : tool) pattern=\(pattern)")
    }

    func removeTrustedCommand(_ entry: TrustedCommands.Entry) {
        trustedCommands = TrustedCommands.remove(entry)
        Log.settings.info("trusted remove tool=\(entry.tool.isEmpty ? "*" : entry.tool) pattern=\(entry.pattern)")
    }

    // MARK: - Product groups (manual roots; Codex projects + auto-suggestions are derived in render())

    func addProductGroup(root: String) {
        manualGroups = ProductGroups.add(root: root)
        Log.settings.info("product group add root=\(root)")
        render()
    }

    func removeProductGroup(root: String) {
        manualGroups = ProductGroups.remove(root: root)
        Log.settings.info("product group remove root=\(root)")
        render()
    }

    // MARK: - Remote hosts (SSH-monitored VS Code + Claude Code sessions on other machines)

    func addRemoteHost(_ host: RemoteHost) {
        remoteHosts = RemoteHosts.add(host)
        startRemoteTimers()   // a newly-added enabled host may be the first — ensure the remote timers run
        pollRemoteSessions()
    }

    func updateRemoteHost(_ host: RemoteHost) {
        remoteHosts = RemoteHosts.update(host)
        startRemoteTimers()   // the enabled-set may have flipped (e.g. the last host disabled) — retoggle
        pollRemoteSessions()
        render()   // reflect an enable/disable at once, even when no host remains to poll-and-render
    }

    func removeRemoteHost(_ id: String) {
        remoteHosts = RemoteHosts.remove(id: id)
        remoteHostStatuses.removeValue(forKey: id)
        remoteTestResults.removeValue(forKey: id)
        remoteHooksInstallResults.removeValue(forKey: id)
        // Drop that host's allow-all memory too — its sessions are gone, so the entries would only leak.
        remoteAllowAll = remoteAllowAll.filter { SessionInfo.parseRemoteID($0)?.hostId != id }
        // Drop the host's sessions from the merge buffer so render()'s re-fold can't resurrect them; the
        // next render() then omits them (precise prune instead of mutating the published `sessions`
        // directly, which the fold would immediately overwrite anyway — V19).
        remotePoller.prune(hostId: id)
        startRemoteTimers()   // may have removed the last enabled host — stop the timers if so
        render()
    }

    func setRemoteHostEnabled(_ id: String, enabled: Bool) {
        guard var host = remoteHosts.first(where: { $0.id == id }) else { return }
        host.enabled = enabled
        updateRemoteHost(host)
    }

    /// "Test Connection" UI action — runs a non-batch ssh (see `RemoteExec.testConnection`) so a
    /// brand-new host's known_hosts prompt can complete once, and stores the detected platform on
    /// success so `RemoteHooksInstaller` can refuse a non-macOS-incompatible install path later.
    func testRemoteConnection(_ host: RemoteHost) {
        Task { [weak self] in
            // Offload the blocking ssh round-trip to a background task, then hop back to the
            // main actor (inherited by this Task) to touch @Published state.
            let result = await Task.detached(priority: .userInitiated) {
                RemoteExec.testConnection(host)
            }.value
            guard let self else { return }
            self.remoteTestResults[host.id] = result
            if case .success(let platform) = result {
                // Re-read the LIVE host: the user may have toggled `enabled` / edited it during the
                // multi-second ssh. Merge ONLY the detected platform onto the current copy, so that
                // concurrent edit isn't clobbered by writing back the pre-ssh snapshot (S2).
                guard var current = self.remoteHosts.first(where: { $0.id == host.id }) else { return }
                current.platform = platform
                self.remoteHosts = RemoteHosts.update(current)
            }
        }
    }

    /// "Install hooks" UI action. Mirrors `testRemoteConnection`: offload the blocking ssh work to a
    /// detached task, then hop back to the main actor to publish a per-host outcome the row renders
    /// (green "installed" / red failure) — the old version log-and-dropped, so the button looked inert on
    /// both success and failure (V27).
    func installRemoteHooks(_ host: RemoteHost) {
        Task { [weak self] in
            let result: RemoteHookInstallResult = await Task.detached(priority: .userInitiated) {
                do { try RemoteHooksInstaller.install(host); return .installed }
                catch { return .failed(error.localizedDescription) }
            }.value
            guard let self else { return }
            self.remoteHooksInstallResults[host.id] = result
            switch result {
            case .installed: Log.settings.info("remote hooks installed (\(host.label))")
            case .failed(let msg): Log.settings.error("remote hook install failed (\(host.label)): \(msg)")
            }
        }
    }

    func uninstallRemoteHooks(_ host: RemoteHost) {
        Task.detached(priority: .userInitiated) {
            do { try RemoteHooksInstaller.uninstall(host) }
            catch { Log.settings.error("remote hook uninstall failed (\(host.label)): \(error.localizedDescription)") }
        }
    }

    /// Run a settings.json mutation and surface any failure (e.g. a malformed or unwritable file)
    /// instead of letting the menu button look like it silently did nothing.
    private func runHookOp(_ opKey: String, _ op: () throws -> Void) {
        do {
            try op()
            lastHookError = nil
            Log.settings.info("hook op \(opKey) ok")
        } catch {
            lastHookError = .failed(opKey: opKey, error: error)
            Log.settings.error("hook op \(opKey) failed: \(error.localizedDescription)")
        }
        hooksInstalled = HooksInstaller.isInstalled()
        permissionHookInstalled = HooksInstaller.isPermissionHookInstalled()
        refreshCodexHookState(force: true)
    }

    // MARK: - Menu-bar presentation

    var menuBarText: String {
        switch color {
        case .gray: return "⚪"
        case .green: return "🟢"
        case .yellow:
            let n = sessions.filter { $0.state == .working }.count
            return n > 1 ? "🟡 \(n)" : "🟡"
        case .red:
            let n = sessions.filter { $0.state == .waiting }.count
            return n > 1 ? "🔴 \(n)" : "🔴"
        }
    }

    var summaryLine: String {
        if sessions.isEmpty { return L("popover.noActiveSessions") }
        let w = sessions.filter { $0.state == .working }.count
        let r = sessions.filter { $0.state == .waiting }.count
        let d = sessions.filter { $0.state == .done }.count
        var parts: [String] = []
        if w > 0 { parts.append("🟡 " + Lf("count.working", w)) }
        if r > 0 { parts.append("🔴 " + Lf("count.waiting", r)) }
        if d > 0 { parts.append("🟢 " + Lf("count.done", d)) }
        return parts.joined(separator: " · ")
    }
}

/// Early detection of "answered in the IDE's own dialog" for a pending permission.
///
/// The Cursor / VS Code Claude Code extension (`Anthropic.claude-code`) logs a line the instant the user
/// answers a permission dialog — BEFORE the tool completes:
///   `[Stall] tool_dispatch_start tool=Bash toolUseId=<id> permissionDecisionMs=<N>`
/// Claude Code's OWN surfaces (transcript / hooks / status files) carry no such signal until the tool
/// finishes (see memory/permission-resume-signal.md), so tailing this log is the only way to drop the
/// ribbon at approval rather than at completion. The SAME extension writes the SAME log in every VS Code
/// fork, so this covers Cursor AND VS Code (+ Insiders / VSCodium).
///
/// ON by default (`WidgetSettings.watchIDELog`) — without it, an approved long-running tool keeps its
/// red Allow/Deny ribbon for the tool's whole runtime (the "approved in Cursor but the widget dialog
/// stayed" incident). Privacy holds: we read ONLY each log's tail and extract ONLY the `toolUseId` from
/// the dispatch marker line — no command text is parsed or stored. It stays a setting because the log is
/// UNDOCUMENTED and version-fragile (a Cursor update can change the format — some 2026-05 markers
/// already vanished): turning it off is the escape hatch, and the canary in `pollIDELog` flags a format
/// change in our own log. All work runs off the main actor (`Task.detached`).
enum IDELogWatcher {
    /// App-support roots for the VS Code forks that host the `Anthropic.claude-code` extension.
    private static var logRoots: [String] {
        let appSup = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support")
        return ["Cursor", "Code", "Code - Insiders", "VSCodium"]
            .map { (appSup as NSString).appendingPathComponent("\($0)/logs") }
    }

    /// The active extension logs worth scanning right now — `…/logs/<session>/window<N>/exthost/
    /// Anthropic.claude-code/Claude VSCode.log`, modified within `freshWithin`, freshest first, capped.
    /// Ranked by the LOG's OWN mtime, NOT the session-dir NAME: a long-running IDE keeps writing to an
    /// older-named session dir (its name is the launch time), so pre-filtering by name misses it. Session
    /// dirs are bounded in practice (IDE prunes them), so statting each window log per poll is cheap.
    static func candidateLogs(freshWithin: TimeInterval = 180, limit: Int = 6) -> [String] {
        let fm = FileManager.default
        let now = Date()
        var hits: [(path: String, mtime: Date)] = []
        for root in logRoots {
            guard let sessions = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for session in sessions {
                let sdir = (root as NSString).appendingPathComponent(session)
                for w in ((try? fm.contentsOfDirectory(atPath: sdir)) ?? []) where w.hasPrefix("window") {
                    let path = (sdir as NSString)
                        .appendingPathComponent("\(w)/exthost/Anthropic.claude-code/Claude VSCode.log")
                    guard let a = try? fm.attributesOfItem(atPath: path),
                          let m = a[.modificationDate] as? Date, now.timeIntervalSince(m) <= freshWithin
                    else { continue }
                    hits.append((path, m))
                }
            }
        }
        return hits.sorted { $0.mtime > $1.mtime }.prefix(limit).map(\.path)
    }

    /// Of `ids`, the subset whose tool has been dispatched (⇒ the permission was answered in the IDE).
    /// A `tool_dispatch_start … toolUseId=<id>` line for our exact id is the signal; it fires at approval,
    /// decoupled from tool duration. Reads only each log's tail; extracts only the id token.
    static func resolvedIds(_ ids: Set<String>, tailBytes: Int = 256 * 1024,
                            freshWithin: TimeInterval = 180) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var found = Set<String>()
        for path in candidateLogs(freshWithin: freshWithin) {
            guard let tail = tail(path, bytes: tailBytes) else { continue }
            for line in tail.split(separator: "\n", omittingEmptySubsequences: true)
            where line.contains("tool_dispatch_start") {
                // Exact-token match (`toolUseId=<id>` is space-delimited) so a pending id that's a strict
                // prefix of another id in the tail can't false-match.
                let tokens = Set(line.split(separator: " ").map(String.init))
                for id in ids where !found.contains(id) && tokens.contains("toolUseId=\(id)") { found.insert(id) }
            }
            if found == ids { break }
        }
        return found
    }

    /// Is the dispatch marker we key on (`tool_dispatch_start`) present at all in a fresh log? Used to
    /// tell "the IDE format changed" (marker gone) from "our toolUseId just isn't there yet / user hasn't
    /// answered" (marker present, id absent). See the canary in `StateEngine.pollIDELog`.
    static func sawDispatchMarker(freshWithin: TimeInterval = 180) -> Bool {
        for p in candidateLogs(freshWithin: freshWithin) {
            if let t = tail(p, bytes: 256 * 1024), t.contains("tool_dispatch_start") { return true }
        }
        return false
    }

    /// Recent dispatch/permission-shaped lines from the freshest log — so that if Cursor changes the log
    /// format and detection breaks, our OWN log (and `--ide-log-probe`) capture the CURRENT format to
    /// update the parser against. Lines are truncated (`maxLen`) and limited; only structural marker
    /// keywords are matched (these lines carry the tool name / id / timing, not the full command).
    static func markerSamples(freshWithin: TimeInterval = 3600, limit: Int = 10, maxLen: Int = 160) -> [String] {
        guard let path = candidateLogs(freshWithin: freshWithin).first,
              let t = tail(path, bytes: 128 * 1024) else { return [] }
        // Structural Claude-emitted markers only (tool name / id / timing / hook flow). Exclude
        // `Received message from webview` lines — those carry chat titles / content, which we never log.
        let keywords = ["tool_dispatch", "permissionDecisionMs", "[Stall]", "Spawning shell",
                        "executePermissionRequestHooks", "Hook PermissionRequest", "hasPendingPermissions"]
        var out: [String] = []
        for line in t.split(separator: "\n", omittingEmptySubsequences: true).reversed()
        where keywords.contains(where: line.contains) && !line.contains("webview") {
            let s = String(line)
            out.append(s.count > maxLen ? String(s.prefix(maxLen)) + "…" : s)
            if out.count >= limit { break }
        }
        return out.reversed()
    }

    private static func tail(_ path: String, bytes: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd() else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        if (try? h.seek(toOffset: start)) == nil { return nil }
        guard let data = try? h.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `ccemaphore --ide-log-probe [toolUseId]` — headless check: list candidate logs and, if an id is
    /// given, whether its dispatch marker is present. Lets the mechanism be verified without the GUI.
    static func probe(_ toolUseId: String?) {
        // Generous window for the diagnostic so it's useful even when the IDE is momentarily idle; the
        // live watcher uses the tighter Tuning-default freshWithin.
        let logs = candidateLogs(freshWithin: 3600)
        print("candidate IDE logs (fresh ≤1h, newest first): \(logs.count)")
        for p in logs { print("  \(p)") }
        print("dispatch marker (tool_dispatch_start) present in a fresh log: \(sawDispatchMarker(freshWithin: 3600))")
        // Current format: if Cursor changed it and detection breaks, these lines show what to parse now.
        let samples = markerSamples()
        print("--- recent dispatch/permission lines (current format, truncated) ---")
        if samples.isEmpty { print("  (none found — format may have changed, or the IDE is idle)") }
        for s in samples { print("  \(s)") }
        guard let id = toolUseId else {
            print("(pass a toolUseId to test dispatch detection)")
            return
        }
        let hit = resolvedIds([id], freshWithin: 3600)
        print("toolUseId \(id): \(hit.isEmpty ? "NOT dispatched (no marker found)" : "DISPATCHED (marker found → would resolve)")")
    }
}
