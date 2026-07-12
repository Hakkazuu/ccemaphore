import AppKit

/// Jumps the user to a session's Cursor window and chat tab (verified against the installed
/// Anthropic.claude-code extension; see memory cursor-deeplink):
///   1. `cursor <cwd>`  → focuses the existing window for that project, or opens one if none.
///   2. `cursor://Anthropic.claude-code/open?session=<uuid>` → reveals that exact chat tab
///      (or resumes the session if its tab isn't open).
/// Best-effort: both depend on Cursor + the extension being present; failures are silent.
///
/// NOTE: we deliberately do NOT pass `-r`/`--reuse-window`. That flag does not "focus the window
/// that already has this folder" — it force-loads the folder into whatever Cursor window is
/// currently frontmost, evicting whatever the user had open there. That destroyed a user's other
/// project once (they were mid-prompt in another window when a permission jump fired). Plain
/// `cursor <folder>` focuses the folder's existing window and never hijacks the active one.
enum DeepLinker {
    /// Cursor's install location, resolved through LaunchServices by asking who handles the `cursor://`
    /// scheme — NOT a hardcoded /Applications path, so a ~/Applications or Setapp install still counts
    /// (and the handler is, by definition, the app `NSWorkspace.open(cursor://…)` would launch, which is
    /// exactly the identity the deep-link gate below needs). Canonical-path fallback for the edge where
    /// the scheme isn't registered but the app exists. nil ⇒ Cursor isn't installed.
    private static let cursorAppURL: URL? = {
        if let probe = URL(string: "cursor://"),
           let app = NSWorkspace.shared.urlForApplication(toOpen: probe) { return app }
        let canonical = URL(fileURLWithPath: "/Applications/Cursor.app")
        return FileManager.default.fileExists(atPath: canonical.path) ? canonical : nil
    }()
    /// Cursor's bundle id (an opaque todesktop id, `com.todesktop.…` — never hardcode it). Compared
    /// against a session's `hostBundleId`: ONLY a confirmed-Cursor chat takes the `cursor://` deep-link.
    private static let cursorBundleId: String? = cursorAppURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
    static var cursorBin: String {
        cursorAppURL?.appendingPathComponent("Contents/Resources/app/bin/cursor").path
            ?? "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
    }

    /// VS Code's install location, resolved the same way as `cursorAppURL` (via the `vscode://` scheme
    /// handler, falling back to the canonical /Applications path). Used only by `focusRemote` — VS Code
    /// isn't otherwise a first-class host in this file the way Cursor is.
    private static let vscodeAppURL: URL? = {
        if let probe = URL(string: "vscode://"),
           let app = NSWorkspace.shared.urlForApplication(toOpen: probe) { return app }
        let canonical = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        return FileManager.default.fileExists(atPath: canonical.path) ? canonical : nil
    }()
    private static var vscodeBin: String? {
        guard let app = vscodeAppURL else { return nil }
        let path = app.appendingPathComponent("Contents/Resources/app/bin/code").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
    private static let vscodeBundleId: String? = vscodeAppURL.flatMap { Bundle(url: $0)?.bundleIdentifier }

    static func focus(_ session: SessionInfo) {
        focus(sessionId: session.id, cwd: session.cwd, host: session.host, hostBundleId: session.hostBundleId,
              remoteHostId: session.remoteHostId)
    }

    /// Jump to a chat given only its id (+ cwd + host) — the ribbon's "open chat" path. Best-effort, and
    /// leaves a metadata-only breadcrumb (session-id prefix + which step resolved) so a "clicking the chat
    /// does nothing" report is diagnosable from ~/Library/Logs/ccemaphore.
    ///
    /// Host-aware, with one hard rule: the `cursor://…open?session=` deep-link RESUMES the session in a
    /// second client when its tab isn't open in Cursor — for any chat that does NOT live in Cursor
    /// (terminal, ssh, another editor, an editor's integrated terminal) that's a forked conversation,
    /// worse than doing nothing. So only a CONFIRMED-Cursor `.ide` chat gets it (its recorded host app
    /// is the very app that handles `cursor://`):
    ///  - `.terminal`                  → raise the terminal app (no per-tab handle exists);
    ///  - `.ide`, Cursor bundle        → the full path: focus the project window + open the chat tab;
    ///  - `.ide`, other KNOWN bundle   → raise that editor (its deep-link scheme is unverified — never
    ///                                   guess one, and never open the WRONG editor);
    ///  - `.ide`, bundle unknown       → window focus only. An older status file, or a bundle-less
    ///                                   `.ide` tree (`.vscode-server` remotes) — unconfirmed hosts
    ///                                   must not get the resume-capable tab link;
    ///  - `.unknown`                   → window focus only, same reasoning. Hooks-off Cursor users
    ///                                   still land on the right window; a CLI/ssh session can no
    ///                                   longer be forked into a second client.
    static func focus(sessionId: String, cwd: String?,
                      host: SessionHost = .unknown, hostBundleId: String? = nil,
                      remoteHostId: String? = nil) {
        let sid = sessionId.prefix(8)
        if let remoteHostId {
            focusRemote(remoteHostId: remoteHostId, cwd: cwd, sid: sid)
            return
        }
        switch host {
        case .terminal:
            activateHostApp(bundleId: hostBundleId, sid: sid, kind: "terminal")
        case .ide where hostBundleId != nil && hostBundleId == cursorBundleId:
            focusCursor(sessionId: sessionId, cwd: cwd, sid: sid, host: host, openChatTab: true)
        case .ide where hostBundleId != nil:
            activateHostApp(bundleId: hostBundleId, sid: sid, kind: "ide")
        case .ide, .unknown:
            focusCursor(sessionId: sessionId, cwd: cwd, sid: sid, host: host, openChatTab: false)
        }
    }

    /// A remote session (see `SessionInfo.remoteHostId`): the local Cursor CLI / Accessibility machinery
    /// above is entirely local-app-only and has no reach into a chat running on another machine. What DOES
    /// work when the user connects via VS Code's Remote-SSH extension (the setup this app assumes remote
    /// hosts run under — see `RemoteHooksInstaller`'s doc comment) is VS Code's own deep-link scheme:
    /// `vscode://vscode-remote/ssh-remote+<host>/<absolutePath>` asks the LOCAL VS Code app to open (or
    /// focus, if already open) a Remote-SSH window onto that folder.
    ///
    /// Deliberately WINDOW-ONLY, same caution as an unconfirmed local IDE (see `focus`'s doc comment):
    /// there is no verified `vscode://Anthropic.claude-code/open?session=…` tab-level deep-link the way
    /// Cursor's is confirmed, so guessing one risks the same "resume in a second client" fork this file
    /// otherwise goes out of its way to avoid. Opening the right PROJECT window is still most of the value
    /// (the user lands in the right VS Code window and picks the chat from its own session list) without
    /// that risk. Best-effort and silent on failure, like every other path here — a stray remote host with
    /// no local VS Code / no matching SSH config entry just doesn't jump, it never errors visibly.
    private static func focusRemote(remoteHostId: String, cwd: String?, sid: Substring) {
        guard let host = RemoteHosts.resolve(remoteHostId) else {
            Log.focus.info("jump sid=\(sid): remote host \(remoteHostId.prefix(8)) no longer configured — skip")
            return
        }
        guard let cwd, !cwd.isEmpty else {
            Log.focus.info("jump sid=\(sid) host=remote(\(host.label)): no cwd recorded — skip")
            return
        }
        // VS Code resolves this the same way ssh does: an `~/.ssh/config` Host alias when the host is
        // configured that way, otherwise `user@hostname` (falling back to bare hostname with no user).
        let authority: String
        if host.useSSHConfigOnly {
            authority = host.hostname
        } else if let user = host.sshUser, !user.isEmpty {
            authority = "\(user)@\(host.hostname)"
        } else {
            authority = host.hostname
        }
        let authorityPart = "ssh-remote+\(authority)"

        // FIRST choice: raise an already-open window directly via Accessibility, matching the host in its
        // title — VS Code titles a Remote-SSH window "… [SSH: <host>]". Neither the `code` CLI's
        // `--folder-uri` NOR the `vscode://vscode-remote/...` URI were found to reuse an existing window
        // for an already-open remote folder (both were confirmed live to always spawn a fresh one), so
        // this AX-based match is the only path that avoids window-duplication for a remote jump.
        if let bundleId = vscodeBundleId, FocusResolver.accessibilityGranted {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
                let pid = app.processIdentifier
                for (window, title) in FocusResolver.windowTitles(pid: pid)
                where title.localizedCaseInsensitiveContains(host.hostname)
                    || (host.sshUser.map { title.localizedCaseInsensitiveContains($0) } ?? false) {
                    FocusResolver.raiseWindow(window, appPid: pid)
                    Log.focus.info("jump sid=\(sid) host=remote(\(host.label)) via=ax-window-match ok")
                    return
                }
            }
        }

        // Fall back to the `code` CLI (spawns a fresh window if none matched above, or if Accessibility
        // isn't granted / VS Code isn't running yet to search).
        if let bin = vscodeBin {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["--folder-uri", "vscode-remote://\(authorityPart)\(cwd)"]
            do {
                try p.run()
                Log.focus.info("jump sid=\(sid) host=remote(\(host.label)) via=code-cli ok")
                return
            } catch {
                Log.focus.warn("jump sid=\(sid) host=remote(\(host.label)): code CLI launch failed "
                    + "(\(error.localizedDescription)) — falling back to vscode:// URI")
            }
        }

        var comps = URLComponents()
        comps.scheme = "vscode"
        comps.host = "vscode-remote"
        comps.path = "/\(authorityPart)\(cwd)"
        guard let url = comps.url else {
            Log.focus.warn("jump sid=\(sid): could not build the vscode-remote deep-link URL")
            return
        }
        let ok = NSWorkspace.shared.open(url)
        Log.focus.info("jump sid=\(sid) host=remote(\(host.label)) via=uri-fallback deeplink=\(ok ? "ok" : "FAILED")")
    }

    /// The Cursor path: focus the project's window via the CLI, then (for a confirmed-Cursor chat) reveal
    /// the exact chat tab via the extension's `cursor://` handler. `openChatTab: false` is the `.unknown`
    /// host's safety cut — window focus only, since the tab deep-link can resume/fork a session that
    /// isn't actually open in Cursor (see `focus`).
    ///
    /// The deep-link is DEFERRED behind the CLI focus, never fired in the same beat. Cursor routes an
    /// incoming `cursor://` URI to the extension host of its focused/last-active window — the URI itself
    /// carries no project. Fired immediately, it races the (slow, Space-switching) CLI focus and lands in
    /// whatever Cursor window was front before, whose claude-code extension then "resumes" a session that
    /// isn't in that workspace → a stray empty chat in the wrong project (seen live 2026-07-03).
    private static func focusCursor(sessionId: String, cwd: String?, sid: Substring,
                                    host: SessionHost, openChatTab: Bool) {
        let fm = FileManager.default
        var focusedWindow = false
        var localCwd: String?
        // The cwd must exist locally: an ssh session's remote path would otherwise make the CLI spawn a
        // bogus window for a folder this Mac doesn't have.
        if let cwd, !cwd.isEmpty, fm.fileExists(atPath: cwd) {
            if fm.isExecutableFile(atPath: cursorBin) {
                run(cursorBin, [cwd], sid: sid)
                focusedWindow = true
                localCwd = cwd
            } else {
                Log.focus.warn("jump sid=\(sid): Cursor CLI not executable at \(cursorBin) — window focus skipped")
            }
        }
        guard openChatTab else {
            Log.focus.info("jump sid=\(sid) host=\(host.rawValue) window=\(focusedWindow) "
                + "deeplink=skipped (host not confirmed Cursor — a tab deep-link could fork the session)")
            return
        }
        if focusedWindow, let localCwd {
            openChatTabAfterWindowFocus(sessionId: sessionId, cwd: localCwd, sid: sid, host: host)
        } else {
            // No CLI focus happened (no local cwd / CLI missing): the URI going to Cursor's last-active
            // window IS the mechanism that opens the chat here — no race to wait out, fire immediately.
            openChatDeepLink(sessionId: sessionId, sid: sid, host: host, focusedWindow: false, confirmation: "n/a")
        }
    }

    /// How long to wait for the CLI window focus to land before firing the deep-link, and the polling
    /// step. 3s covers a Space-switch to a far window; the settle beat absorbs the tail of the window
    /// animation after "Cursor is frontmost" flips (the URI routes by focused window, which can trail it).
    private static let deepLinkWaitBudgetMs = 3000
    private static let deepLinkPollStepMs = 100
    private static let deepLinkSettleMs = 250

    /// Poll until the CLI focus visibly landed, then fire the tab deep-link:
    ///  - Cursor frontmost + Accessibility granted → also require the focused window's title to mention
    ///    the project folder (VS Code titles embed the root name), so a same-app wrong-window front
    ///    doesn't swallow the URI;
    ///  - Cursor frontmost, no Accessibility → frontmost is the best signal available, accept it;
    ///  - budget exhausted but Cursor WAS seen frontmost → fire anyway (custom window titles may never
    ///    match — degrade to today's behavior, just later);
    ///  - Cursor never came frontmost → SKIP. The window focus is done regardless; a blind URI would
    ///    reopen the wrong-window/empty-chat bug this defers around. Skipping loses only the tab reveal.
    private static func openChatTabAfterWindowFocus(sessionId: String, cwd: String, sid: Substring,
                                                    host: SessionHost) {
        let folder = (cwd as NSString).lastPathComponent
        Task { @MainActor in
            let axGranted = FocusResolver.accessibilityGranted
            var sawCursorFront = false
            var confirmation: String?
            var waitedMs = 0
            while waitedMs < deepLinkWaitBudgetMs {
                if let front = NSWorkspace.shared.frontmostApplication, FocusResolver.isCursor(front) {
                    sawCursorFront = true
                    guard axGranted else { confirmation = "frontmost"; break }
                    if let title = FocusResolver.focusedWindowTitle(pid: front.processIdentifier),
                       title.localizedCaseInsensitiveContains(folder) {
                        confirmation = "title"
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(deepLinkPollStepMs) * 1_000_000)
                waitedMs += deepLinkPollStepMs
            }
            if confirmation == nil {
                guard sawCursorFront else {
                    Log.focus.warn("jump sid=\(sid): Cursor never came frontmost within "
                        + "\(deepLinkWaitBudgetMs)ms — deep-link skipped (would land in the wrong window)")
                    return
                }
                confirmation = "timeout"
            }
            try? await Task.sleep(nanoseconds: UInt64(deepLinkSettleMs) * 1_000_000)
            openChatDeepLink(sessionId: sessionId, sid: sid, host: host,
                             focusedWindow: true, confirmation: confirmation ?? "timeout")
        }
    }

    private static func openChatDeepLink(sessionId: String, sid: Substring, host: SessionHost,
                                         focusedWindow: Bool, confirmation: String) {
        guard let url = URL(string: "cursor://Anthropic.claude-code/open?session=\(sessionId)") else {
            Log.focus.warn("jump sid=\(sid): could not build the cursor:// deep-link URL")
            return
        }
        let ok = NSWorkspace.shared.open(url)
        Log.focus.info("jump sid=\(sid) host=\(host.rawValue) window=\(focusedWindow) "
            + "deeplink=\(ok ? "ok" : "FAILED") confirm=\(confirmation)")
        if !ok { Log.focus.warn("jump sid=\(sid): NSWorkspace could not open the cursor:// deep link") }
    }

    /// Best-effort raise of the app a session runs in — a terminal, or an IDE we can't (safely) deep-link
    /// into. We can only bring the app forward, deliberately NOT resume the chat (a terminal has no
    /// per-tab handle; a non-Cursor editor's URI scheme is unverified — and a blind resume would fork the
    /// session). No bundle id (tmux/login/ssh/an unbundled binary) or the app isn't running → a logged
    /// no-op, never a wrong jump.
    private static func activateHostApp(bundleId: String?, sid: Substring, kind: String) {
        guard let bundleId, !bundleId.isEmpty else {
            Log.focus.info("jump sid=\(sid) host=\(kind): no bundle id → nothing to raise")
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            Log.focus.info("jump sid=\(sid) host=\(kind) app=\(bundleId) not running → skip")
            return
        }
        let ok: Bool
        if #available(macOS 14.0, *) { ok = app.activate() }
        else { ok = app.activate(options: [.activateIgnoringOtherApps]) }
        Log.focus.info("jump sid=\(sid) host=\(kind) app=\(bundleId) raised=\(ok)")
    }

    private static func run(_ exe: String, _ args: [String], sid: Substring) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() }   // fire and forget
        catch { Log.focus.warn("jump sid=\(sid): failed to launch Cursor CLI: \(error.localizedDescription)") }
    }
}
