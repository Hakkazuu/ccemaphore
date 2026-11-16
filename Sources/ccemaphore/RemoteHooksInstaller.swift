import CryptoKit
import Foundation

/// Installs/removes ccemaphore's Claude Code and Codex hooks on a REMOTE host over SSH. The merge reuses
/// the local installers' transport-agnostic functions, so unrelated entries are preserved and malformed
/// settings are rejected before any file is written.
///
/// The remote hook COMMAND can't be the compiled `ccemaphore` Swift binary — remote hosts may be Linux,
/// and even on macOS shipping/trusting a copy of this app's binary on another machine is a bigger ask
/// than necessary. Instead we deploy `RemoteHookShim.source`, a portable Python 3 script that writes the
/// same `~/.claude/status/<id>.json` records parsed by `StatusReader`. Claude's permission relay also
/// uses `~/.claude/ccemaphore/pending/*`; a visible ccemaphore widget can relay Codex approval decisions
/// too, with Codex's native prompt as the fallback. See `RemoteHookShim.swift`.
enum RemoteHooksInstaller {
    enum RemoteHookError: LocalizedError {
        case platformUndetected
        case python3Missing
        case ssh(RemoteExec.SSHError)
        case settings(Error)

        var errorDescription: String? {
            switch self {
            case .platformUndetected: return L("remote.platform.unsupported")
            case .python3Missing: return L("remote.python3.missing")
            case .ssh(let e): return e.message
            case .settings(let e): return e.localizedDescription
            }
        }
    }

    static let remoteBaseDir = "~/.claude/ccemaphore"
    static var remoteShimPath: String { "\(remoteBaseDir)/bin/ccemaphore-hook.py" }
    static let remoteSettingsPath = "~/.claude/settings.json"
    static let remoteCodexHooksPath = "~/.codex/hooks.json"

    /// What a full install did with Codex's hooks on that host.
    enum CodexHooksOutcome: Sendable, Equatable {
        case noCodex            // no `~/.codex` there — nothing written
        case installed
        case failed(String)     // `~/.codex/hooks.json` unreadable / malformed — left untouched
    }

    /// The shim as deployed: the source plus a content-hash line, so `refreshShimIfOutdated` can tell an
    /// older copy from this build's.
    static var shimData: Data { Data((RemoteHookShim.source + "\n" + shimMarker + "\n").utf8) }
    private static var shimMarker: String {
        "# ccemaphore-shim: \(SHA256.hash(data: Data(RemoteHookShim.source.utf8)).map { String(format: "%02x", $0) }.joined())"
    }

    /// Full install: deploy the portable shim, merge Claude Code's hooks into `settings.json` and — only
    /// on a host that has Codex (`~/.codex`) — Codex's into `~/.codex/hooks.json`. A Codex file that can't
    /// be read or parsed is left alone and reported, without holding back Claude Code's hooks.
    @discardableResult
    static func install(_ host: RemoteHost) throws -> CodexHooksOutcome {
        guard RemoteExec.hasPython3(host) else { throw RemoteHookError.python3Missing }
        do {
            // The hook COMMAND embedded in settings.json is quoted by `HooksInstaller.shQuote` (SHARED
            // with the local installer), which wraps the entire `exe` value in ONE pair of double quotes
            // and escapes `$` to `\$` — correct for a plain absolute path (the local case it was written
            // for), but fatal for a two-token "python3 <path>" string or an unexpanded `$HOME`/`~`: both
            // collapse into a single, non-existent "command" the remote shell can't execute, so the hook
            // silently no-ops every time (this was live-diagnosed: settings.json looked correctly
            // installed, but no status file was ever updated for real session activity). Resolving `$HOME`
            // to a concrete absolute path HERE — once, over SSH — and invoking the shim file directly
            // (it has a `#!/usr/bin/env python3` shebang and is chmod +x'd by `uploadExecutable`) makes
            // `exe` a single, ordinary path with no embedded shell syntax, exactly like the local case.
            let home = try RemoteExec.run(host, command: "printf '%s' \"$HOME\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let exe = home.isEmpty ? remoteShimPath : "\(home)/.claude/ccemaphore/bin/ccemaphore-hook.py"
            var root = stripLegacyInlineEntries(try readRemoteSettings(host))
            root = try HooksInstaller.mergeInstall(root: root, exe: exe)
            root = try HooksInstaller.mergeInstallPermission(root: root, exe: exe)
            try RemoteExec.uploadExecutable(host, data: shimData, remotePath: remoteShimPath)
            try writeRemoteSettings(host, root: root)
            let codex = try installCodexHooks(host, exe: exe)
            Log.settings.info("installed remote hooks on \(host.label) (\(host.hostname)) exe=\(exe) codex=\(codex)")
            return codex
        } catch let e as RemoteExec.SSHError {
            throw RemoteHookError.ssh(e)
        } catch let e as HooksInstaller.HookError {
            throw RemoteHookError.settings(e)
        }
    }

    static func uninstall(_ host: RemoteHost) throws {
        do {
            let before = try readRemoteSettings(host)
            var root = stripLegacyInlineEntries(before)
            root = try HooksInstaller.mergeUninstall(root: root)
            // No-write guard (compare FRESH-read vs final, not stripped-vs-final): a file with only legacy
            // inline entries still differs from `before` and MUST be rewritten, but a file with nothing of
            // ours is left byte-identical instead of being reformatted or created as `{}`.
            if !HooksInstaller.nsEqual(before, root) {
                try writeRemoteSettings(host, root: root)
            }
            // Codex's file only if it exists and parses: an unreadable one can't hold entries we could find.
            do {
                let codexBefore = try readRemoteCodexHooks(host)
                let codexAfter = CodexHooksInstaller.removed(codexBefore)
                if !HooksInstaller.nsEqual(codexBefore, codexAfter) {
                    try RemoteExec.writeFile(host, path: remoteCodexHooksPath,
                                             data: HooksInstaller.encodeSettings(codexAfter))
                }
            } catch let e as HooksInstaller.HookError {
                Log.settings.warn("remote uninstall on \(host.label): \(remoteCodexHooksPath) left as is (\(e.localizedDescription))")
            }
            _ = try? RemoteExec.run(host, command: "rm -f \(RemoteExec.shQuote(remoteShimPath))")
            Log.settings.info("uninstalled remote hooks on \(host.label) (\(host.hostname))")
        } catch let e as RemoteExec.SSHError {
            throw RemoteHookError.ssh(e)
        } catch let e as HooksInstaller.HookError {
            throw RemoteHookError.settings(e)
        }
    }

    /// Strip hook entries left by an EARLIER, differently-shaped remote installer that embedded the
    /// whole hook script inline as `python3 -c "..."` (tagged with a `# ccemaphore-remote-hook` marker
    /// comment) instead of deploying `RemoteHookShim.source` to a file and invoking it by path. Local
    /// `HooksInstaller`'s shared `isOurBasic`/`isPermissionEntry` predicates require the command to
    /// START with a quoted path (`"…" --hook <kw>`) — the inline form starts with `python3 -c` instead,
    /// so those predicates never recognized it as "ours," and every `install()` kept ADDING the new
    /// file-based entry alongside the orphaned inline one rather than replacing it: every hook event fired
    /// TWICE (duplicate pending-request writes racing each other, which is what broke Allow/Deny for a
    /// remote permission request). Scoped to this file only — local `HooksInstaller` and its predicates
    /// are untouched; the marker string is specific enough that a genuine user hook could never collide.
    private static func stripLegacyInlineEntries(_ root: [String: Any]) -> [String: Any] {
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        var root = root
        for (event, value) in hooks {
            guard var arr = value as? [[String: Any]] else { continue }
            arr.removeAll { entry in
                let cmds = (entry["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
                return cmds.contains { $0.contains("ccemaphore-remote-hook") }
            }
            if arr.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = arr }
        }
        root["hooks"] = hooks
        return root
    }

    /// Lenient status check — mirrors `HooksInstaller.isInstalled()`, for `--remote-hooks-status`/UI.
    static func isInstalled(_ host: RemoteHost) -> Bool {
        guard let root = try? readRemoteSettings(host) else { return false }
        return HooksInstaller.isAnyInstalled(root: root)
    }

    /// Strict remote read, SHARING `HooksInstaller.parseSettingsStrict`. `RemoteExec.readFile` now THROWS
    /// on a transport/permission failure (only a genuinely-absent file returns nil → `[:]`), so a dropped
    /// ssh mid-install propagates out of `install`/`uninstall` and `writeRemoteSettings` is never reached
    /// — the remote settings.json can't be clobbered with a hooks-only file on a transient failure (V5).
    private static func readRemoteSettings(_ host: RemoteHost) throws -> [String: Any] {
        let data = try RemoteExec.readFile(host, path: remoteSettingsPath)
        return try HooksInstaller.parseSettingsStrict(data: data, path: remoteSettingsPath)
    }

    /// Merge Codex's hooks on a host that has Codex. Transport failures throw (the host is gone); a bad
    /// `hooks.json` is reported as `.failed` and never written.
    private static func installCodexHooks(_ host: RemoteHost, exe: String) throws -> CodexHooksOutcome {
        let probe = try RemoteExec.run(host, command: "if [ -d \"$HOME/.codex\" ]; then echo yes; fi")
        guard probe.trimmingCharacters(in: .whitespacesAndNewlines) == "yes" else { return .noCodex }
        do {
            let before = try readRemoteCodexHooks(host)
            let after = try CodexHooksInstaller.merged(
                before, exe: exe, permissionRequestTimeout: Int(Tuning.permissionPollTimeout) + 30)
            if !HooksInstaller.nsEqual(before, after) {
                try RemoteExec.writeFile(host, path: remoteCodexHooksPath, data: HooksInstaller.encodeSettings(after))
            }
            return .installed
        } catch let e as HooksInstaller.HookError {
            return .failed(e.localizedDescription)
        }
    }

    /// Bring an already-deployed shim up to this build's version. The file is ours (overwritten on every
    /// install), and the app and the shim must agree — e.g. on the visibility beacon — so a host keeps
    /// working as this version expects without a manual reinstall. Never installs a shim or touches any
    /// settings; Codex's hook trust covers the hook command, not the script's bytes, so nothing needs
    /// re-approving. Returns false when the host couldn't be asked (retry later).
    static func refreshShimIfOutdated(_ host: RemoteHost) -> Bool {
        let f = RemoteExec.shQuote(remoteShimPath)
        let cmd = "if [ ! -f \(f) ]; then echo none; elif grep -qF \(RemoteExec.shQuote(shimMarker)) \(f); then echo current; else echo old; fi"
        guard let state = try? RemoteExec.run(host, command: cmd).trimmingCharacters(in: .whitespacesAndNewlines),
              !state.isEmpty else { return false }
        guard state == "old" else { return true }
        do {
            try RemoteExec.uploadExecutable(host, data: shimData, remotePath: remoteShimPath)
            Log.settings.info("updated the remote hook shim on \(host.label)")
            return true
        } catch {
            Log.settings.warn("remote hook shim update on \(host.label) failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func readRemoteCodexHooks(_ host: RemoteHost) throws -> [String: Any] {
        let data = try RemoteExec.readFile(host, path: remoteCodexHooksPath)
        return try HooksInstaller.parseSettingsStrict(data: data, path: remoteCodexHooksPath)
    }

    private static func writeRemoteSettings(_ host: RemoteHost, root: [String: Any]) throws {
        try RemoteExec.writeFile(host, path: remoteSettingsPath, data: HooksInstaller.encodeSettings(root))
    }
}
