import SwiftUI

/// Process entry point. Routes `--scan` to the headless diagnostic; otherwise launches the menu-bar
/// app. Must NOT live in a file named main.swift (the @main attribute collides with synthesized
/// top-level code under SwiftPM).
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments

        // Hook invocation: `ccemaphore --hook <event>` — read stdin, write status, exit (no GUI).
        if let i = args.firstIndex(of: "--hook"), i + 1 < args.count {
            let event = args[i + 1]
            switch event {
            // Blocking permission broker. `permission-request` (PermissionRequest) is the precise path;
            // `permission` (PreToolUse) is kept for already-installed legacy configs.
            case "permission-request": PermissionBroker.runHook(event: .permissionRequest)
            case "permission":         PermissionBroker.runHook(event: .preToolUse)
            default:                   HookHandler.run(event)
            }
            return
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
        if args.contains("--check-perm") {
            Diagnostic.checkPermission()
            return
        }
        if args.contains("--perm-diag") {
            Diagnostic.permDiag()
            return
        }
        if args.contains("--install-hooks") {
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
        if args.contains("--trusted-dump") {
            TrustedCommands.dump()
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

    private static func printUsage() {
        print("""
        ccemaphore — menu-bar traffic light for Claude Code sessions.

        Usage:
          ccemaphore                 Launch the menu-bar app (default; no Dock icon).
          ccemaphore --help, -h      Show this help.

        Diagnostics:
          ccemaphore --scan          One-shot classification pass over ~/.claude/projects, then exit.
          ccemaphore --probe <file>  Dump the heuristic's per-stage result for one .jsonl transcript.
          ccemaphore --check-perm    Read a PreToolUse JSON payload from stdin; print whether the
                                     permission broker would skip it (Claude auto-resolves → no banner).
          ccemaphore --perm-diag     Print the raw payload last captured for each permission hook event
                                     (PreToolUse / PermissionRequest) — confirms the event fires + shape.
          ccemaphore --status-dump   Print the current mode-B hook status files.
          ccemaphore --presence-dump Print the GUI presence beacon + the permission hook's readiness verdict.
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

        Internal (invoked by Claude Code, not by hand):
          ccemaphore --hook <event>         Handle a hook event from stdin.
        """)
    }
}

/// The menu-bar item is now minimal (§11): it keeps the colored status glyph, but clicking it offers
/// only "show the light" + "quit" — every other surface moved into the floating widget. The widget
/// itself (and the history window) is managed in AppKit (`FloatingWidgetController`).
struct CcemaphoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = StateEngine.shared
    @ObservedObject private var settings = WidgetSettings.shared
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some Scene {
        MenuBarExtra {
            Toggle(isOn: $settings.visible) { Text(L("menubar.showLight")) }
            Divider()
            Button(L("menu.quit")) { NSApplication.shared.terminate(nil) }
        } label: {
            // Emoji keeps its color in the menu bar (SF Symbols render as monochrome templates),
            // and the distinct glyphs double as the non-color accessibility cue.
            Text(engine.menuBarText)
        }
        .menuBarExtraStyle(.menu)
    }
}
