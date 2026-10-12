import SwiftUI

/// Process entry point. Routes `--scan` to the headless diagnostic; otherwise launches the menu-bar
/// app. Must NOT live in a file named main.swift (the @main attribute collides with synthesized
/// top-level code under SwiftPM).
@main
enum Entry {
    static func main() {
        // Writing to an ssh stdin whose reader has already closed (a host that dropped mid-write) delivers
        // SIGPIPE, which by default kills the whole process — and RemoteExec.writeFile is reached from
        // ordinary user actions (remote Allow/Deny relay, "Install hooks"). Ignore it process-wide so the
        // failed write surfaces as a catchable EPIPE instead of a crash. Set here because Entry.main is the
        // single entry for BOTH the GUI and every headless --remote-* CLI path.
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments

        // Hook invocation: `ccemaphore --hook <event>` — read stdin, write status, exit (no GUI).
        if let i = args.firstIndex(of: "--hook"), i + 1 < args.count {
            let event = args[i + 1]
            // `--agent codex` marks a Codex hook (appended by `CodexHooksInstaller`); absent ⇒ Claude Code.
            let agent = args.firstIndex(of: "--agent").flatMap { j in
                j + 1 < args.count ? AgentKind(rawValue: args[j + 1]) : nil
            } ?? .claude
            switch event {
            // Blocking permission broker. `permission-request` (PermissionRequest) is the precise path;
            // `permission` (PreToolUse) is kept for already-installed legacy configs.
            case "permission-request": PermissionBroker.runHook(event: .permissionRequest, agent: agent)
            case "permission":         PermissionBroker.runHook(event: .preToolUse, agent: agent)
            default:                   HookHandler.run(event, agent: agent)
            }
            return
        }
        // Relaunch watchdog, spawned detached by the updater right before the app quits to install or
        // restart (`UpdateSupport.spawnRelaunchWatchdog`). Headless: never touches AppKit/LaunchServices.
        if args.contains("--relaunch-watchdog") {
            exit(UpdateSupport.runRelaunchWatchdog(args))
        }
        if args.contains("--help") || args.contains("-h") {
            printUsage()
            return
        }
        if args.contains("--scan") {
            // Drive the async diagnostic to completion, then exit — no semaphore bridge needed.
            Task { await Diagnostic.run(); exit(0) }
            dispatchMain()
        }
        if let i = args.firstIndex(of: "--probe"), i + 1 < args.count {
            Diagnostic.probe(args[i + 1])
            return
        }
        if args.contains("--registry-dump") {
            SessionRegistryReader.dump()
            return
        }
        if args.contains("--groups-dump") {
            ProductGroups.dump()
            return
        }
        if args.contains("--usage-dump") {
            Task { await Diagnostic.usageDump(); exit(0) }
            dispatchMain()
        }
        if args.contains("--codex-scan") {
            Task { await CodexDiagnostic.scan(); exit(0) }
            dispatchMain()
        }
        if let i = args.firstIndex(of: "--codex-probe"), i + 1 < args.count {
            CodexDiagnostic.probe(args[i + 1])
            return
        }
        if args.contains("--codex-db-probe") {
            CodexDiagnostic.dbProbe()
            return
        }
        if args.contains("--check-perm") {
            Diagnostic.checkPermission()
            return
        }
        if args.contains("--perm-diag") {
            Diagnostic.permDiag()
            return
        }
        if args.contains("--install-hooks") {
            refuseHookInstallFromTransientLocation("--install-hooks")
            do { try HooksInstaller.install(); print("hooks installed → \(HooksInstaller.settingsPath)") }
            catch { print("install failed: \(error.localizedDescription)") }
            return
        }
        if args.contains("--uninstall-hooks") {
            do { try HooksInstaller.uninstall(); print("hooks removed → \(HooksInstaller.settingsPath)") }
            catch { print("uninstall failed: \(error.localizedDescription)") }
            return
        }
        if args.contains("--hooks-status") {
            print("installed: \(HooksInstaller.isInstalled())  (\(HooksInstaller.settingsPath))")
            return
        }
        if args.contains("--install-codex-hooks") {
            refuseHookInstallFromTransientLocation("--install-codex-hooks")
            do { try CodexHooksInstaller.install(); print("codex hooks installed → \(CodexHooksInstaller.hooksPath)") }
            catch { print("install failed: \(error.localizedDescription)") }
            print("trust: \(CodexHooksInstaller.trustState())")
            return
        }
        if args.contains("--uninstall-codex-hooks") {
            do { try CodexHooksInstaller.uninstall(); print("codex hooks removed → \(CodexHooksInstaller.hooksPath)") }
            catch { print("uninstall failed: \(error.localizedDescription)") }
            return
        }
        if args.contains("--codex-hooks-status") {
            print("installed: \(CodexHooksInstaller.isInstalled())  permission: \(CodexHooksInstaller.isPermissionHookInstalled())  "
                  + "trust: \(CodexHooksInstaller.trustState())  (\(CodexHooksInstaller.hooksPath))")
            return
        }
        if args.contains("--ax-dump") {
            FocusResolver.axDump()
            return
        }
        if args.contains("--l10n-check") {
            Diagnostic.l10nCheck()
            return
        }
        if args.contains("--presence-dump") {
            AppPresence.dump()
            return
        }
        if args.contains("--update-status") {
            UpdateSupport.printStatus()
            return
        }
        if args.contains("--trusted-dump") {
            TrustedCommands.dump()
            return
        }
        if args.contains("--remote-hosts-dump") {
            RemoteHosts.dump()
            return
        }
        if let i = args.firstIndex(of: "--remote-ping"), i + 1 < args.count {
            guard let host = RemoteHosts.resolve(args[i + 1]) else { print("no such remote host: \(args[i + 1])"); return }
            switch RemoteExec.testConnection(host) {
            case .success(let platform): print("\(host.label) (\(host.hostname)): reachable, platform=\(platform)")
            case .failure(let e): print("\(host.label) (\(host.hostname)): FAILED — \(e.message)")
            }
            return
        }
        if let i = args.firstIndex(of: "--remote-scan"), i + 1 < args.count {
            guard let host = RemoteHosts.resolve(args[i + 1]) else { print("no such remote host: \(args[i + 1])"); return }
            Task { @MainActor in
                // A throwaway instance (pollOnce is now an instance method holding the F1 parse cache — a
                // one-shot scan gets no cache benefit, which is fine for the diagnostic).
                let poller = RemoteTranscriptPoller()
                switch await poller.pollOnce(host: host) {
                case .success(let result):
                    // Mode-A sessions (state here is the transcript-only dot; the app merges the status
                    // rows below in render() — printed separately so the diagnostic shows both layers).
                    let now = Date()
                    for s in result.sessions {
                        let ageSec = Int(now.timeIntervalSince(s.lastActivity))
                        print("\(s.dot) \(s.project)  \(s.gitBranch ?? "")  age=\(ageSec)s  lastActivity=\(s.lastActivity)  id=\(s.id)")
                    }
                    if result.sessions.isEmpty { print("(no sessions found)") }
                    for (id, st) in result.statuses.sorted(by: { $0.key < $1.key }) {
                        print("  status \(st.state.rawValue)/\(st.lastEvent ?? "?")  id=\(id)")
                    }
                case .failure(let e): print("scan failed: \(e.message)")
                }
                exit(0)
            }
            dispatchMain()
        }
        if let i = args.firstIndex(of: "--remote-status-dump"), i + 1 < args.count {
            guard let host = RemoteHosts.resolve(args[i + 1]) else { print("no such remote host: \(args[i + 1])"); return }
            do {
                let names = try RemoteExec.listGlob(host, glob: "~/.claude/status/*.json")
                for name in names {
                    guard let data = try RemoteExec.readFile(host, path: name), let e = StatusReader.parse(data: data) else { continue }
                    print("\(e.state.rawValue)  \(e.project)  id=\(e.id.prefix(8))  event=\(e.lastEvent ?? "?")")
                }
                if names.isEmpty { print("(no status files)") }
            } catch { print("status dump failed: \(error.localizedDescription)") }
            return
        }
        if let i = args.firstIndex(of: "--remote-hooks-status"), i + 1 < args.count {
            guard let host = RemoteHosts.resolve(args[i + 1]) else { print("no such remote host: \(args[i + 1])"); return }
            print("installed: \(RemoteHooksInstaller.isInstalled(host))  (\(host.label) — \(RemoteHooksInstaller.remoteSettingsPath))")
            return
        }
        if let i = args.firstIndex(of: "--remote-install-hooks"), i + 1 < args.count {
            guard let host = RemoteHosts.resolve(args[i + 1]) else { print("no such remote host: \(args[i + 1])"); return }
            do { try RemoteHooksInstaller.install(host); print("remote hooks installed on \(host.label)") }
            catch { print("install failed: \(error.localizedDescription)") }
            return
        }
        if let i = args.firstIndex(of: "--remote-uninstall-hooks"), i + 1 < args.count {
            guard let host = RemoteHosts.resolve(args[i + 1]) else { print("no such remote host: \(args[i + 1])"); return }
            do { try RemoteHooksInstaller.uninstall(host); print("remote hooks removed from \(host.label)") }
            catch { print("uninstall failed: \(error.localizedDescription)") }
            return
        }
        if let i = args.firstIndex(of: "--ide-log-probe") {
            IDELogWatcher.probe(i + 1 < args.count ? args[i + 1] : nil)
            return
        }
        if args.contains("--logs-path") {
            Log.cliPath()
            return
        }
        if args.contains("--logs-tail") {
            Log.cliTail()
            return
        }
        if args.contains("--status-dump") {
            let now = Date()
            for (id, e) in StatusReader.readAll().sorted(by: { $0.value.updatedAt > $1.value.updatedAt }) {
                let label = e.isCompacting ? "compact" : e.state.rawValue
                let pid = e.ownerPid.map { "  pid=\($0)(\(ProcTree.isAlive($0) ? "alive" : "DEAD"))" } ?? ""
                let host = e.host == .unknown ? "" : "  host=\(e.host.rawValue)\(e.hostBundleId.map { "(\($0))" } ?? "")"
                print("\(label.padding(toLength: 7, withPad: " ", startingAt: 0)) "
                      + "\(e.project)  age=\(Int(now.timeIntervalSince(e.updatedAt)))s  id=\(id.prefix(8))\(pid)\(host)")
            }
            return
        }
        // A typo'd ccemaphore flag (ours are all `--…`) → say so. But IGNORE single-dash system /
        // Cocoa arguments (e.g. `-NSDocumentRevisionsDebugMode YES` that Xcode injects when it
        // launches the app for debugging) and just boot the GUI.
        if let bad = args.dropFirst().first(where: { $0.hasPrefix("--") }) {
            FileHandle.standardError.write(Data("ccemaphore: unknown option '\(bad)'\n".utf8))
            printUsage()
            exit(2)
        }
        CcemaphoreApp.main()
    }

    /// The same rule the GUI applies (`StateEngine.refuseHookInstallFromTransientLocation`): installing from
    /// the mounted DMG or an App Translocation copy would bake a path into settings.json / hooks.json that
    /// vanishes once the DMG is ejected, and every hook would then fail (exit 127). Exits 1 in that case.
    private static func refuseHookInstallFromTransientLocation(_ flag: String) {
        guard UpdateSupport.isTransientLocation() else { return }
        FileHandle.standardError.write(Data("""
            ccemaphore: \(flag) refused — this copy runs from a transient location (\(Bundle.main.bundlePath)):
            the mounted disk image or an App Translocation copy. The hook command would point at a path that
            disappears once the disk image is ejected, and every hook would then fail.
            Move ccemaphore.app to /Applications, open it once from there, and run this again.

            """.utf8))
        exit(1)
    }

    private static func printUsage() {
        print("""
        ccemaphore — menu-bar traffic light for Claude Code sessions.

        Usage:
          ccemaphore                 Launch the menu-bar app (default; no Dock icon).
          ccemaphore --help, -h      Show this help.

        Diagnostics:
          ccemaphore --scan          One-shot classification pass over ~/.claude/projects, then exit.
          ccemaphore --probe <file>  Dump the heuristic's per-stage result for one .jsonl transcript.
          ccemaphore --registry-dump Print Claude Code's live session registry (~/.claude/sessions).
          ccemaphore --groups-dump   Print the product groups (manual + Codex projects).
          ccemaphore --usage-dump    Run ccusage once; print per-day totals with the Claude/Codex split.
          ccemaphore --codex-scan    One-shot pass over Codex's ~/.codex (catalog + rollouts), then exit.
          ccemaphore --codex-probe <rollout.jsonl>
                                     Per-stage result for one Codex rollout transcript.
          ccemaphore --check-perm    Read a PreToolUse JSON payload from stdin; print whether the
                                     permission broker would skip it (Claude auto-resolves → no banner).
          ccemaphore --perm-diag     Print the raw payload last captured for each permission hook event
                                     (PreToolUse / PermissionRequest) — confirms the event fires + shape.
          ccemaphore --status-dump   Print the current mode-B hook status files.
          ccemaphore --presence-dump Print the GUI presence beacon + the permission hook's readiness verdict.
          ccemaphore --update-status Print the in-app updater's gates, Info.plist keys and saved state
                                     (signature, location, feed, mode, last check) — no network.
          ccemaphore --trusted-dump  Print the user's trusted-command auto-allow list (trusted.json).
          ccemaphore --ide-log-probe [toolUseId]
                                     List the Cursor/VS Code extension logs the IDE-log watcher would
                                     scan; with a toolUseId, report whether its dispatch marker is present.
          ccemaphore --ax-dump       Probe the frontmost Cursor window's Accessibility tree.
          ccemaphore --l10n-check    Print localized samples for every language (verify localization).
          ccemaphore --logs-path     Print the log directory (~/Library/Logs/ccemaphore).
          ccemaphore --logs-tail     Print the tail of today's log file.

        Hooks (edit ~/.claude/settings.json — usually done from the in-app menu):
          ccemaphore --install-hooks        Install the status/notification hooks.
          ccemaphore --uninstall-hooks      Remove everything ccemaphore added.
          ccemaphore --hooks-status         Report whether the hooks are installed.

        Codex hooks (edit ~/.codex/hooks.json; Codex must then TRUST the file — review it in the
        ChatGPT app's Codex settings or with /hooks in the Codex CLI):
          ccemaphore --install-codex-hooks     Install the Codex status + permission hooks.
          ccemaphore --uninstall-codex-hooks   Remove everything ccemaphore added to hooks.json.
          ccemaphore --codex-hooks-status      Report install + trust state.
          ccemaphore --codex-db-probe          Low-level SQLite open/prepare probe of the Codex catalog.

        Remote hosts (SSH — configured from the in-app "Remote Hosts" section; <host> is an id or label):
          ccemaphore --remote-hosts-dump           Print the configured remote host list.
          ccemaphore --remote-ping <host>          Test connectivity + detect platform (uname -s).
          ccemaphore --remote-scan <host>          One-shot session scan over SSH, then exit.
          ccemaphore --remote-status-dump <host>   Print the host's mode-B hook status files.
          ccemaphore --remote-hooks-status <host>  Report whether remote hooks are installed.
          ccemaphore --remote-install-hooks <host>    Deploy the hook shim + install remote hooks.
          ccemaphore --remote-uninstall-hooks <host>  Remove everything ccemaphore added remotely.

        Internal (invoked by Claude Code / Codex / the app itself, not by hand):
          ccemaphore --hook <event> [--agent codex]   Handle a hook event from stdin.
          ccemaphore --relaunch-watchdog <pid> <bundle> <install|restart> [--dry-run]
                                     Wait for the app (and Sparkle's installer) to finish, then reopen
                                     the app if nothing relaunched it. --dry-run only reports.
        """)
    }
}

/// The menu-bar item (v3, `StatusItemController` — a manual `NSStatusItem`, not SwiftUI's
/// `MenuBarExtra`): right-click PINS the management panel open, left-click shows "show the light" +
/// "open panel" + "quit" — every other surface lives in the floating widget. No SwiftUI `Scene` is
/// needed for the status item itself; `Settings {}` is a required-but-invisible placeholder scene so
/// this stays a valid SwiftUI `App` with zero windows of its own (the floating widget / history window
/// are both managed directly in AppKit via `FloatingWidgetController`/`HistoryWindowController`).
struct CcemaphoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {}
    }
}
