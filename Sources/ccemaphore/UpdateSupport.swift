import Foundation
import Darwin
import Security

/// Nonisolated helpers of the in-app updater, usable from the GUI, the hook CLI and diagnostics:
/// the launch gates (Developer ID signature, read-only / translocated location), the relaunch
/// watchdog CLI mode and `--update-status`.
///
/// Deliberately free of AppKit and Sparkle: the watchdog runs as a headless copy of this binary while
/// Sparkle swaps the bundle, and it must never check in with LaunchServices as an "application" (Sparkle
/// sends its quit event to every running app instance of our bundle and waits for them).
enum UpdateSupport {
    /// `UserDefaults` keys the updater owns (Sparkle's own `SU*` keys live beside them).
    enum DefaultsKey {
        /// `UpdateMode.rawValue`; absent until the consent row is answered.
        static let mode = "update.mode"
        /// The last update Sparkle found (display version + build) — re-offered after a relaunch.
        static let pendingVersion = "update.pendingVersion"
        static let pendingBuild = "update.pendingBuild"
        /// `{version, build, fromBuild, date}` written right before we quit to install; read once at the
        /// next launch to show "updated" or "didn't install".
        static let installMarker = "update.installMarker"
        /// `CFBundleVersion` of the last launch (diagnostics).
        static let lastRunBuild = "update.lastRunBuild"
    }

    /// The `SUPublicEDKey` value Info.plist carries until the real EdDSA key is generated. CI refuses to
    /// release with it; the app treats it as `.misconfigured`.
    static let publicKeyPlaceholder = "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"

    /// Developer ID Application, any team: Apple-anchored, issued by the Developer ID CA (…6.2.6) and
    /// carrying the Developer ID leaf marker (…6.1.13). No team pin, so it survives both the G2
    /// certificate renewal and the move to the company team.
    static let developerIDRequirement =
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"

    // MARK: - Launch gates

    /// Whether the updater may run in this process — the single decision `AppUpdater.start()` and
    /// `--update-status` share. Order: Debug build, signature, location, configuration.
    static func launchGate(bundleURL: URL = Bundle.main.bundleURL) -> UpdateAvailability {
        #if DEBUG
        return .debugBuild
        #else
        if !isDeveloperIDSigned() { return .notDeveloperIDSigned }
        if isTransientLocation(bundleURL) { return .needsMoveToApplications }
        if publicKeyIsPlaceholder() {
            return .misconfigured(detail: "SUPublicEDKey is missing or still the placeholder '\(publicKeyPlaceholder)'")
        }
        return .enabled
        #endif
    }

    /// True iff the running code satisfies `developerIDRequirement` (see there). Ad-hoc, unsigned and
    /// Apple Development builds (Xcode ⌘R, Profile, `package_app.sh`, agent compile checks) fail it.
    static func isDeveloperIDSigned() -> Bool { developerIDCheck() == errSecSuccess }

    /// The raw `SecCodeCheckValidity` status behind `isDeveloperIDSigned()` (printed by `--update-status`).
    static func developerIDCheck() -> OSStatus {
        var code: SecCode?
        let selfStatus = SecCodeCopySelf(SecCSFlags(), &code)
        guard selfStatus == errSecSuccess, let code else { return selfStatus }
        var requirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(developerIDRequirement as CFString, SecCSFlags(), &requirement)
        guard reqStatus == errSecSuccess, let requirement else { return reqStatus }
        return SecCodeCheckValidity(code, SecCSFlags(), requirement)
    }

    /// The signing Team ID of the running code, if any (diagnostics only).
    static func signingTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Running from the mounted DMG (read-only volume) or an App Translocation copy. The same two tests
    /// Sparkle uses (`SUHost isRunningOnReadOnlyVolume` / `isRunningTranslocated`): Sparkle refuses to
    /// update from there — silently, for scheduled checks — and a hook path baked in from there dangles
    /// once the DMG is ejected (every hook then exits 127). Cheap: one `statfs` + a substring test.
    static func isTransientLocation(_ bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        isOnReadOnlyVolume(bundleURL) || isTranslocated(bundleURL)
    }

    static func isOnReadOnlyVolume(_ url: URL) -> Bool {
        var info = statfs()
        let rc = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return statfs(path, &info)
        }
        guard rc == 0 else { return false }
        return (info.f_flags & UInt32(MNT_RDONLY)) != 0
    }

    static func isTranslocated(_ url: URL) -> Bool {
        url.path.contains("/AppTranslocation/")
    }

    /// Whether installing over `bundleURL` makes macOS ask for an administrator password. Sparkle's own test
    /// (`SPUSystemNeedsAuthorizationAccessForBundlePath`, SUInstallerLauncher.m) as it works out for a
    /// non-root user: the bundle or its folder isn't writable, or the bundle belongs to another user (Sparkle's
    /// chown probe can only succeed when the owner is the current user). Sparkle runs its installer launcher
    /// in-process and asks for that password on the MAIN thread, so the GUI is unresponsive until it's answered.
    static func installNeedsAuthorization(_ bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        let path = bundleURL.path
        guard access(path, W_OK) == 0, access(bundleURL.deletingLastPathComponent().path, W_OK) == 0 else { return true }
        var info = stat()
        guard stat(path, &info) == 0 else { return true }
        return info.st_uid != getuid()
    }

    /// For a translocated bundle, the original location the user launched (e.g. `~/Downloads/…`), so
    /// "Show in Finder" points at the copy they can actually move. `SecTranslocateCreateOriginalPathForURL`
    /// is not in the public SDK headers, so it is looked up at runtime; nil if unavailable.
    static func originalURL(forTranslocated url: URL) -> URL? {
        guard isTranslocated(url),
              let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(url as CFURL, nil)?.takeRetainedValue() as URL?
    }

    /// `SUPublicEDKey` missing, empty, or still the placeholder → Sparkle can't verify anything.
    static func publicKeyIsPlaceholder(_ info: [String: Any]? = Bundle.main.infoDictionary) -> Bool {
        let key = (info?["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty || key == publicKeyPlaceholder
    }

    // MARK: - Release pages

    /// `https://github.com/<owner>/<repo>/releases`, derived from `SUFeedURL` (a GitHub release-asset
    /// feed), so the fallback "release notes" link never needs a second hard-coded URL.
    static func releasesURL() -> URL? {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let range = feed.range(of: "/releases/") else { return nil }
        let base = String(feed[..<range.lowerBound]) + "/releases"
        guard let url = URL(string: base), url.scheme == "https" else { return nil }
        return url
    }

    /// The GitHub release page of `version` (tags are `v<version>`).
    static func releasePageURL(version: String) -> URL? {
        let v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, v != "?",
              v.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return releasesURL() }
        return releasesURL()?.appendingPathComponent("tag").appendingPathComponent("v" + v)
    }

    /// `CFBundleVersion` comparison: integers numerically (the project's scheme), anything else by equality.
    static func isBuild(_ build: String, atLeast other: String) -> Bool {
        if let a = Int(build), let b = Int(other) { return a >= b }
        return build == other
    }

    // MARK: - Relaunch watchdog

    /// Bounds for every wait in the watchdog: the app must quit, then Sparkle's installer must finish.
    /// Measured in AWAKE time (`waitUntil`), so a Mac that sleeps mid-install doesn't use them up.
    private static let watchdogWaitCap: TimeInterval = 600
    /// After the installer exits, how long Sparkle's own relaunch gets to show up before we open the app.
    private static let relaunchGrace: TimeInterval = 10

    /// Launch the headless watchdog (`--relaunch-watchdog`) as a detached copy of this executable: new
    /// session (`POSIX_SPAWN_SETSID`, so the app's exit doesn't take it down), no inherited descriptors,
    /// stdio on /dev/null. It waits for `pid` to exit (and, for `awaitInstaller`, for Sparkle's installer to
    /// finish), then reopens `bundleURL` unless an instance is already running — the safety net for an
    /// install that fails after the app has quit (Sparkle then never relaunches, and the light would
    /// silently disappear). Returns the watchdog's pid, nil if it couldn't be spawned.
    ///
    /// If the watchdog exits while the app is still running (it gives up once the app hasn't quit within
    /// `watchdogWaitCap`), it is reaped ON THE MAIN THREAD and `onExit` reports it there. Reaping and the
    /// owner's `kill()` therefore never interleave: a pid the owner still holds is alive or a zombie — never
    /// recycled for an unrelated process — and the owner learns to arm a fresh watchdog for the next quit.
    @discardableResult
    static func spawnRelaunchWatchdog(waitingFor pid: pid_t, bundleURL: URL, awaitInstaller: Bool,
                                      onExit: @escaping @MainActor @Sendable (pid_t) -> Void) -> pid_t? {
        guard let exe = Bundle.main.executableURL?.path else {
            Log.app.error("update: watchdog not spawned — no executable path")
            return nil
        }
        let argv = [exe, "--relaunch-watchdog", String(pid), bundleURL.path, awaitInstaller ? "install" : "restart"]
        let envp = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        let cArgv = argv.map { strdup($0) } + [nil]
        let cEnvp = envp.map { strdup($0) } + [nil]
        defer {
            cArgv.forEach { free($0) }
            cEnvp.forEach { free($0) }
        }
        var child: pid_t = 0
        let rc = posix_spawn(&child, exe, &actions, &attr, cArgv, cEnvp)
        guard rc == 0 else {
            Log.app.error("update: watchdog spawn failed: \(String(cString: strerror(rc))) (\(rc))")
            return nil
        }
        // Normally we quit first and launchd adopts it. If it exits while we're still alive: wait for that
        // WITHOUT reaping (`WNOWAIT` keeps the zombie, so its pid can't be reused yet), then reap and report
        // on the main thread — the same thread that may `kill()` it.
        let spawned = child
        Thread.detachNewThread {
            var info = siginfo_t()
            while waitid(P_PID, id_t(spawned), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
            DispatchQueue.main.async {
                var status: Int32 = 0
                _ = waitpid(spawned, &status, WNOHANG)
                MainActor.assumeIsolated { onExit(spawned) }
            }
        }
        Log.app.info("update: watchdog pid=\(spawned) waits for pid=\(pid) (\(awaitInstaller ? "install" : "restart")) → \(bundleURL.path)")
        return spawned
    }

    /// `ccemaphore --relaunch-watchdog <pid> <bundlePath> <install|restart> [--dry-run]` — see
    /// `spawnRelaunchWatchdog`. `--dry-run` only reports what it would do: it never waits on a live pid
    /// and never opens anything. Returns the process exit code.
    static func runRelaunchWatchdog(_ args: [String]) -> Int32 {
        let dryRun = args.contains("--dry-run")
        let rest = Array(args.drop(while: { $0 != "--relaunch-watchdog" }).dropFirst().filter { $0 != "--dry-run" })
        guard rest.count >= 3, let pid = pid_t(rest[0]), pid > 0, rest[2] == "install" || rest[2] == "restart" else {
            FileHandle.standardError.write(Data(
                "usage: ccemaphore --relaunch-watchdog <pid> <bundlePath> <install|restart> [--dry-run]\n".utf8))
            return 2
        }
        let bundleURL = URL(fileURLWithPath: rest[1]).standardizedFileURL
        let awaitInstaller = rest[2] == "install"
        let identity = bundleIdentity(at: bundleURL)
        let exclude: Set<pid_t> = [pid, getpid()]
        let tag = dryRun ? "relaunch-watchdog (dry run)" : "relaunch-watchdog"
        func note(_ s: String) {
            Log.app.info("\(tag): \(s)")
            if dryRun { print(s) }
        }
        note("pid=\(pid) mode=\(rest[2]) bundle=\(bundleURL.path) id=\(identity.id) exe=\(identity.exe)")

        // 1. The app has to be gone first. If it never quits, nothing was installed — leave it alone.
        if dryRun {
            note(ProcTree.isAlive(pid) ? "pid \(pid) is alive — would wait up to \(Int(watchdogWaitCap))s for it to exit"
                                       : "pid \(pid) is not running")
        } else if !waitUntil(watchdogWaitCap, poll: 0.25, { !ProcTree.isAlive(pid) }) {
            note("pid \(pid) still running after \(Int(watchdogWaitCap))s awake — giving up, nothing relaunched")
            return 0
        }

        // 2. Sparkle's installer swaps the bundle after we quit, and relaunches the app itself on success.
        if awaitInstaller {
            let installers = sparkleInstallerPIDs(bundleID: identity.id, bundleURL: bundleURL)
            if dryRun {
                note("Sparkle installer processes: \(installers.isEmpty ? "none" : installers.map(String.init).joined(separator: ", "))")
            } else {
                if !installers.isEmpty { note("waiting for Sparkle installer pid(s) \(installers)") }
                // Done once the installer is gone — or as soon as the app is back (Sparkle relaunches it
                // before its installer has fully exited; nothing is left for us to do then).
                var relaunched: pid_t?
                let finished = waitUntil(watchdogWaitCap, poll: 0.5) {
                    relaunched = scanGUIInstances(bundleURL: bundleURL, identity: identity, excluding: exclude).match
                    return relaunched != nil || sparkleInstallerPIDs(bundleID: identity.id, bundleURL: bundleURL).isEmpty
                }
                if relaunched == nil {
                    if !finished { note("installer still running after \(Int(watchdogWaitCap))s awake — relaunching anyway") }
                    _ = waitUntil(relaunchGrace, poll: 0.5) {
                        relaunched = scanGUIInstances(bundleURL: bundleURL, identity: identity, excluding: exclude).match
                        return relaunched != nil
                    }
                }
                if let relaunched {
                    note("app relaunched by Sparkle (pid \(relaunched)) — nothing to do")
                    return 0
                }
            }
        }

        // 3. Reopen unless THIS bundle already runs (Sparkle's relaunch, a login item, the user). Another copy
        // with our bundle id elsewhere (an Xcode Debug build) doesn't count — Sparkle relaunches next to it too.
        let instances = scanGUIInstances(bundleURL: bundleURL, identity: identity, excluding: exclude)
        let running = instances.match
        let others = instances.others.map { "pid \($0.pid) at \($0.bundlePath)" }.joined(separator: ", ")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: bundleURL.path, isDirectory: &isDir) && isDir.boolValue
        if dryRun {
            note("running GUI instance: \(running.map { "pid \($0)" } ?? "none")")
            if !others.isEmpty { note("other copies with id \(identity.id) (not this bundle — ignored): \(others)") }
            note("bundle on disk: \(exists ? "present" : "MISSING")")
            note(running != nil ? "decision: already running — would not open"
                 : exists ? "decision: would open \(bundleURL.path)" : "decision: bundle missing — would not open")
            return 0
        }
        if let running {
            note("already running (pid \(running)) — nothing to do")
            return 0
        }
        if !others.isEmpty { note("another copy is running (\(others)) — not this bundle, reopening it anyway") }
        guard exists else {
            note("bundle missing at \(bundleURL.path) — cannot relaunch")
            return 1
        }
        let status = openBundle(bundleURL)
        note("opened \(bundleURL.path) → /usr/bin/open exit \(status)")
        return status == 0 ? 0 : 1
    }

    /// Poll `done` every `poll` seconds for up to `timeout` seconds of AWAKE time; true once it holds.
    /// `systemUptime` stops while the Mac sleeps and ignores clock changes — a wall-clock deadline would be
    /// used up by a lid closed mid-install, and the watchdog would then give up or reopen the app mid-swap.
    private static func waitUntil(_ timeout: TimeInterval, poll: TimeInterval, _ done: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if done() { return true }
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            Thread.sleep(forTimeInterval: poll)
        }
    }

    /// `/usr/bin/open <bundle>` — a separate process, so the watchdog itself never talks to
    /// LaunchServices (see the type comment). Without `-n`, LaunchServices won't start a second instance.
    private static func openBundle(_ bundleURL: URL) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [bundleURL.path]
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            Log.app.error("relaunch-watchdog: /usr/bin/open failed to start: \(error.localizedDescription)")
            return -1
        }
    }

    /// Bundle id + executable name read fresh from `<bundle>/Contents/Info.plist`, falling back to our own.
    private static func bundleIdentity(at bundleURL: URL) -> (id: String, exe: String) {
        let plist = infoPlist(ofBundle: bundleURL)
        let id = plist?["CFBundleIdentifier"] as? String ?? Bundle.main.bundleIdentifier ?? "com.hakkazuu.ccemaphore"
        let exe = plist?["CFBundleExecutable"] as? String ?? Bundle.main.executableURL?.lastPathComponent ?? "ccemaphore"
        return (id, exe)
    }

    /// `<bundle>/Contents/Info.plist` read straight from disk — never through `Bundle`, which caches its
    /// info dictionary for the life of the process (useless for seeing a bundle that was replaced).
    static func infoPlist(ofBundle bundleURL: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// GUI instances of the app found by `scanGUIInstances`.
    private struct GUIInstances {
        /// A process running THIS bundle, if any.
        var match: pid_t?
        /// Copies with our bundle id at another path (e.g. an Xcode Debug build) — reported, never counted.
        var others: [(pid: pid_t, bundlePath: String)] = []
    }

    /// GUI instances of the app — kernel-level, no LaunchServices: processes whose executable is
    /// `<some>.app/Contents/MacOS/<exe>`, started without a `--flag` (the same rule `Entry.main` uses to boot
    /// the GUI — hooks, diagnostics and this watchdog all carry one). `match` is the one running THIS bundle,
    /// by the rule Sparkle's own relaunch uses (InstallerProgressAppController `runningApplicationsWithBundle`):
    /// the resolved bundle path — or, only when nothing matches that, a translocated copy with the same bundle
    /// id and bundle name. Matching by bundle id alone would take any other copy (the developer's Debug build)
    /// for "relaunched" and leave the updated app closed after a failed install.
    private static func scanGUIInstances(bundleURL: URL, identity: (id: String, exe: String),
                                         excluding: Set<pid_t>) -> GUIInstances {
        let suffix = "/Contents/MacOS/" + identity.exe
        let wanted = bundleURL.resolvingSymlinksInPath().path
        var result = GUIInstances()
        var translocatedMatch: pid_t?
        for pid in allPIDs() where !excluding.contains(pid) {
            let path = ProcTree.execPath(pid)
            guard path.hasSuffix(suffix), let argv = processArguments(pid) else { continue }
            if argv.dropFirst().contains(where: { $0.hasPrefix("--") }) { continue }
            let app = URL(fileURLWithPath: String(path.dropLast(suffix.count)))
            let appPath = app.resolvingSymlinksInPath().path
            if appPath == wanted {
                result.match = pid
                return result
            }
            guard bundleIdentity(at: app).id == identity.id else { continue }
            if isTranslocated(app), app.lastPathComponent == bundleURL.lastPathComponent {
                translocatedMatch = translocatedMatch ?? pid
            } else {
                result.others.append((pid, appPath))
            }
        }
        result.match = translocatedMatch
        return result
    }

    /// Sparkle's installer processes for THIS app: `Autoupdate` (argv[1] = host bundle id) and the
    /// `Updater.app` progress agent (argv[1] = host bundle path), both run from a Sparkle.framework.
    ///
    /// A root-owned `Autoupdate` (after an admin prompt) has unreadable arguments, and so does any other app's
    /// root installer or another user's. Such an `Autoupdate` counts as ours only while OUR progress agent is
    /// alive: Sparkle submits that agent with every installer, always in the user's launchd domain (readable
    /// argv), and it exits when the installer's connection goes away (InstallerProgressAppController) — so it
    /// brackets our installer's lifetime. Once it's gone our install finished or failed, and a foreign
    /// unreadable `Autoupdate` (another app's pending install-on-quit) can't hold the relaunch back for the
    /// whole `watchdogWaitCap`.
    static func sparkleInstallerPIDs(bundleID: String, bundleURL: URL) -> [pid_t] {
        let me = getpid()
        let wantedPath = bundleURL.resolvingSymlinksInPath().path
        var ours: [pid_t] = []
        var unreadableAutoupdates: [pid_t] = []
        var ourAgentAlive = false
        for pid in allPIDs() where pid != me {
            let path = ProcTree.execPath(pid)
            let name = path.isEmpty ? processName(pid) : (path as NSString).lastPathComponent
            let inSparkle = path.isEmpty || path.contains("/Sparkle.framework/")
            let isAutoupdate = name == "Autoupdate" && inSparkle
            let isProgressAgent = name == "Updater" && path.hasSuffix("/Updater.app/Contents/MacOS/Updater") && inSparkle
            guard isAutoupdate || isProgressAgent else { continue }
            if let argv = processArguments(pid), argv.count > 1 {
                let target = argv[1]
                let matches = isAutoupdate
                    ? target == bundleID
                    : URL(fileURLWithPath: target).resolvingSymlinksInPath().path == wantedPath
                guard matches else { continue }
                if isProgressAgent { ourAgentAlive = true }
                ours.append(pid)
            } else if isAutoupdate {
                unreadableAutoupdates.append(pid)
            }
        }
        return ourAgentAlive ? ours + unreadableAutoupdates : ours
    }

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return [] }
        return pids.prefix(Int(n)).filter { $0 > 0 }
    }

    private static func processName(_ pid: pid_t) -> String {
        var buf = [UInt8](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// argv of `pid` via `KERN_PROCARGS2` (layout: argc, exec path, NUL padding, argv…). nil for
    /// processes we may not read (another user's, root's) or that are gone.
    private static func processArguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }   // exec path
        while i < size, buf[i] == 0 { i += 1 }   // padding
        var argv: [String] = []
        while argv.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            argv.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return argv
    }

    // MARK: - `--update-status`

    /// Everything that decides whether (and how) this copy updates itself — no network, no Sparkle.
    ///
    /// CI CONTRACT: `Scripts/release/smoke-test.sh` runs the SIGNED release binary with `--update-status`,
    /// finds the launch gate row printed below (two-space indent, label padded to 32), reads the first word
    /// after the label — the gate's case name, which `describe` puts first — and fails the release unless it
    /// is `enabled`. Since only a Developer ID build in CI can run that check, `Scripts/release/selftest.sh`
    /// checks this file instead: an anchored grep for the code line that prints the row (a mention in a
    /// comment doesn't count) and one for `describe`'s `.enabled` text starting with `enabled`. Rewording the
    /// label, the row format or `describe`'s leading case names breaks the release after approval and signing
    /// — change them only together with those scripts. The rest of this output is free-form developer text
    /// (English, not localized).
    static func printStatus() {
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]
        let defaults = UserDefaults.standard
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        func row(_ label: String, _ value: String) {
            print("  " + label.padding(toLength: 32, withPad: " ", startingAt: 0) + value)
        }
        func plistBool(_ key: String) -> String {
            guard let v = info[key] else { return "<missing>" }
            return (v as? Bool).map { $0 ? "YES" : "NO" } ?? "\(v)"
        }

        print("ccemaphore — in-app updater status (local checks only, no network)")
        print("")
        row("version", "\(short) (build \(build))")
        row("bundle", bundle.bundlePath)
        #if DEBUG
        row("build configuration", "Debug — the updater never starts in Debug builds")
        #else
        row("build configuration", "Release")
        #endif
        let sig = developerIDCheck()
        let team = signingTeamID().map { "  (team \($0))" } ?? ""
        let why: String
        switch sig {
        case errSecCSUnsigned: why = "not signed"
        case errSecCSReqFailed: why = "signed, but not with a Developer ID certificate (ad-hoc / Apple Development)"
        case errSecCSSignatureFailed, errSecCSSignatureInvalid: why = "signature invalid (bundle modified after signing?)"
        default: why = "check failed"
        }
        row("Developer ID signature", (sig == errSecSuccess ? "yes" : "no — \(why) (OSStatus \(sig))") + team)
        row("read-only volume", isOnReadOnlyVolume(bundle.bundleURL) ? "YES (mounted DMG?)" : "no")
        row("translocated", isTranslocated(bundle.bundleURL) ? "YES" : "no")
        if let original = originalURL(forTranslocated: bundle.bundleURL) { row("original location", original.path) }
        row("install needs admin password", installNeedsAuthorization(bundle.bundleURL)
            ? "YES — bundle or its folder not writable, or owned by another user (the GUI blocks while macOS asks)"
            : "no")
        // CI CONTRACT (smoke-test.sh greps this line — see printStatus): keep the label and `describe`'s
        // leading case name as they are.
        row("launch gate", describe(launchGate()))

        print("")
        print("Info.plist")
        row("SUFeedURL", info["SUFeedURL"] as? String ?? "<missing>")
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        row("SUPublicEDKey", publicKeyIsPlaceholder(info)
            ? (key.isEmpty ? "<missing>" : "PLACEHOLDER — updates cannot be verified (misconfigured)")
            : "present (\(key.count) chars)")
        row("SURequireSignedFeed", plistBool("SURequireSignedFeed"))
        row("SUVerifyUpdateBeforeExtraction", plistBool("SUVerifyUpdateBeforeExtraction"))
        for extra in ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUScheduledCheckInterval", "SUAllowsAutomaticUpdates"]
        where info[extra] != nil {
            row(extra, "\(info[extra]!)  (Info.plist should not set this — the consent row owns it)")
        }

        print("")
        print("User defaults (\(bundle.bundleIdentifier ?? "?"))")
        func value(_ k: String) -> String {
            guard let v = defaults.object(forKey: k) else { return "—" }
            if let d = v as? Date { return d.formatted(.iso8601) }
            if let dict = v as? [String: Any] {
                return dict.keys.sorted().map { "\($0)=\(dict[$0].map { "\($0)" } ?? "")" }.joined(separator: " ")
            }
            return "\(v)"
        }
        let ownKeys = [DefaultsKey.mode, DefaultsKey.pendingVersion, DefaultsKey.pendingBuild,
                       DefaultsKey.installMarker, DefaultsKey.lastRunBuild]
        for k in ownKeys { row(k, value(k)) }
        let modeNote = defaults.string(forKey: DefaultsKey.mode) == nil ? "  (no consent yet → first launch shows the consent row)" : ""
        if !modeNote.isEmpty { print(modeNote) }
        let others = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("update.") && !ownKeys.contains($0) }.sorted()
        for k in others { row(k, value(k)) }
        for k in ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SULastCheckTime", "SUSkippedVersion",
                  "SUSkippedMajorVersion", "SUScheduledCheckInterval", "SUHasLaunchedBefore", "SUSendProfileInfo"] {
            row(k, value(k))
        }
        if let override = defaults.string(forKey: "SUFeedURL") {
            print("")
            print("  !!! SUFeedURL is OVERRIDDEN in user defaults → \(override)")
            print("  !!! This copy checks THAT feed, not Info.plist's. Remove after testing:")
            print("  !!!   defaults delete \(bundle.bundleIdentifier ?? "com.hakkazuu.ccemaphore") SUFeedURL")
        }
    }

    /// Each value starts with the case name. CI CONTRACT: the release smoke test reads that first word from
    /// the `launch gate` row and requires `enabled` (see `printStatus`); keep the case names first.
    private static func describe(_ a: UpdateAvailability) -> String {
        switch a {
        case .enabled: return "enabled — Sparkle starts; automatic checks follow update.mode"
        case .debugBuild: return "debugBuild — never self-updates"
        case .notDeveloperIDSigned: return "notDeveloperIDSigned — local build, never swapped for the release"
        case .needsMoveToApplications: return "needsMoveToApplications — move the app out of the DMG / Downloads"
        case .misconfigured(let detail): return "misconfigured — \(detail)"
        }
    }
}
