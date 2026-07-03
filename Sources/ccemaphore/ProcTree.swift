import Foundation
import Darwin

/// Tiny process-tree helper used to bind a Claude Code session to the OS process that owns it, so a
/// closed window / killed session drops off the light immediately instead of lingering until
/// `staleWindow`. Liveness is decided by the kernel (`kill(pid,0)`), not a timestamp — same principle as
/// `AppPresence`, but pointed at a FOREIGN pid (the agent), so there's no "is it still our binary" check.
///
/// This is our reinterpretation of gmr/claude-status's "validate the session by its process tree": they
/// know the pid because they spawn a per-session daemon; we don't, so the hook walks up its own ancestry
/// to find the owning agent and records that pid in the status file (see `HookHandler.writeStatus`).
enum ProcTree {
    /// PID of one process's parent, via `sysctl(KERN_PROC_PID)`. nil if the pid is gone/unreadable.
    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = mib.withUnsafeMutableBufferPointer { buf in
            sysctl(buf.baseAddress, UInt32(buf.count), &info, &size, nil, 0)
        }
        guard rc == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    /// Absolute executable PATH for `pid` (empty if we can't read it — e.g. a process we don't own).
    static func execPath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(cString: buf)
    }

    /// Last path component of `execPath` — the process's binary name (empty if unreadable).
    static func execName(_ pid: pid_t) -> String {
        (execPath(pid) as NSString).lastPathComponent
    }

    /// True iff `pid` is a live process. EPERM means "alive but owned by someone else" → still alive.
    static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static let shells: Set<String> =
        ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "-zsh", "-bash", "-fish"]

    /// The hook invocation's ancestor chain as `(pid, execPath)`, from our parent upward, bounded so a
    /// weird tree can't loop. The single source both `ownerPID` and `sessionContext` derive from — one
    /// process-tree walk per hook rather than two. execPath is "" for an ancestor we can't read.
    private static func ancestry(maxHops: Int = 16) -> [(pid: pid_t, path: String)] {
        var out: [(pid_t, String)] = []
        var pid = getppid()
        var hops = 0
        while pid > 1 && hops < maxHops {
            out.append((pid, execPath(pid)))
            guard let parent = parentPID(pid), parent != pid, parent > 1 else { break }
            pid = parent
            hops += 1
        }
        return out
    }

    /// The owning agent process for the CURRENT hook invocation: the first ancestor that is not a shell
    /// Claude Code wraps hook commands in (`sh -c "…"`) nor our own binary — the node/claude/Cursor-helper
    /// process that lives for the whole session. nil if nothing plausible is found (→ no pid recorded →
    /// the session simply falls back to the `staleWindow` timeout, never mis-reaped).
    static func ownerPID() -> pid_t? { ownerPID(in: ancestry()) }

    private static func ownerPID(in chain: [(pid: pid_t, path: String)]) -> pid_t? {
        ownerIndex(in: chain).map { chain[$0].pid }
    }

    /// Index (within `chain`) of the owning agent process — the first ancestor that is neither a hook
    /// wrapper shell nor our own binary. Shared by `ownerPID` and `classifyHost`'s IDE-scan bound.
    private static func ownerIndex(in chain: [(pid: pid_t, path: String)]) -> Int? {
        chain.firstIndex { a in
            let name = (a.path as NSString).lastPathComponent
            return !name.isEmpty && name != "ccemaphore" && !shells.contains(name)
        }
    }

    // MARK: - Host detection (IDE vs. terminal) for the current hook invocation

    /// The session's owner pid + where it's hosted, from ONE ancestry walk. Called by `HookHandler.
    /// writeStatus`, so it runs in the short-lived hook process where the ancestry IS the Claude Code
    /// session's own tree. See `SessionHost`.
    static func sessionContext() -> (ownerPid: pid_t?, host: SessionHost, hostBundleId: String?) {
        let chain = ancestry()
        let owner = ownerPID(in: chain)
        let (host, bundleId) = classifyHost(chain)
        return (owner, host, bundleId)
    }

    /// Path substrings that mark an ancestor as an IDE host running the Claude Code EXTENSION — the only
    /// case where a native side-channel permission dialog appears (so the broker may safely block). In an
    /// extension host the `claude` binary itself lives under the extension dir (verified in Cursor:
    /// `~/.cursor/extensions/anthropic.claude-code-*/…/claude`), which these catch.
    ///
    /// Deliberately NOT a bare `/Cursor.app/` / `/Code.app/` match: Claude Code's CLI run in the editor's
    /// INTEGRATED TERMINAL also has an editor `.app` ancestor (its pty/extension-host helper), but its
    /// prompt is INLINE text — blocking on it would freeze the agent (the very thing the host gate
    /// avoids). Keying on the extension dir distinguishes the two; an integrated-terminal claude has no
    /// such marker → falls through to `.unknown`/`.terminal` → no wait window. See the review finding in
    /// memory/terminal-mode-review.md.
    private static let ideMarkers = [
        ".cursor/extensions", ".vscode/extensions", ".vscode-server", ".windsurf/extensions",
    ]
    /// Terminal emulators (by `.app` path) + shell-multiplexer/login binaries (by exec name) that mark a
    /// real-terminal host. Not exhaustive — an unmatched host stays `.unknown` (focus falls back to the
    /// Cursor path), never wrongly `.terminal`.
    private static let terminalAppMarkers = [
        "/Terminal.app/", "/iTerm.app/", "/Ghostty.app/", "/WezTerm.app/", "/kitty.app/",
        "/Alacritty.app/", "/Warp.app/", "/WarpPreview.app/", "/Hyper.app/", "/Tabby.app/",
        "/Rio.app/",
    ]
    private static let terminalExecNames: Set<String> =
        ["tmux", "tmux: server", "screen", "login", "ghostty", "wezterm-gui", "alacritty", "kitty"]

    private static func classifyHost(_ chain: [(pid: pid_t, path: String)]) -> (SessionHost, String?) {
        // IDE first (a `login` shell can appear under an editor too). Then a terminal `.app` across the
        // WHOLE chain BEFORE the exec-name pass — otherwise a `login`/`tmux` ancestor (exec-name match,
        // no bundle) would return before the real `Terminal.app` further up and drop its bundle id.
        //
        // The IDE scan is BOUNDED at the session's owning agent (inclusive): an extension-hosted claude
        // carries the marker on the owner's OWN exec path, so a genuine IDE chat still classifies — but
        // a NESTED claude (spawned from another session's Bash tool, so the OUTER session's extension
        // claude sits further up the chain) must not inherit `.ide` from it. That chat has no IDE tab;
        // stamping it Cursor-confirmed would hand the resume-capable `cursor://` deep-link to exactly
        // the sessions it can fork, and give a headless `claude -p` a pointless permission wait window.
        // Terminal markers keep scanning the whole chain: the terminal .app always sits ABOVE the owner,
        // and "raise the app" can't fork anything.
        let ideScan = ownerIndex(in: chain).map { chain[...$0] } ?? chain[...]
        for a in ideScan where ideMarkers.contains(where: a.path.contains) {
            // The marker ancestor is normally the extension's own `claude` binary
            // (`~/.cursor/extensions/anthropic.claude-code-*/…/claude`), which lives OUTSIDE any `.app`
            // bundle — so fall back to the first ancestor inside one (the editor's extension-host
            // helper, e.g. `/Applications/Cursor.app/…/Cursor Helper (Plugin)`). Without the fallback
            // every IDE session was bundle-less and DeepLinker couldn't tell Cursor from VS Code —
            // a VS Code / Windsurf chat's "перейти в чат" opened Cursor.
            return (.ide, bundleId(fromExecPath: a.path) ?? firstAppBundleId(in: chain))
        }
        for a in chain where terminalAppMarkers.contains(where: a.path.contains) {
            return (.terminal, bundleId(fromExecPath: a.path))
        }
        for a in chain where terminalExecNames.contains((a.path as NSString).lastPathComponent) {
            return (.terminal, bundleId(fromExecPath: a.path))
        }
        return (.unknown, nil)
    }

    /// Bundle id of the OUTERMOST `.app` in an exec path (`/Applications/iTerm.app/Contents/MacOS/iTerm2`
    /// → `com.googlecode.iterm2`), via `Bundle` (Foundation-only, so it works in the hook process). The
    /// outermost match also makes an Electron helper resolve to its OWNING app (`/Applications/Cursor.app/
    /// Contents/Frameworks/Cursor Helper (Plugin).app/…` → Cursor's id, not the helper's). nil if the
    /// path isn't inside a `.app` or the bundle has no id (e.g. a bare `tmux`/`login` binary).
    private static func bundleId(fromExecPath path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        let appPath = String(path[path.startIndex..<r.lowerBound]) + ".app"
        return Bundle(path: appPath)?.bundleIdentifier
    }

    /// Bundle id of the first ancestor that lives inside a `.app` bundle — the IDE branch's fallback for
    /// recovering the editor's identity when the marker ancestor itself is a bare binary. Walking from
    /// the hook upward, the first bundled ancestor IS the hosting editor's process tree (nothing sits
    /// between the extension's `claude` and the editor's helper). nil in a bundle-less tree (ssh,
    /// `.vscode-server` remotes).
    private static func firstAppBundleId(in chain: [(pid: pid_t, path: String)]) -> String? {
        for a in chain {
            if let id = bundleId(fromExecPath: a.path) { return id }
        }
        return nil
    }
}
