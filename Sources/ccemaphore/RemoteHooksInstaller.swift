import Foundation

/// Installs/removes ccemaphore's Claude Code hooks on a REMOTE host's `~/.claude/settings.json`, over
/// SSH, mirroring `HooksInstaller` exactly except for transport: reads/writes go through `RemoteExec`
/// instead of `FileManager`, and the merge itself reuses `HooksInstaller`'s pure, transport-agnostic
/// `mergeInstall`/`mergeInstallPermission`/`mergeUninstall`/`isAnyInstalled` functions — so the
/// idempotent-merge guarantees (never touch a non-ccemaphore entry, never write on an unparseable file)
/// hold identically on the remote side.
///
/// The remote hook COMMAND can't be the compiled `ccemaphore` Swift binary — remote hosts may be Linux,
/// and even on macOS shipping/trusting a copy of this app's binary on another machine is a bigger ask
/// than necessary. Instead we deploy `RemoteHookShim.source`, a portable Python 3 script that
/// reimplements the minimal subset of `HookHandler.run`/`PermissionBroker.runHook` needed for status +
/// permission parity, writing the SAME `~/.claude/status/<id>.json` / `~/.claude/ccemaphore/pending/*`
/// shapes `StatusReader`/`PermissionBroker.PendingRequest` already parse. See `RemoteHookShim.swift`.
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

    /// Full install: verify the host is reachable + has python3, deploy the shim, merge both the basic
    /// and permission hook entries into the remote settings.json.
    static func install(_ host: RemoteHost) throws {
        guard RemoteExec.hasPython3(host) else { throw RemoteHookError.python3Missing }
        do {
            try RemoteExec.uploadExecutable(
                host, data: Data(RemoteHookShim.source.utf8), remotePath: remoteShimPath)
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
            try writeRemoteSettings(host, root: root)
            Log.settings.info("installed remote hooks on \(host.label) (\(host.hostname)) exe=\(exe)")
        } catch let e as RemoteExec.SSHError {
            throw RemoteHookError.ssh(e)
        } catch let e as HooksInstaller.HookError {
            throw RemoteHookError.settings(e)
        }
    }

    static func uninstall(_ host: RemoteHost) throws {
        do {
            var root = stripLegacyInlineEntries(try readRemoteSettings(host))
            root = try HooksInstaller.mergeUninstall(root: root)
            try writeRemoteSettings(host, root: root)
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

    private static func readRemoteSettings(_ host: RemoteHost) throws -> [String: Any] {
        guard let data = try RemoteExec.readFile(host, path: remoteSettingsPath), !data.isEmpty else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw HooksInstaller.HookError.unparseableSettings(remoteSettingsPath)
        }
        guard let dict = obj as? [String: Any] else {
            throw HooksInstaller.HookError.unexpectedShape(L("shape.rootNotObject"))
        }
        return dict
    }

    private static func writeRemoteSettings(_ host: RemoteHost, root: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try RemoteExec.writeFile(host, path: remoteSettingsPath, data: data)
    }
}
