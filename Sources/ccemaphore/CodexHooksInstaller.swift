import Foundation
import CryptoKit

/// Installs/removes ccemaphore's hooks in Codex's `~/.codex/hooks.json` (user scope → every Codex thread,
/// in ChatGPT.app and the CLI alike). Same JSON shape as Claude Code's `settings.json` `hooks` object, so
/// the parsing/merging/writing primitives are `HooksInstaller`'s; what differs:
///  - the event list (Codex has `Interrupt` and `PostCompact`, no `Notification`);
///  - every command carries ` --agent codex`, so the hook process knows whose payload it reads;
///  - TRUST: Codex refuses to run a hooks.json it hasn't reviewed (hash-bound, `hooks.state."<hash>"
///    .trusted_hash` in config.toml). We never write that record ourselves — the user approves the file in
///    the ChatGPT app (Codex settings → Hooks) or with `/hooks` in the CLI — but we DO report where things
///    stand (`trustState`), and we touch hooks.json as rarely as possible because every change resets it.
///
/// Legacy entries: ChatGPT.app's "import Claude Code config" copies the user's Claude hooks verbatim into
/// hooks.json — including OUR Claude-shaped `"…ccemaphore" --hook …` commands (no `--agent`). Those are
/// ours too: install REPLACES them with the Codex-tagged form, uninstall removes them.
enum CodexHooksInstaller {
    /// (Codex hook event, our `--hook` keyword, whether the event uses a tool matcher).
    static let events: [(event: String, keyword: String, matcher: Bool)] = [
        ("SessionStart", "start", false),
        ("SessionEnd", "end", false),
        ("UserPromptSubmit", "prompt", false),
        // No `matcher` key for Codex: Claude's empty-string "match everything" convention is unverified
        // there, and an absent matcher means "all tools" in both.
        ("PreToolUse", "pre", false),
        ("PostToolUse", "post", false),
        ("Stop", "stop", false),
        ("Interrupt", "interrupt", false),
        ("PreCompact", "precompact", false),
        ("PostCompact", "postcompact", false),
    ]
    private static let basicKeywords = events.map(\.keyword)

    /// Test seam: point at a throwaway file to exercise merge/uninstall without touching ~/.codex.
    static var hooksPath: String {
        if let p = ProcessInfo.processInfo.environment["CCEMAPHORE_CODEX_HOOKS_PATH"], !p.isEmpty { return p }
        return CodexPaths.hooksPath
    }
    /// The file name a shape error names (`HooksInstaller.HookError.unexpectedShape`).
    private static var hooksFileName: String { (hooksPath as NSString).lastPathComponent }
    static var configPath: String {
        if let p = ProcessInfo.processInfo.environment["CCEMAPHORE_CODEX_CONFIG_PATH"], !p.isEmpty { return p }
        return CodexPaths.configPath
    }

    enum TrustState: Equatable, CustomStringConvertible {
        /// No hooks.json (or nothing of ours in it) — nothing to trust yet.
        case notInstalled
        /// config.toml records a trust hash matching the CURRENT hooks.json bytes → Codex runs the hooks.
        case trusted
        /// config.toml has a hooks trust record, but not for these bytes: hooks.json changed since approval.
        case stale
        /// No hooks trust record at all: never reviewed in Codex.
        case untrusted

        var description: String {
            switch self {
            case .notInstalled: return "not-installed"
            case .trusted:      return "trusted"
            case .stale:        return "stale (hooks.json changed since approval)"
            case .untrusted:    return "untrusted (never reviewed in Codex)"
            }
        }
    }

    // MARK: - Status (lenient)

    /// Installed = our Codex-TAGGED entries are present. Imported Claude-shaped copies don't count: they
    /// would mis-key Codex payloads as Claude sessions if Codex ever ran them, so they read as "off" until
    /// `install()` replaces them.
    static func isInstalled() -> Bool {
        guard let hooks = readLenient()["hooks"] as? [String: Any] else { return false }
        return events.contains { e in
            (hooks[e.event] as? [[String: Any]])?.contains(where: isOurTaggedBasic) ?? false
        }
    }

    /// Un-tagged (imported) copies of our Claude hooks are present in hooks.json. Surfaced so the user
    /// knows why the row reads "off" despite entries being there.
    static func hasLegacyImports() -> Bool {
        guard let hooks = readLenient()["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { ($0 as? [[String: Any]])?.contains(where: HooksInstaller.isAnyOurs) ?? false }
    }

    static func isPermissionHookInstalled() -> Bool {
        guard let hooks = readLenient()["hooks"] as? [String: Any],
              let arr = hooks["PermissionRequest"] as? [[String: Any]] else { return false }
        return arr.contains(where: isPermissionEntry)
    }

    /// Where Codex's hash-bound trust stands for the CURRENT hooks.json. Codex records
    /// `hooks.state."<hash>".trusted_hash = "<hash>"` in config.toml when the user approves the file; the
    /// hash is taken to be the SHA-256 of the file bytes — a HYPOTHESIS until verified against a real
    /// approval. If it is wrong, a trusted file reads as `.stale`; that state's caption therefore says only
    /// "no approval on record for the current file — review it in Codex", never "the file changed".
    static func trustState() -> TrustState {
        guard isInstalled() || isPermissionHookInstalled(),
              let bytes = FileManager.default.contents(atPath: hooksPath) else { return .notInstalled }
        guard let config = try? String(contentsOfFile: configPath, encoding: .utf8) else { return .untrusted }
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        if config.contains(sha) { return .trusted }
        return config.contains("trusted_hash") ? .stale : .untrusted
    }

    // MARK: - Install / uninstall (strict)

    static func install() throws {
        var root = try HooksInstaller.loadStrict(path: hooksPath)
        var hooks = try HooksInstaller.hooksObject(root, file: hooksFileName)
        let exe = HooksInstaller.executablePath
        for e in events {
            var arr = try HooksInstaller.eventArray(hooks, e.event, file: hooksFileName)
            arr.removeAll(where: isOurBasic)                  // idempotent; incl. imported Claude-shaped ones
            arr.append(HooksInstaller.entry(keyword: e.keyword, matcher: e.matcher, exe: exe, agent: .codex))
            hooks[e.event] = arr
        }
        // The import also brings Claude-only events we never register for Codex (`Notification`) and a
        // Claude-shaped PermissionRequest; drop OUR entries there so no un-tagged command lingers.
        for event in ["Notification", "SubagentStart", "SubagentStop", "PermissionRequest"] {
            guard var arr = hooks[event] as? [[String: Any]] else { continue }
            arr.removeAll(where: HooksInstaller.isAnyOurs)
            if arr.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = arr }
        }
        root["hooks"] = hooks
        try HooksInstaller.write(root, to: hooksPath)
        Log.codex.info("installed codex hooks → \(hooksPath) (exe=\(exe)); Codex must now trust the file")
    }

    static func installPermissionHook() throws {
        var root = try HooksInstaller.loadStrict(path: hooksPath)
        var hooks = try HooksInstaller.hooksObject(root, file: hooksFileName)
        var arr = try HooksInstaller.eventArray(hooks, "PermissionRequest", file: hooksFileName)
        arr.removeAll(where: { isPermissionEntry($0) || HooksInstaller.isAnyOurs($0) })
        arr.append(HooksInstaller.permissionEntry(exe: HooksInstaller.executablePath, agent: .codex))
        hooks["PermissionRequest"] = arr
        root["hooks"] = hooks
        try HooksInstaller.write(root, to: hooksPath)
        Log.codex.info("installed codex PermissionRequest hook → \(hooksPath)")
    }

    static func uninstallPermissionHook() throws {
        var root = try HooksInstaller.loadStrict(path: hooksPath)
        guard var hooks = root["hooks"] as? [String: Any],
              var arr = hooks["PermissionRequest"] as? [[String: Any]] else { return }
        arr.removeAll(where: isPermissionEntry)
        if arr.isEmpty { hooks.removeValue(forKey: "PermissionRequest") } else { hooks["PermissionRequest"] = arr }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try HooksInstaller.write(root, to: hooksPath)
        Log.codex.info("removed codex PermissionRequest hook → \(hooksPath)")
    }

    /// Remove everything of ours (Codex-tagged AND imported Claude-shaped). No-write when nothing changes;
    /// an absent file is never materialized.
    static func uninstall() throws {
        let before = try HooksInstaller.loadStrict(path: hooksPath)
        var root = before
        if var hooks = root["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard var arr = value as? [[String: Any]] else { continue }
                arr.removeAll(where: { isAnyOurs($0) || HooksInstaller.isAnyOurs($0) })
                if arr.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = arr }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
        guard !HooksInstaller.nsEqual(before, root) else {
            Log.codex.info("codex uninstall: nothing of ours in \(hooksPath) → left untouched")
            return
        }
        try HooksInstaller.write(root, to: hooksPath)
        Log.codex.info("uninstalled codex hooks → \(hooksPath)")
    }

    /// Refresh-only self-heal, like `HooksInstaller.healInstalled` — but every byte changed in hooks.json
    /// invalidates Codex's hash-bound trust, so this is deliberately NARROWER than the Claude one: an
    /// entry is re-pointed at THIS binary only when the binary it names is GONE (a deleted DerivedData
    /// build, an app that moved). Two coexisting builds (Xcode's and /Applications') never churn a
    /// trusted file: whichever one the entries name keeps running, and both read the same status files.
    static func healInstalled() throws {
        var root = try HooksInstaller.loadStrict(path: hooksPath)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        let exe = HooksInstaller.executablePath
        var changed = false
        for e in events {
            guard var arr = hooks[e.event] as? [[String: Any]] else { continue }
            let desired = HooksInstaller.entry(keyword: e.keyword, matcher: e.matcher, exe: exe, agent: .codex)
            var touched = false
            for i in arr.indices where isOurTaggedBasic(arr[i]) && isDangling(arr[i]) && !HooksInstaller.nsEqual(arr[i], desired) {
                arr[i] = desired; touched = true
            }
            if touched { hooks[e.event] = arr; changed = true }
        }
        if var arr = hooks["PermissionRequest"] as? [[String: Any]] {
            let desired = HooksInstaller.permissionEntry(exe: exe, agent: .codex)
            var touched = false
            for i in arr.indices where isPermissionEntry(arr[i]) && isDangling(arr[i]) && !HooksInstaller.nsEqual(arr[i], desired) {
                arr[i] = desired; touched = true
            }
            if touched { hooks["PermissionRequest"] = arr; changed = true }
        }
        guard changed else { return }
        root["hooks"] = hooks
        try HooksInstaller.write(root, to: hooksPath)
        Log.codex.warn("self-healed codex hook commands whose binary was gone → \(exe); hooks.json changed, so Codex will ask to trust it again")
    }

    /// An entry whose command names a binary that no longer exists (or can't be parsed) — the only case
    /// the self-heal touches.
    private static func isDangling(_ entry: [String: Any]) -> Bool {
        let exes = commands(entry).compactMap(commandExe)
        return exes.isEmpty || exes.contains { !FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The executable a hook command points at — the inverse of `HooksInstaller.shQuote` (a double-quoted
    /// path with `\"`, `\\`, `` \` ``, `\$` escapes), or the first bare token of an unquoted command.
    static func commandExe(_ cmd: String) -> String? {
        guard cmd.hasPrefix("\"") else { return cmd.split(separator: " ", maxSplits: 1).first.map(String.init) }
        var out = ""
        var escaped = false
        for ch in cmd.dropFirst() {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { return out }
            out.append(ch)
        }
        return nil   // unterminated quote
    }

    // MARK: - Ownership (structural + ccemaphore-anchored + `--agent codex`-tagged)

    private static func commands(_ entry: [String: Any]) -> [String] {
        (entry["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
    }

    /// Our Codex basic entry: `… --hook <kw> --agent codex`.
    static func isOurTaggedBasic(_ entry: [String: Any]) -> Bool {
        commands(entry).contains { cmd in
            guard cmd.hasPrefix("\""), cmd.contains("ccemaphore") else { return false }
            return basicKeywords.contains { cmd.hasSuffix(" --hook \($0) --agent codex") }
        }
    }

    /// Ours to replace/remove: the tagged entry OR an imported Claude-shaped one of ours (`… --hook <kw>`).
    static func isOurBasic(_ entry: [String: Any]) -> Bool {
        isOurTaggedBasic(entry) || HooksInstaller.isOurBasic(entry)
    }

    static func isPermissionEntry(_ entry: [String: Any]) -> Bool {
        commands(entry).contains {
            $0.hasPrefix("\"") && $0.contains("ccemaphore") && $0.hasSuffix(" --hook permission-request --agent codex")
        }
    }

    static func isAnyOurs(_ entry: [String: Any]) -> Bool { isOurBasic(entry) || isPermissionEntry(entry) }

    private static func readLenient() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: hooksPath),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return obj
    }
}
