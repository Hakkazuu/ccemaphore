import AppKit
import Combine
import Sparkle

/// Owner of the in-app updater (Sparkle 2.10.0) — GUI process only; CLI / hook modes never create it.
///
/// CONTRACT: the public surface below is shared with the UI layer (`UpdateViews`, `FloatingPanelView`,
/// `StatusItemController`). Change it only together with them. The implementation behind it (Sparkle
/// wiring, gates, persistence, watchdog) lives here, in `UpdateUserDriver` and in `UpdateSupport`.
///
/// How an update reaches the user (no Sparkle window on any of these paths):
/// - **automatic** — Sparkle checks daily and downloads in the background; once the installer is
///   staged it asks `willInstallUpdateOnQuit`, we keep its block and show `.readyToInstall`. One click
///   (`install()`) calls the block: quit → atomic swap → relaunch. Quitting any other way installs too.
///   If installing needs an administrator password, Sparkle can't stage it silently: it keeps the download
///   and offers it through the user driver at stage `.downloaded` → `.available` (`isDownloaded`).
/// - **notifyOnly** — the daily check's find arrives through `UpdateUserDriver.showUpdateFound`; we
///   hold Sparkle's reply as `.available`. Update → download/extract progress in the row → at "ready"
///   we answer install on the user's behalf → quit, swap, relaunch.
/// - **off** — no scheduled checks; `checkNow()` runs the same user-initiated flow.
/// Every quit-to-install first writes an install marker (read once at the next launch: "updated" or
/// "didn't install") and arms the relaunch watchdog (`UpdateSupport`), the safety net for an install
/// that fails after we're gone. Restart is refused while a permission request is pending: quitting would
/// cut the blocking permission hook off.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    /// What the panel row, the Settings section and the status menu render.
    @Published private(set) var phase: UpdatePhase = .idle
    /// Whether the updater runs in this process, and why not.
    @Published private(set) var availability: UpdateAvailability = .debugBuild
    /// The user's preference; `nil` until the consent row is answered.
    @Published private(set) var mode: UpdateMode?
    /// When Sparkle last completed an update check (scheduled or manual); `nil` if never.
    @Published private(set) var lastCheckDate: Date?
    /// Bumped whenever an update surface should be brought to the user's attention (a user-initiated
    /// check started/finished, Sparkle asked to show the update in focus). The UI layer observes it and
    /// opens (pins) the management panel so the row is visible even if the check came from the menu.
    @Published private(set) var focusRequest = 0

    private override init() { super.init() }

    /// The running app's `CFBundleShortVersionString`, e.g. "1.3.0".
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// The running app's `CFBundleVersion`, e.g. "4".
    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// True while a permission request is pending: quitting would cut the blocking permission hook off,
    /// so Restart/Install is disabled and the UI says why.
    var restartBlockedByPermission: Bool { !StateEngine.shared.pendingRequests.isEmpty }

    /// Whether "Check now" can run right now (updater enabled, no update session in progress). While an
    /// update is staged silently Sparkle's session stays busy, but "Check now" still answers — it brings
    /// the Restart row forward. Off while `.restartNeeded` is up: that row outranks every check result, so a
    /// check would run unseen — and against this old build, while the newer one is already on disk.
    var canCheckNow: Bool {
        guard availability == .enabled, updater != nil, restartNeededVersion == nil else { return false }
        return sparkleCanCheck || immediateInstall != nil
    }

    /// CONTRACT (review fix UX-7): in `.readyToInstall`, true when quitting ccemaphore installs the update too —
    /// Sparkle's installer is staged and armed for the app's termination: an update staged silently in the
    /// background, a held "ready to install" reply, or a resumed offer at stage `.installing`. (A download
    /// Sparkle only kept, stage `.downloaded`, never reaches `.readyToInstall`: it is `.available` with
    /// `UpdateInfo.isDownloaded`, and only Update installs it.) False in every other phase.
    var readyInstallsOnQuit: Bool {
        guard case .readyToInstall = phase else { return false }
        #if DEBUG
        if availability == .debugBuild { return simulatedFlags.contains(.installsOnQuit) }
        #endif
        return stagedForQuit != nil
    }

    /// CONTRACT (review fix UX-7): true while the user already chose to install and the install only waits for
    /// a pending permission request to be answered — it then continues by itself (`permissionGateChanged`):
    /// the "ready" step held after Update was pressed (`.readyToInstall`), or Sparkle's relaunch postponed for
    /// a request that arrived right after the click (`.installing`).
    var installWaitsForPermission: Bool {
        #if DEBUG
        if availability == .debugBuild { return simulatedFlags.contains(.waitsForPermission) }
        #endif
        if postponedRelaunch != nil { return true }
        guard userChoseInstall, case .ready? = heldChoice else { return false }
        return restartBlockedByPermission
    }

    /// Additive (review fix CONC-2; optional for the UI): true when installing replaces a bundle this user can't
    /// write or doesn't own, so macOS asks for an administrator password as the install starts. Sparkle runs
    /// its installer launcher in-process and asks on the MAIN thread, so the light and the ribbons stay
    /// frozen until that dialog is answered — the UI may say so next to Update. A fresh file-system check.
    var installNeedsAdministrator: Bool {
        #if DEBUG
        if availability == .debugBuild { return simulatedFlags.contains(.needsAdministrator) }
        #endif
        return UpdateSupport.installNeedsAuthorization()
    }

    /// Called once from `AppDelegate.applicationDidFinishLaunching`, after the engine, widget and status
    /// item are up. Decides `availability`, restores state and starts Sparkle when allowed.
    func start() {
        guard !started else { return }
        started = true
        mode = UserDefaults.standard.string(forKey: UpdateSupport.DefaultsKey.mode).flatMap(UpdateMode.init(rawValue:))
        observeEnvironment()
        #if DEBUG
        availability = .debugBuild
        Log.app.info("update: Debug build — updater off (mode=\(mode?.rawValue ?? "unset")); simulate() drives the update UI")
        #else
        let gate = UpdateSupport.launchGate()
        availability = gate
        let defaults = UserDefaults.standard
        let lastRun = defaults.string(forKey: UpdateSupport.DefaultsKey.lastRunBuild)
        defaults.set(currentBuild, forKey: UpdateSupport.DefaultsKey.lastRunBuild)
        Log.app.info("update: start \(currentVersion) (build \(currentBuild), last run \(lastRun ?? "—")) "
                     + "bundle=\(Bundle.main.bundlePath) availability=\(gate) mode=\(mode?.rawValue ?? "unset — consent pending")")
        consumeInstallMarker()
        startDiskWatch()
        guard gate == .enabled else {
            if case .misconfigured(let detail) = gate { Log.app.error("update: updater not started — \(detail)") }
            recomputePhase()
            return
        }
        clearStalePending()
        // GitHub's release-asset redirect sets session cookies; never store or send them (the app makes
        // no other HTTP requests, so nothing else depends on cookies).
        HTTPCookieStorage.shared.cookieAcceptPolicy = .never
        driver.owner = self
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        // Before start(): the first update cycle then already follows the user's choice.
        apply(mode, to: updater)
        do {
            // The throwing start (not SPUStandardUpdaterController.startUpdater): a failure comes back
            // here as an error instead of a modal "Unable to Check For Updates" alert.
            try updater.start()
        } catch {
            availability = .misconfigured(detail: UpdateUserDriver.describe(error as NSError))
            Log.app.error("update: Sparkle failed to start — \(UpdateUserDriver.describe(error as NSError))")
            recomputePhase()
            return
        }
        self.updater = updater
        observe(updater)
        if let override = defaults.string(forKey: "SUFeedURL") {
            Log.app.warn("update: SUFeedURL is overridden in user defaults → \(override) (pre-release testing only)")
        }
        // A found-but-unanswered update survives a relaunch: re-check once so its row comes back now
        // instead of after the next daily check. Sparkle allows this call only right after start().
        if let pending = defaults.string(forKey: UpdateSupport.DefaultsKey.pendingVersion),
           mode == .automatic || mode == .notifyOnly {
            Log.app.info("update: \(pending) was offered before the relaunch — checking again now")
            updater.checkForUpdatesInBackground()
        }
        recomputePhase()
        #endif
    }

    /// Consent row / Settings: apply and persist the user's preference. A Debug build keeps it in memory
    /// only: Debug and Release share the bundle id — and so one defaults domain — and the installed release
    /// copy must not inherit a mode clicked while reviewing the simulated update UI with ⌘R (it would skip
    /// its consent row, or silently stop checking).
    func setMode(_ mode: UpdateMode) {
        let old = self.mode
        self.mode = mode
        #if DEBUG
        if availability == .debugBuild {
            Log.app.info("update: [debug] mode \(old?.rawValue ?? "unset") → \(mode.rawValue) — in memory only, "
                         + "\(UpdateSupport.DefaultsKey.mode) in the shared defaults stays untouched")
            if phase == .consent { phase = .idle }   // answers a simulated consent row
            return
        }
        #endif
        UserDefaults.standard.set(mode.rawValue, forKey: UpdateSupport.DefaultsKey.mode)
        Log.app.info("update: mode \(old?.rawValue ?? "unset") → \(mode.rawValue)")
        // Sparkle reschedules itself shortly after the setting changes (and checks at once if overdue —
        // e.g. right after the consent row on first launch).
        if let updater { apply(mode, to: updater) }
        recomputePhase()
    }

    /// User-initiated check ("Check now", status menu, Retry).
    func checkNow() {
        if handledBySimulation("checkNow") { return }
        guard availability == .enabled, let updater else {
            Log.app.info("update: check unavailable (\(availability))")
            return
        }
        focusRequest += 1
        if let version = restartNeededVersion {
            // The newer build is already on disk: the answer to "check" is the Restart row (`canCheckNow` is
            // false here; this covers a caller that didn't ask).
            Log.app.info("update: check requested while \(version) waits for a restart — showing Restart")
            return
        }
        oneShot = nil
        if immediateInstall != nil {
            // Sparkle's session is parked on the staged update; the answer to "check" is the Restart row.
            stagedSnoozed = false
            Log.app.info("update: check requested while an update is staged — showing Restart")
            recomputePhase()
            return
        }
        if case .failed = session { setSession(.idle, "retry") }
        guard updater.canCheckForUpdates else {
            Log.app.info("update: check requested while Sparkle is busy (background check or download)")
            recomputePhase()
            return
        }
        Log.app.info("update: user-initiated check")
        updater.checkForUpdates()
    }

    /// Primary action: `.available` → download + install; `.readyToInstall` → quit, install, relaunch;
    /// informational updates open their link. No-op while `restartBlockedByPermission`.
    func install() {
        if handledBySimulation("install") { return }
        guard updater != nil else { return }
        // Informational-only item: nothing to download — open its page and close the offer.
        if case .found(let reply, _)? = heldChoice, let info = sessionInfo, info.isInformationalOnly {
            heldChoice = nil
            open(info.infoURL ?? info.releaseNotesURL ?? UpdateSupport.releasePageURL(version: info.displayVersion))
            setSession(.idle, "informational update opened")
            reply(.dismiss)
            return
        }
        guard !restartBlockedByPermission else {
            Log.app.info("update: install held — a permission request is pending")
            return
        }
        // Silent path: downloaded and staged in the background (automatic mode).
        if let immediate = immediateInstall {
            let info = sessionInfo ?? Self.unknownInfo
            prepareForQuit(info)
            setSession(.installing(info), "restart to install (staged update)")
            scheduleInstallRetry()
            immediate()
            return
        }
        switch heldChoice {
        case .found(let reply, let stage)?:
            let info = sessionInfo ?? Self.unknownInfo
            heldChoice = nil
            userChoseInstall = true
            switch stage {
            case .notDownloaded:
                setSession(.downloading(info, fraction: nil), "user chose Update")
            case .downloaded:
                setSession(.extracting(info, fraction: 0), "user chose Update (already downloaded)")
            case .installing:
                // The installer is already staged: Sparkle may quit us right away ("fast install & relaunch").
                prepareForQuit(info)
                setSession(.installing(info), "user chose Update (installer already staged)")
                scheduleInstallRetry()
            @unknown default:
                setSession(.downloading(info, fraction: nil), "user chose Update")
            }
            reply(.install)
        case .ready(let reply)?:
            let info = sessionInfo ?? Self.unknownInfo
            heldChoice = nil
            prepareForQuit(info)
            setSession(.installing(info), "user chose Restart")
            scheduleInstallRetry()
            reply(.install)
        case nil:
            if case .installing = session, let retry = retryTermination {
                Log.app.info("update: install pressed again — re-sending the quit request")
                retry()
            } else {
                Log.app.info("update: install() with nothing to install (phase \(Self.name(phase)))")
            }
        }
    }

    /// Hide an `.available` update until the next scheduled check.
    func later() {
        if handledBySimulation("later") { return }
        if sessionInfo?.isCritical == true, heldChoice != nil {
            Log.app.info("update: Later ignored — critical update")
            return
        }
        switch heldChoice {
        case .found(let reply, _)?:
            // At stage `.downloaded` Sparkle keeps the download for the next reminder; nothing installs on quit.
            heldChoice = nil
            if let info = sessionInfo { persistPending(info) }
            setSession(.idle, "later")
            reply(.dismiss)
        case .ready(let reply)?:
            // Sparkle keeps the installer staged: it installs when the app quits. Later also withdraws an
            // earlier Update click whose last step a permission request was holding.
            heldChoice = nil
            userChoseInstall = false
            setSession(.idle, "later — installs when the app quits")
            reply(.dismiss)
        case nil:
            if immediateInstall != nil, case .readyToInstall = session {
                stagedSnoozed = true
                Log.app.info("update: staged update hidden until the next check (it installs when the app quits)")
                recomputePhase()
            } else {
                Log.app.info("update: later() with nothing to postpone (phase \(Self.name(phase)))")
            }
        }
    }

    /// Never offer this version again (not for critical updates).
    func skipVersion() {
        if handledBySimulation("skipVersion") { return }
        guard case .found(let reply, let stage)? = heldChoice, let info = sessionInfo else {
            Log.app.info("update: skipVersion() with no offer to skip (phase \(Self.name(phase)))")
            return
        }
        guard !info.isCritical else {
            Log.app.info("update: Skip ignored — critical update")
            return
        }
        heldChoice = nil
        clearPending()
        if stage == .installing { stagedForQuit = nil }   // skipping also cancels the staged install
        setSession(.idle, "skipped \(info.displayVersion)")
        reply(.skip)
    }

    /// Cancel a user-initiated check or a download in progress.
    func cancel() {
        if handledBySimulation("cancel") { return }
        if let cancellation = checkCancellation {
            checkCancellation = nil
            setSession(.idle, "check cancelled")
            cancellation()
        } else if let cancellation = downloadCancellation {
            downloadCancellation = nil
            userChoseInstall = false
            setSession(.idle, "download cancelled")
            cancellation()
        } else {
            Log.app.info("update: cancel() with nothing cancellable (phase \(Self.name(phase)))")
        }
    }

    /// Dismiss a transient / one-shot phase (`upToDate`, `incompatible`, `failed`, `updated`).
    func dismiss() {
        if handledBySimulation("dismiss") { return }
        switch phase {
        case .updated, .failed(.didNotInstall):
            oneShot = nil
            Log.app.info("update: note dismissed")
            recomputePhase()
        case .upToDate, .incompatible, .failed:
            setSession(.idle, "dismissed")
        default:
            break
        }
    }

    /// Open the release notes page (or the informational update's link) in the browser.
    func openReleaseNotes() {
        let url: URL?
        switch phase {
        case .available(let info), .downloading(let info, _), .extracting(let info, _),
             .readyToInstall(let info), .installing(let info):
            url = info.isInformationalOnly
                ? info.infoURL ?? info.releaseNotesURL
                : info.releaseNotesURL ?? UpdateSupport.releasePageURL(version: info.displayVersion) ?? info.infoURL
        case .updated(let version), .restartNeeded(let version), .failed(.didNotInstall(let version)),
             .incompatible(let version, _):
            url = UpdateSupport.releasePageURL(version: version)
        default:
            url = UpdateSupport.releasePageURL(version: currentVersion)
        }
        open(url)
    }

    /// `.moveToApplications`: reveal the running bundle in Finder so the user can drag it to Applications.
    func revealInFinder() {
        let running = Bundle.main.bundleURL
        // A translocated copy lives on a random read-only mount; point at the original the user opened.
        let target = UpdateSupport.originalURL(forTranslocated: running) ?? running
        NSWorkspace.shared.activateFileViewerSelecting([target])
        Log.app.info("update: revealed \(target.path) in Finder")
    }

    /// `.restartNeeded`: quit and relaunch from the (newer) bundle on disk.
    func restartNow() {
        if handledBySimulation("restartNow") { return }
        guard !restartBlockedByPermission else {
            Log.app.info("update: restart held — a permission request is pending")
            return
        }
        // A Sparkle installer that is still armed runs as we quit (an update staged in this process, or one
        // Sparkle couldn't cancel) — then the watchdog must wait for it instead of reopening mid-swap.
        let installerArmed = stagedForQuit != nil || immediateInstall != nil
            || !UpdateSupport.sparkleInstallerPIDs(bundleID: Bundle.main.bundleIdentifier ?? "com.hakkazuu.ccemaphore",
                                                   bundleURL: Bundle.main.bundleURL).isEmpty
        guard rearmWatchdog(awaitInstaller: installerArmed, "restart into the bundle on disk") else {
            Log.app.error("update: restart cancelled — the relaunch watchdog could not be started")
            return
        }
        Log.app.info("update: restarting into the bundle on disk (\(restartNeededVersion ?? "?"))"
                     + (installerArmed ? " — a staged Sparkle installer runs first" : ""))
        NSApp.terminate(nil)
    }

    #if DEBUG
    /// The live Sparkle state behind `readyInstallsOnQuit`, `installWaitsForPermission` and
    /// `installNeedsAdministrator`, which a Debug build never has: `simulate()` sets it instead.
    struct SimulatedFlags: OptionSet {
        let rawValue: Int
        static let installsOnQuit     = SimulatedFlags(rawValue: 1 << 0)
        static let waitsForPermission = SimulatedFlags(rawValue: 1 << 1)
        static let needsAdministrator = SimulatedFlags(rawValue: 1 << 2)
    }
    private(set) var simulatedFlags: SimulatedFlags = []

    /// Debug builds only (the updater itself is off there): force any phase — with the held states its
    /// row reads (`flags`) — so every update surface can be checked visually with ⌘R. `.idle` clears the
    /// simulation.
    func simulate(_ phase: UpdatePhase, flags: SimulatedFlags = []) {
        simulatedFlags = phase == .idle ? [] : flags   // before `phase`: its change re-renders the row
        self.phase = phase
    }
    #endif

    // MARK: - State behind the public surface

    /// The `SPUUserDriver` reply the panel currently owes Sparkle (one at a time).
    private enum HeldChoice {
        /// `showUpdateFound` — the offer, at the stage Sparkle reported.
        case found(reply: (SPUUserUpdateChoice) -> Void, stage: SPUUserUpdateStage)
        /// `showReady(toInstallAndRelaunch:)` — downloaded, validated, installer staged.
        case ready(reply: (SPUUserUpdateChoice) -> Void)
    }

    private var started = false
    private var updater: SPUUpdater?
    private let driver = UpdateUserDriver()
    /// Sparkle's view of the world: the session phase (see `recomputePhase()` for where it ranks).
    private var session: UpdatePhase = .idle
    /// The update the current (or last) session is about.
    private var sessionInfo: UpdateInfo?
    private var heldChoice: HeldChoice?
    private var checkCancellation: (() -> Void)?
    private var downloadCancellation: (() -> Void)?
    private var retryTermination: (() -> Void)?
    /// Silent path: Sparkle's "install and relaunch now" block (callable more than once).
    private var immediateInstall: (() -> Void)?
    /// `shouldPostponeRelaunch`: Sparkle's continuation, held while a permission request is pending.
    /// Publishes on change: `installWaitsForPermission` reads it while the phase stays `.installing`.
    private var postponedRelaunch: (() -> Void)? {
        willSet { objectWillChange.send() }
    }
    /// The user pressed Update, so "ready to install" is answered for them (`installWaitsForPermission`).
    private var userChoseInstall = false {
        willSet { if newValue != userChoseInstall { objectWillChange.send() } }
    }
    /// An installer is staged and waits for the app to quit (it installs on ANY quit) — the update the
    /// install marker records. Cleared for a staged install the bundle on disk already supersedes.
    private var stagedForQuit: UpdateInfo?
    /// `later()` on a silently staged update: hide the row (it still installs on quit).
    private var stagedSnoozed = false
    private var downloadExpected: UInt64?
    private var downloadReceived: UInt64 = 0
    /// The armed relaunch watchdog. Cleared when it exits while we still run (`watchdogDidExit`, reaped on
    /// the main thread), so a later quit-to-install arms a new one and `kill()` never hits a recycled pid.
    private var watchdogPID: pid_t?
    /// One-shot launch note: `.updated` / `.failed(.didNotInstall)`.
    private var oneShot: UpdatePhase?
    /// The bundle on disk is newer than this process (see `startDiskWatch`).
    private var restartNeededVersion: String?
    /// Mirror of `SPUUpdater.canCheckForUpdates` (KVO) so `canCheckNow` stays fresh in SwiftUI.
    @Published private var sparkleCanCheck = false
    private var cancellables = Set<AnyCancellable>()
    private var diskTimer: Timer?
    private var transientToken = 0
    private var installToken = 0

    private static let unknownInfo = UpdateInfo(displayVersion: "?", buildVersion: "?", releaseNotesMarkdown: nil,
                                                releaseNotesURL: nil, isCritical: false, isInformationalOnly: false,
                                                infoURL: nil)

    /// How long a user-initiated check's result stays before the row returns to idle by itself.
    private static let upToDateShownFor: UInt64 = 5_000_000_000
    /// Longer than "up to date": it names a version and the macOS / Mac it needs.
    private static let incompatibleShownFor: UInt64 = 15_000_000_000

    /// The single place `phase` is derived. Precedence:
    /// 1. `restartNeeded` — nothing else matters until we restart into the newer bundle on disk;
    /// 2. the `failed(.didNotInstall)` note — kept above the session on purpose: the launch right after a
    ///    failed install re-checks at once (pending version), and the re-found offer must not erase the
    ///    report within seconds; its Retry and Dismiss both bring that offer forward;
    /// 3. the Sparkle session, when not idle (a silently staged update hidden with Later counts as idle) —
    ///    an informational note never hides an actionable update;
    /// 4. the `updated` note (any later session activity also clears it for good — `setSession`);
    /// 5. `moveToApplications`, 6. `consent` (only with an idle session: a check the user starts before
    ///    answering is shown over it, and the row returns when that check ends), 7. `idle`.
    private func recomputePhase() {
        #if DEBUG
        if availability == .debugBuild { return }   // Debug: `phase` belongs to simulate()
        #endif
        var visibleSession = session
        if stagedSnoozed, case .readyToInstall = session { visibleSession = .idle }
        let next: UpdatePhase
        if let version = restartNeededVersion {
            next = .restartNeeded(version: version)
        } else if let note = oneShot, case .failed = note {
            next = note
        } else if visibleSession != .idle {
            next = visibleSession
        } else if let note = oneShot {
            next = note
        } else if availability == .needsMoveToApplications {
            next = .moveToApplications
        } else if availability == .enabled, mode == nil {
            next = .consent
        } else {
            next = .idle
        }
        guard next != phase else { return }
        if Self.name(next) != Self.name(phase) {
            Log.app.info("update: phase \(Self.name(phase)) → \(Self.name(next))")
        }
        phase = next
    }

    private func setSession(_ next: UpdatePhase, _ why: String = "") {
        if Self.name(next) != Self.name(session) {
            Log.app.info("update: session \(Self.name(session)) → \(Self.name(next))\(why.isEmpty ? "" : " — \(why)")")
        }
        session = next
        // "Updated to X" is informational: the first later session activity (a check, an offer, a staged
        // update, an error) supersedes it for good — it must neither hide that activity nor come back after it.
        if next != .idle, case .updated? = oneShot {
            oneShot = nil
            Log.app.info("update: 'updated' note superseded by \(Self.name(next))")
        }
        switch next {
        case .upToDate: scheduleTransientReset(after: Self.upToDateShownFor)
        case .incompatible: scheduleTransientReset(after: Self.incompatibleShownFor)
        default: break
        }
        recomputePhase()
    }

    /// `.upToDate` / `.incompatible` are transient: back to idle after a while unless something replaced them.
    private func scheduleTransientReset(after nanoseconds: UInt64) {
        transientToken &+= 1
        let token = transientToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self, self.transientToken == token else { return }
            switch self.session {
            case .upToDate, .incompatible: self.setSession(.idle, "check result expired")
            default: break
            }
        }
    }

    /// We asked Sparkle to quit us; if we're still here after a while (the quit event got lost or was
    /// delayed), ask again — both Sparkle handlers may be invoked repeatedly for exactly this case. A
    /// re-invocation skips Sparkle's postpone hook, so the loop only re-sends while no permission request is
    /// pending; while one is (or while Sparkle's relaunch is postponed for one) it keeps looking, and the
    /// resumed relaunch restarts it (`permissionGateChanged`).
    private func scheduleInstallRetry() {
        installToken &+= 1
        let token = installToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.installToken == token, case .installing = self.session else { return }
            if self.postponedRelaunch != nil || self.restartBlockedByPermission {
                self.scheduleInstallRetry()
                return
            }
            Log.app.warn("update: still running 20s after the install was triggered — re-sending the quit request")
            if let retry = self.retryTermination { retry() } else { self.immediateInstall?() }
        }
    }

    /// Debug builds have no Sparkle: an action just ends the `simulate()`d phase, so every surface can
    /// be clicked through with ⌘R without anything real happening.
    private func handledBySimulation(_ action: String) -> Bool {
        #if DEBUG
        guard availability == .debugBuild else { return false }
        Log.app.debug("update: [debug] \(action) — ends the simulated phase")
        simulate(.idle)
        return true
        #else
        return false
        #endif
    }

    // MARK: Sparkle settings

    /// `UpdateMode` → Sparkle's two persisted switches. Order matters: Sparkle ignores
    /// `automaticallyDownloadsUpdates` while automatic checks are off (`allowsAutomaticUpdates` follows
    /// them), so downloads are cleared before checks go off and set after they come on. `nil` (no
    /// consent yet) means no automatic checks at all.
    private func apply(_ mode: UpdateMode?, to updater: SPUUpdater) {
        let checks = mode == .automatic || mode == .notifyOnly
        let downloads = mode == .automatic
        if checks {
            if !updater.automaticallyChecksForUpdates { updater.automaticallyChecksForUpdates = true }
            if updater.automaticallyDownloadsUpdates != downloads { updater.automaticallyDownloadsUpdates = downloads }
        } else {
            if updater.automaticallyDownloadsUpdates { updater.automaticallyDownloadsUpdates = false }
            if updater.automaticallyChecksForUpdates { updater.automaticallyChecksForUpdates = false }
        }
        Log.app.info("update: Sparkle automatic checks=\(updater.automaticallyChecksForUpdates) "
                     + "downloads=\(updater.automaticallyDownloadsUpdates) (mode \(mode?.rawValue ?? "unset"))")
    }

    private func observe(_ updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in MainActor.assumeIsolated { self?.sparkleCanCheck = value } }
            .store(in: &cancellables)
        updater.publisher(for: \.lastUpdateCheckDate, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] date in MainActor.assumeIsolated { self?.lastCheckDate = date } }
            .store(in: &cancellables)
    }

    /// Permission requests gate Restart/Install (and a postponed relaunch); app termination may install a
    /// staged update — record it so the next launch can report the outcome.
    private func observeEnvironment() {
        StateEngine.shared.$pendingRequests
            .map(\.isEmpty)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEmpty in MainActor.assumeIsolated { self?.permissionGateChanged(clear: isEmpty) } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.applicationWillTerminate() } }
            .store(in: &cancellables)
    }

    private func permissionGateChanged(clear: Bool) {
        // `restartBlockedByPermission` / `installWaitsForPermission` derive from StateEngine.
        objectWillChange.send()
        // The value arrives one main-queue turn after the change (`receive(on:)`): re-read the live gate, so a
        // request that arrived in between still holds the quit back — its blocking hook must not be cut off
        // (Sparkle consults the postpone hook only once per install).
        guard clear, !restartBlockedByPermission else { return }
        if let resume = postponedRelaunch {
            postponedRelaunch = nil
            Log.app.info("update: permission requests resolved — resuming the postponed relaunch")
            // Re-arm for this quit: the watchdog armed at the click may have given up meanwhile (or be close to
            // its cap), and the silent path never comes back through prepareForQuit on its own. (A stale install
            // — superseded on disk while it waited — gets no marker: `writeInstallMarker`.)
            writeInstallMarker(sessionInfo ?? Self.unknownInfo, reason: "resuming the postponed relaunch")
            rearmWatchdog(awaitInstaller: true, "resuming the postponed relaunch")
            resume()
            // The quit request can still get lost: restart the retry loop for this attempt.
            scheduleInstallRetry()
        } else if userChoseInstall, case .ready? = heldChoice {
            // The user pressed Update; only the pending request held the final step back.
            Log.app.info("update: permission requests resolved — finishing the install the user asked for")
            install()
        }
    }

    private func applicationWillTerminate() {
        guard let info = stagedForQuit,
              UserDefaults.standard.dictionary(forKey: UpdateSupport.DefaultsKey.installMarker) == nil else { return }
        writeInstallMarker(info, reason: "the staged update installs as the app quits")
    }

    // MARK: Restart needed (bundle replaced underneath us)

    /// Every minute, read our own Info.plist from disk (not through `Bundle`, which caches it): a higher
    /// `CFBundleVersion` means the bundle was replaced while we run — updated from another user session or
    /// by hand. Hooks already run the new binary, so the old GUI should restart.
    private func startDiskWatch() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkBundleOnDisk() }
        }
        RunLoop.main.add(timer, forMode: .common)
        diskTimer = timer
    }

    private func checkBundleOnDisk() {
        guard restartNeededVersion == nil,
              let plist = UpdateSupport.infoPlist(ofBundle: Bundle.main.bundleURL),
              let diskBuild = plist["CFBundleVersion"] as? String,
              let disk = Int(diskBuild), let running = Int(currentBuild), disk > running else { return }
        let version = plist["CFBundleShortVersionString"] as? String ?? diskBuild
        restartNeededVersion = version
        Log.app.info("update: bundle on disk is \(version) (build \(diskBuild)), running \(currentVersion) (build \(currentBuild)) — restart needed")
        cancelStaleStagedInstall()
        recomputePhase()
    }

    /// `CFBundleVersion` of the bundle on disk right now (a fresh Info.plist read), nil if unreadable.
    private func diskBuild() -> String? {
        UpdateSupport.infoPlist(ofBundle: Bundle.main.bundleURL)?["CFBundleVersion"] as? String
    }

    /// An update staged (or about to be staged) in this process is stale once the bundle was replaced
    /// underneath us with at least that build: installing it on quit would reinstall the same build or swap
    /// an OLDER one over the newer bundle — Sparkle's downgrade guard ran only when it was staged, and the
    /// swap after we quit doesn't look again.
    private func isSupersededOnDisk(_ info: UpdateInfo) -> Bool {
        guard restartNeededVersion != nil, let disk = diskBuild() else { return false }
        return UpdateSupport.isBuild(disk, atLeast: info.buildVersion)
    }

    /// The bundle was just found replaced: cancel a staged install it supersedes, where Sparkle allows it,
    /// and never record an install marker for it (the next launch must not report "Updated to <stale>").
    private func cancelStaleStagedInstall() {
        guard let staged = stagedForQuit, isSupersededOnDisk(staged) else { return }
        let what = "staged \(staged.displayVersion) (build \(staged.buildVersion)) is superseded by the bundle on disk"
        stagedForQuit = nil
        // A marker already written for it (Restart / Update was clicked, and a permission request is holding
        // the quit) would report the stale build as "Updated to …" after the next launch.
        UserDefaults.standard.removeObject(forKey: UpdateSupport.DefaultsKey.installMarker)
        switch heldChoice {
        case .ready(let reply)?:
            heldChoice = nil
            userChoseInstall = false
            Log.app.warn("update: \(what) — cancelling it")
            setSession(.idle, "stale staged update cancelled")
            reply(.skip)   // cancels the staged installer (Sparkle doesn't mark the version skipped here)
        case .found(let reply, let stage)? where stage == .installing:
            heldChoice = nil
            Log.app.warn("update: \(what) — cancelling it")
            setSession(.idle, "stale staged update cancelled")
            reply(.skip)   // cancels the staged installer (and skips that older version)
        default:
            if immediateInstall != nil {
                Log.app.warn("update: \(what), but Sparkle has no cancel for a silently staged update — it may still "
                             + "run when the app quits (the next check offers the newer build again); no install marker for it")
            } else if session == .idle, let updater, updater.canCheckForUpdates {
                // Staged, then dismissed with Later: Sparkle keeps the installer but holds no session. Resuming it
                // re-offers it at stage `.installing`, which `driverUpdateFound` cancels as stale. (With a session
                // on screen — e.g. `.installing`, its relaunch postponed — a check would only re-show it.)
                Log.app.warn("update: \(what) — resuming it to cancel it")
                updater.checkForUpdates()
            } else {
                Log.app.warn("update: \(what) — it can't be cancelled right now; no install marker for it")
            }
        }
    }

    // MARK: Install marker, watchdog, pending version

    /// About to quit for an install: record what we expect to come back as, and arm the relaunch
    /// watchdog unless one is armed. Idempotent (several paths can lead here for one install).
    private func prepareForQuit(_ info: UpdateInfo) {
        writeInstallMarker(info, reason: "quitting to install")
        if watchdogPID == nil { rearmWatchdog(awaitInstaller: true, "quitting to install") }
    }

    /// Spawn a fresh relaunch watchdog and retire the armed one, if any — in that order, so the safety net
    /// never lapses. False if it couldn't be spawned (the armed one, if any, stays).
    @discardableResult
    private func rearmWatchdog(awaitInstaller: Bool, _ why: String) -> Bool {
        guard let pid = UpdateSupport.spawnRelaunchWatchdog(
            waitingFor: getpid(), bundleURL: Bundle.main.bundleURL, awaitInstaller: awaitInstaller,
            onExit: { [weak self] pid in self?.watchdogDidExit(pid) }) else { return false }
        stopWatchdog("replaced (\(why))")
        watchdogPID = pid
        return true
    }

    /// Stop the armed watchdog. Safe to signal: it is reaped only on this (main) thread, so a pid still held
    /// here belongs to it — alive or a zombie — and was never recycled for an unrelated process.
    private func stopWatchdog(_ why: String) {
        guard let pid = watchdogPID else { return }
        watchdogPID = nil
        kill(pid, SIGTERM)
        Log.app.info("update: relaunch watchdog pid=\(pid) stopped — \(why)")
    }

    /// The watchdog ended while we still run (it gives up once the app hasn't quit within its cap): forget
    /// it, so the next quit-to-install arms a new one.
    private func watchdogDidExit(_ pid: pid_t) {
        guard watchdogPID == pid else { return }
        watchdogPID = nil
        Log.app.warn("update: relaunch watchdog pid=\(pid) exited while the app is still running — the next quit arms a new one")
    }

    /// The install attempt ended while we're still running (error, cancelled authorization): this
    /// session reports it, so drop the marker and stop the watchdog — it must not relaunch us after a
    /// later, ordinary quit.
    private func abandonQuit(_ why: String) {
        stopWatchdog("install abandoned")
        postponedRelaunch = nil
        UserDefaults.standard.removeObject(forKey: UpdateSupport.DefaultsKey.installMarker)
        Log.app.warn("update: install abandoned — \(why)")
    }

    /// Never for an install the bundle on disk already supersedes (`isSupersededOnDisk`): swapping it in would
    /// put the same or an older build in place, and the next launch must not report that as "Updated to …".
    private func writeInstallMarker(_ info: UpdateInfo, reason: String) {
        if isSupersededOnDisk(info) {
            UserDefaults.standard.removeObject(forKey: UpdateSupport.DefaultsKey.installMarker)
            Log.app.warn("update: no install marker for \(info.displayVersion) (build \(info.buildVersion)) — the bundle "
                         + "on disk supersedes it (\(reason))")
            return
        }
        let marker: [String: Any] = ["version": info.displayVersion, "build": info.buildVersion,
                                     "fromBuild": currentBuild, "date": Date()]
        UserDefaults.standard.set(marker, forKey: UpdateSupport.DefaultsKey.installMarker)
        Log.app.info("update: install marker → \(info.displayVersion) (build \(info.buildVersion)) — \(reason)")
    }

    /// Launch: the previous run quit to install → show the outcome once, then forget the marker.
    private func consumeInstallMarker() {
        let defaults = UserDefaults.standard
        guard let marker = defaults.dictionary(forKey: UpdateSupport.DefaultsKey.installMarker) else { return }
        defaults.removeObject(forKey: UpdateSupport.DefaultsKey.installMarker)
        let version = marker["version"] as? String ?? "?"
        let build = marker["build"] as? String ?? ""
        let from = marker["fromBuild"] as? String ?? "?"
        if !build.isEmpty, UpdateSupport.isBuild(currentBuild, atLeast: build) {
            let shown = currentBuild == build ? version : currentVersion
            oneShot = .updated(version: shown)
            Log.app.info("update: updated build \(from) → \(currentBuild) (\(shown))")
        } else {
            oneShot = .failed(.didNotInstall(version: version))
            focusRequest += 1
            Log.app.error("update: \(version) (build \(build)) did not install — still on build \(currentBuild)")
        }
    }

    private func persistPending(_ info: UpdateInfo) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: UpdateSupport.DefaultsKey.pendingVersion) != info.displayVersion
                || defaults.string(forKey: UpdateSupport.DefaultsKey.pendingBuild) != info.buildVersion else { return }
        defaults.set(info.displayVersion, forKey: UpdateSupport.DefaultsKey.pendingVersion)
        defaults.set(info.buildVersion, forKey: UpdateSupport.DefaultsKey.pendingBuild)
        Log.app.info("update: remembering \(info.displayVersion) (build \(info.buildVersion)) across relaunches")
    }

    private func clearPending() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: UpdateSupport.DefaultsKey.pendingVersion) != nil
                || defaults.object(forKey: UpdateSupport.DefaultsKey.pendingBuild) != nil else { return }
        defaults.removeObject(forKey: UpdateSupport.DefaultsKey.pendingVersion)
        defaults.removeObject(forKey: UpdateSupport.DefaultsKey.pendingBuild)
        Log.app.info("update: pending version cleared")
    }

    /// A remembered offer this build already satisfies (installed on quit, or by hand) is stale.
    private func clearStalePending() {
        guard let build = UserDefaults.standard.string(forKey: UpdateSupport.DefaultsKey.pendingBuild),
              UpdateSupport.isBuild(currentBuild, atLeast: build) else { return }
        clearPending()
    }

    private func open(_ url: URL?) {
        guard let url, url.scheme == "https" else {
            Log.app.warn("update: no https link to open (\(url?.absoluteString ?? "none"))")
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Log helpers

    /// Phase case name (+ version), without progress fractions — log lines stay one per transition.
    private static func name(_ phase: UpdatePhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .consent: return "consent"
        case .checking: return "checking"
        case .upToDate: return "upToDate"
        case .incompatible(let v, let requirement): return "incompatible(\(v), \(describe(requirement)))"
        case .available(let i): return "available(\(i.displayVersion)\(i.isDownloaded ? ", downloaded" : ""))"
        case .downloading(let i, _): return "downloading(\(i.displayVersion))"
        case .extracting(let i, _): return "extracting(\(i.displayVersion))"
        case .readyToInstall(let i): return "readyToInstall(\(i.displayVersion))"
        case .installing(let i): return "installing(\(i.displayVersion))"
        case .failed(let f): return "failed(\(f))"
        case .moveToApplications: return "moveToApplications"
        case .updated(let v): return "updated(\(v))"
        case .restartNeeded(let v): return "restartNeeded(\(v))"
        }
    }

    private static func describe(_ reason: SPUNoUpdateFoundReason) -> String {
        switch reason {
        case .unknown: return "unknown"
        case .onLatestVersion: return "on the latest version"
        case .onNewerThanLatestVersion: return "newer than the feed's latest"
        case .systemIsTooOld: return "macOS too old for the latest version"
        case .systemIsTooNew: return "macOS too new for the latest version"
        case .hardwareDoesNotSupportARM64: return "hardware doesn't support the latest version"
        @unknown default: return "reason \(reason.rawValue)"
        }
    }

    private static func describe(_ requirement: UpdateRequirement) -> String {
        switch requirement {
        case .newerMacOS(let minimum): return "needs macOS \(minimum ?? "?") or later"
        case .olderMacOS(let maximum): return "needs macOS \(maximum ?? "?") or earlier"
        case .appleSilicon: return "needs Apple silicon"
        }
    }

    private static func describe(_ stage: SPUUserUpdateStage) -> String {
        switch stage {
        case .notDownloaded: return "not downloaded"
        case .downloaded: return "downloaded (no installer yet)"
        case .installing: return "installer staged"
        @unknown default: return "stage \(stage.rawValue)"
        }
    }

    /// Why the feed's newer `latest` item can't run here, from Sparkle's not-found reason — nil when the
    /// reason isn't about this Mac (up to date, newer than the feed, unknown).
    private static func requirement(for reason: SPUNoUpdateFoundReason, latest: SUAppcastItem) -> UpdateRequirement? {
        func nonEmpty(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        switch reason {
        case .systemIsTooOld: return .newerMacOS(minimum: nonEmpty(latest.minimumSystemVersion))
        case .systemIsTooNew: return .olderMacOS(maximum: nonEmpty(latest.maximumSystemVersion))
        case .hardwareDoesNotSupportARM64: return .appleSilicon
        default: return nil
        }
    }
}

// MARK: - UpdateUserDriver → AppUpdater

extension AppUpdater {
    /// Never shown: `updaterShouldPromptForPermissionToCheck(forUpdates:)` returns false and the
    /// consent row owns this question. If Sparkle asks anyway, answer from the stored mode at once — a
    /// held reply would stall the updater.
    func driverPermissionRequest(reply: (SUUpdatePermissionResponse) -> Void) {
        let checks = mode == .automatic || mode == .notifyOnly
        Log.app.warn("update: Sparkle asked for check permission — answered from mode \(mode?.rawValue ?? "unset")")
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: checks,
                                         automaticUpdateDownloading: NSNumber(value: mode == .automatic),
                                         sendSystemProfile: false))
    }

    func driverCheckStarted(cancellation: @escaping () -> Void) {
        checkCancellation = cancellation
        setSession(.checking, "user-initiated check")
    }

    func driverUpdateFound(_ found: UpdateInfo, stage: SPUUserUpdateStage, userInitiated: Bool,
                           reply: @escaping (SPUUserUpdateChoice) -> Void) {
        var info = found
        // `.downloaded`: Sparkle resumed a download it only KEPT (typically the silent install needed an
        // administrator password). No installer exists yet, so nothing installs on quit — it's an offer.
        info.isDownloaded = stage == .downloaded
        if stage == .installing, isSupersededOnDisk(info) {
            // A resumed staged install the bundle on disk already supersedes (see `cancelStaleStagedInstall`).
            Log.app.warn("update: resumed staged \(info.displayVersion) (build \(info.buildVersion)) is superseded "
                         + "by the bundle on disk — cancelling it")
            if stagedForQuit?.buildVersion == info.buildVersion { stagedForQuit = nil }
            reply(.skip)
            return
        }
        if heldChoice != nil { Log.app.warn("update: new offer while a reply was still held — dropping the stale one") }
        checkCancellation = nil
        sessionInfo = info
        heldChoice = .found(reply: reply, stage: stage)
        userChoseInstall = false
        stagedSnoozed = false
        if stage == .installing { stagedForQuit = info }
        persistPending(info)
        if userInitiated { focusRequest += 1 }
        // Only a staged installer is "ready"; a kept download still needs Update (extraction, maybe a password).
        let staged = stage == .installing && !info.isInformationalOnly
        setSession(staged ? .readyToInstall(info) : .available(info),
                   "found \(info.displayVersion) (build \(info.buildVersion)), \(Self.describe(stage)), "
                   + "\(userInitiated ? "user-initiated" : "scheduled")\(info.isCritical ? ", critical" : "")"
                   + "\(info.isInformationalOnly ? ", informational" : "")")
    }

    func driverNotFound(_ error: NSError) {
        checkCancellation = nil
        let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)
            .flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) }
        let latest = error.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        clearPending()
        focusRequest += 1
        let why = "no update (\(reason.map(Self.describe) ?? "unknown"); feed's latest \(latest?.displayVersionString ?? "—"))"
        // A newer version exists that this Mac can't run: say so instead of "up to date".
        if let reason, let latest, let requirement = Self.requirement(for: reason, latest: latest) {
            setSession(.incompatible(version: latest.displayVersionString, requirement: requirement), why)
        } else {
            setSession(.upToDate, why)
        }
    }

    func driverError(_ error: NSError) {
        var downloading = false
        if case .downloading = session { downloading = true }
        let failure = UpdateUserDriver.failure(for: error, downloading: downloading)
        Log.app.error("update: \(failure) — \(UpdateUserDriver.describe(error))")
        checkCancellation = nil
        downloadCancellation = nil
        userChoseInstall = false
        if case .installing = session { abandonQuit("installer error") }
        stagedForQuit = nil
        focusRequest += 1
        setSession(.failed(failure))
    }

    func driverDownloadStarted(cancellation: @escaping () -> Void) {
        downloadCancellation = cancellation
        downloadExpected = nil
        downloadReceived = 0
        setSession(.downloading(sessionInfo ?? Self.unknownInfo, fraction: nil), "download started")
    }

    /// May be wrong or repeated (Sparkle's note): a new expected length restarts the count.
    func driverDownloadExpectedLength(_ length: UInt64) {
        downloadExpected = length > 0 ? length : nil
        downloadReceived = 0
        publishDownloadProgress(force: true)
    }

    func driverDownloadReceived(_ length: UInt64) {
        downloadReceived &+= length
        publishDownloadProgress(force: false)
    }

    /// Re-publish only on a visible change (≥ 1 %): Sparkle reports every network chunk.
    private func publishDownloadProgress(force: Bool) {
        guard case .downloading(let info, let shown) = session else { return }
        var fraction: Double?
        if let expected = downloadExpected { fraction = min(1, Double(downloadReceived) / Double(expected)) }
        if !force {
            if fraction == nil, shown == nil { return }
            if let f = fraction, let s = shown, f < 1, abs(f - s) < 0.01 { return }
        }
        session = .downloading(info, fraction: fraction)
        recomputePhase()
    }

    /// The installer launches as extraction starts (it does the extracting). Where installing needs an
    /// administrator password, macOS asks right now — on our main thread (Sparkle's in-process installer
    /// launcher), so the light and ribbons freeze until it's answered. Logged so a "frozen" report explains
    /// itself.
    func driverExtractionStarted() {
        downloadCancellation = nil   // no longer cancellable once extraction starts
        if installNeedsAdministrator {
            Log.app.warn("update: installing needs an administrator password — macOS asks now; the GUI stays "
                         + "unresponsive until that dialog is answered")
        }
        setSession(.extracting(sessionInfo ?? Self.unknownInfo, fraction: 0), "extracting")
    }

    func driverExtractionProgress(_ progress: Double) {
        guard case .extracting(let info, let shown) = session else { return }
        let p = min(1, max(0, progress))
        guard p >= 1 || abs(p - shown) >= 0.01 else { return }
        session = .extracting(info, fraction: p)
        recomputePhase()
    }

    /// Downloaded, validated, installer staged. If the user already pressed Update, install now (marker +
    /// watchdog first); otherwise hold the reply as `.readyToInstall` until Restart is pressed. A pending
    /// permission request also holds it — then the install continues by itself once the requests clear
    /// (`permissionGateChanged`), since the user already asked for it.
    func driverReadyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let info = sessionInfo ?? Self.unknownInfo
        downloadCancellation = nil
        if isSupersededOnDisk(info) {
            // The bundle was replaced underneath us with this build or a newer one meanwhile.
            userChoseInstall = false
            stagedForQuit = nil
            Log.app.warn("update: \(info.displayVersion) (build \(info.buildVersion)) is ready, but the bundle on disk "
                         + "already supersedes it — cancelling it")
            setSession(.idle, "stale ready update cancelled")
            reply(.skip)
            return
        }
        stagedForQuit = info
        if userChoseInstall, !restartBlockedByPermission {
            prepareForQuit(info)
            setSession(.installing(info), "ready — installing as the user asked")
            scheduleInstallRetry()
            reply(.install)
        } else {
            heldChoice = .ready(reply: reply)
            setSession(.readyToInstall(info),
                       userChoseInstall ? "ready — held while a permission request is pending" : "ready to install")
        }
    }

    func driverInstalling(applicationTerminated: Bool, retry: @escaping () -> Void) {
        retryTermination = applicationTerminated ? nil : retry
        let info = sessionInfo ?? Self.unknownInfo
        prepareForQuit(info)   // normally already done; makes the safety net unconditional
        if case .installing = session { return }
        setSession(.installing(info), "installer started (app terminated: \(applicationTerminated))")
        scheduleInstallRetry()
    }

    func driverInstalled(relaunched: Bool) {
        Log.app.info("update: Sparkle reports the install finished (relaunched: \(relaunched))")
        setSession(.idle)
    }

    /// Sparkle tears the session down: every block it handed us is dead now — drop them (never call).
    /// Acknowledged results (`upToDate`, `incompatible`, `failed`) stay on screen; the silent path isn't
    /// driven by the user driver at all.
    func driverDismiss() {
        heldChoice = nil
        checkCancellation = nil
        downloadCancellation = nil
        retryTermination = nil
        userChoseInstall = false
        downloadExpected = nil
        downloadReceived = 0
        switch session {
        case .upToDate, .incompatible, .failed:
            recomputePhase()
        case .readyToInstall where immediateInstall != nil:
            break
        case .installing where immediateInstall != nil:
            break
        case .installing:
            abandonQuit("Sparkle ended the session before the app quit")
            setSession(.idle, "session dismissed")
        default:
            setSession(.idle, "session dismissed")
        }
    }

    /// "Check now" while an update is on screen: bring the row forward.
    func driverShowInFocus() {
        stagedSnoozed = false
        focusRequest += 1
        recomputePhase()
    }
}

// MARK: - SPUUpdaterDelegate

extension AppUpdater: SPUUpdaterDelegate {
    /// Sparkle's own permission window never appears: the in-panel consent row asks instead.
    @objc(updaterShouldPromptForPermissionToCheckForUpdates:)
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    /// Notes are embedded Markdown; an HTML `releaseNotesLink` would be an extra request we can't render.
    @objc(updater:shouldDownloadReleaseNotesForUpdate:)
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    // `feedURLString(for:)` is deliberately NOT implemented: Sparkle then honours a `SUFeedURL` user
    // default, which is how pre-release builds are tested (`defaults write … SUFeedURL …`).

    @objc(updater:didFindValidUpdate:)
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Log.app.info("update: feed offers \(item.displayVersionString) (build \(item.versionString))")
        persistPending(UpdateUserDriver.info(from: item))
    }

    @objc(updaterDidNotFindUpdate:error:)
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let reason = ((error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)
            .flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) }
        Log.app.info("update: no new version (\(reason.map(Self.describe) ?? "unknown"))")
        clearPending()
    }

    /// Silent path (automatic mode): the update is downloaded and its installer staged. Returning true
    /// keeps the restart ours — the row offers it — instead of letting Sparkle nag a week later.
    @objc(updater:willInstallUpdateOnQuit:immediateInstallationBlock:)
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let info = UpdateUserDriver.info(from: item)
        sessionInfo = info
        immediateInstall = immediateInstallHandler
        stagedSnoozed = false
        persistPending(info)
        if isSupersededOnDisk(info) {
            // Staged while the bundle on disk already has this build or a newer one; this path has no cancel.
            stagedForQuit = nil
            Log.app.warn("update: \(info.displayVersion) (build \(info.buildVersion)) was staged silently, but the bundle "
                         + "on disk already supersedes it — no install marker for it")
        } else {
            stagedForQuit = info
        }
        setSession(.readyToInstall(info), "staged in the background (installs on quit; Restart installs now)")
        return true
    }

    /// Last gate before Sparkle quits us: never while a permission request is pending — continue once
    /// the requests clear (`permissionGateChanged`).
    @objc(updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard restartBlockedByPermission else { return false }
        postponedRelaunch = installHandler
        Log.app.info("update: relaunch postponed — a permission request is pending")
        return true
    }

    /// Right before the installer takes over (explicit installs only): the marker is the record the next
    /// launch reads, so (re)write it with Sparkle's own item.
    @objc(updater:willInstallUpdate:)
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        writeInstallMarker(UpdateUserDriver.info(from: item), reason: "Sparkle is installing")
    }

    @objc(updaterWillRelaunchApplication:)
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Log.app.info("update: Sparkle will relaunch the app after installing")
    }

    @objc(updater:didAbortWithError:)
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let e = error as NSError
        let code = e.domain == SUSparkleErrorDomain ? SUError(rawValue: OSStatus(truncatingIfNeeded: e.code)) : nil
        if code == .noUpdateError { return }
        Log.app.warn("update: update cycle aborted — \(UpdateUserDriver.describe(e))")
        if code == .runningFromDiskImageError || code == .runningTranslocated {
            availability = .needsMoveToApplications
            // The move note explains this failure and is the fix; a failure row over it would offer a Retry
            // that can't work from here.
            if session == .idle { recomputePhase() } else { setSession(.idle, "running from a transient location") }
            return
        }
        // The silent path reports only here (the user driver isn't involved): a failure after the block
        // was handed over means the staged update is gone.
        if immediateInstall != nil {
            immediateInstall = nil
            stagedForQuit = nil
            if case .installing = session {
                abandonQuit("silent install failed")
                setSession(.failed(UpdateUserDriver.failure(for: e, downloading: false)))
            } else if case .readyToInstall = session {
                setSession(.idle, "staged update aborted")
            }
        }
    }

    @objc(updater:didFinishUpdateCycleForUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastCheckDate = updater.lastUpdateCheckDate
        let e = error as NSError?
        if let e, e.domain == SUSparkleErrorDomain, e.code == Int(SUError.noUpdateError.rawValue) { clearPending() }
        let kind: String
        switch updateCheck {
        case .updates: kind = "user-initiated"
        case .updatesInBackground: kind = "scheduled"
        case .updateInformation: kind = "probe"
        @unknown default: kind = "kind \(updateCheck.rawValue)"
        }
        Log.app.info("update: \(kind) cycle finished — \(e.map(UpdateUserDriver.describe) ?? "ok")")
    }

    @objc(updater:failedToDownloadUpdate:error:)
    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        Log.app.warn("update: download of \(item.displayVersionString) failed — \(UpdateUserDriver.describe(error as NSError))")
    }

    @objc(userDidCancelDownload:)
    func userDidCancelDownload(_ updater: SPUUpdater) {
        Log.app.info("update: download cancelled by the user")
    }

    @objc(updater:userDidMakeChoice:forUpdate:state:)
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        let name: String
        switch choice {
        case .install: name = "install"
        case .dismiss: name = "later"
        case .skip: name = "skip"
        @unknown default: name = "choice \(choice.rawValue)"
        }
        Log.app.info("update: user chose \(name) for \(updateItem.displayVersionString) (\(Self.describe(state.stage)))")
    }

    @objc(updater:willScheduleUpdateCheckAfterDelay:)
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        Log.app.debug("update: next scheduled check in \(Int(delay))s")
    }

    @objc(updaterWillNotScheduleUpdateCheck:)
    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
        Log.app.debug("update: no scheduled checks (automatic checks off)")
    }
}
