import Foundation

/// Installs/removes ccemaphore's hooks in Codex's `~/.codex/hooks.json` (user scope → every Codex thread,
/// in ChatGPT.app and the CLI alike). Same JSON shape as Claude Code's `settings.json` `hooks` object, so
/// the parse/write primitives are `HooksInstaller`'s. What is Codex-specific:
///  - the event set (`events`) is SMALL on purpose. Mode A (the rollout, `CodexSessionStore`) already
///    tells working / done precisely, so hooks add only what a rollout can't show: Codex waiting for the
///    user's approval (`PermissionRequest` → red), context compaction (the chip), and a prompt reset of
///    both when a turn stops or is interrupted. No per-tool `PreToolUse`/`PostToolUse`: Codex waits for a
///    hook process on every tool call, and the rollout already says when the turn moved on
///    (`CodexHookOverlay`). Fewer hooks is also fewer handlers for the user to approve;
///  - every command carries ` --agent codex`, so the hook process knows whose payload it reads;
///  - TRUST: Codex skips a handler until the user approves it ("Review hooks" in the ChatGPT app, `/hooks`
///    in the CLI). Trust is per handler and hash-bound (`CodexHookTrust`), so ANY change to one of our
///    entries — even moving it to another index — asks for approval again. We therefore write hooks.json
///    only on an explicit install / update / removal, and the self-heal touches nothing but a dangling
///    binary path. We never write the trust record ourselves.
///
/// Recognized as ours (replaced by install, removed by uninstall): the Codex-tagged commands of any
/// version (`"…ccemaphore…" --hook <kw> --agent codex`), and the un-tagged Claude-shaped copies that
/// ChatGPT.app's "import Claude Code config" writes into hooks.json.
enum CodexHooksInstaller {
    /// The hooks we install: (Codex event, our `--hook` keyword). `permission-request` routes to the
    /// `PermissionBroker` (which never blocks for Codex — `mayBlock`); the rest to `HookHandler`.
    static let events: [(event: String, keyword: String)] = [
        ("PermissionRequest", "permission-request"),
        ("Stop", "stop"),
        ("Interrupt", "interrupt"),
        ("PreCompact", "precompact"),
        ("PostCompact", "postcompact"),
    ]

    /// Seconds Codex gives a hook before killing it. Our handlers return at once; Codex clamps
    /// `Interrupt` to 3 s (and warns about a larger value), so it gets exactly that.
    static func timeout(for event: String) -> Int { event == "Interrupt" ? 3 : 10 }

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

    // MARK: - Status

    /// Install state + Codex's trust verdict for each of our handlers. Lenient: unreadable files read as
    /// "nothing installed" / "no trust records".
    static func status() -> CodexHooksStatus {
        let root = readLenient()
        let config = MiniTOML.flatten((try? String(contentsOfFile: configPath, encoding: .utf8)) ?? "")
        return status(hooksRoot: root, hooksPath: keyPath(hooksPath), config: config)
    }

    /// The pure half of `status()`. `hooksPath` is the path Codex keys trust by (`keyPath`).
    static func status(hooksRoot: [String: Any], hooksPath: String, config: [[String]: MiniTOML.Value]) -> CodexHooksStatus {
        let install = installState(hooksRoot)
        guard install != .none else { return .notInstalled }
        let entries = CodexHookTrust.entries(hooksRoot: hooksRoot, hooksPath: hooksPath,
                                             states: CodexHookTrust.states(in: config), isOurs: isOurCommand)
        return CodexHooksStatus(install: install,
                                featureEnabled: CodexHookTrust.hooksFeatureEnabled(in: config),
                                entries: entries)
    }

    /// `current` iff every event of `events` holds exactly one entry of ours with its keyword, and nothing
    /// else of ours exists anywhere (an older layout's extra events, an imported Claude-shaped copy).
    static func installState(_ root: [String: Any]) -> CodexHooksStatus.Install {
        guard let hooks = root["hooks"] as? [String: Any] else { return .none }
        var ours: [(event: String, entry: [String: Any])] = []
        for (event, value) in hooks {
            for entry in (value as? [[String: Any]]) ?? [] where isOurs(entry) { ours.append((event, entry)) }
        }
        guard !ours.isEmpty else { return .none }
        guard ours.count == events.count else { return .outdated }
        for e in events {
            let matching = ours.filter { $0.event == e.event }
            guard matching.count == 1,
                  commands(matching[0].entry).contains(where: { $0.hasSuffix(" --hook \(e.keyword) --agent codex") })
            else { return .outdated }
        }
        return .current
    }

    /// Codex keys trust by the PHYSICAL hooks.json path (it canonicalizes CODEX_HOME).
    static func keyPath(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        guard let r = realpath(dir, nil) else { return path }
        defer { free(r) }
        return (String(cString: r) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    // MARK: - Install / uninstall (strict)

    /// Install (or update to) the current set. A file already holding exactly that set for this binary is
    /// left untouched — rewriting it would re-key nothing but still bump Codex's file watcher.
    static func install() throws {
        let before = try HooksInstaller.loadStrict(path: hooksPath)
        let after = try merged(before, exe: HooksInstaller.executablePath)
        guard !HooksInstaller.nsEqual(before, after) else {
            Log.codex.info("codex hooks already current in \(hooksPath) → left untouched")
            return
        }
        try HooksInstaller.write(after, to: hooksPath)
        Log.codex.info("installed codex hooks → \(hooksPath) (exe=\(HooksInstaller.executablePath)); Codex must now approve them")
        logShiftedForeignHooks(before: before, after: after)
    }

    /// Remove everything of ours. No write when nothing changes; an absent file is never materialized.
    static func uninstall() throws {
        let before = try HooksInstaller.loadStrict(path: hooksPath)
        let after = removed(before)
        guard !HooksInstaller.nsEqual(before, after) else {
            Log.codex.info("codex uninstall: nothing of ours in \(hooksPath) → left untouched")
            return
        }
        try HooksInstaller.write(after, to: hooksPath)
        Log.codex.info("uninstalled codex hooks → \(hooksPath)")
        logShiftedForeignHooks(before: before, after: after)
    }

    /// The pure half of `install`. On an event of the current set our entry is rewritten IN PLACE (its
    /// first entry of ours keeps its index; a first install appends), so every foreign group keeps its
    /// index — and with it Codex's trust, which is keyed by index. Our extra entries, and ours on events
    /// the current set no longer uses (an older layout, imported Claude-shaped copies), are dropped;
    /// a foreign group AFTER one of those does move up, and Codex asks to approve it again — unavoidable
    /// short of leaving placeholder groups in the user's file (`logShiftedForeignHooks` names them).
    static func merged(_ root: [String: Any], exe: String) throws -> [String: Any] {
        var hooks = try HooksInstaller.hooksObject(root, file: hooksFileName)
        let current = Dictionary(uniqueKeysWithValues: events.map { ($0.event, $0.keyword) })
        for event in Set(hooks.keys).union(current.keys) {
            var arr = try HooksInstaller.eventArray(hooks, event, file: hooksFileName)
            if let keyword = current[event] {
                let desired = entry(event: event, keyword: keyword, exe: exe)
                if let first = arr.firstIndex(where: isOurs) {
                    arr[first] = desired
                    arr = arr.enumerated().filter { $0.offset == first || !isOurs($0.element) }.map(\.element)
                } else {
                    arr.append(desired)
                }
            } else {
                arr.removeAll(where: isOurs)
            }
            if arr.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = arr }
        }
        var out = root
        out["hooks"] = hooks
        return out
    }

    /// Events whose foreign hooks changed index between two versions of the file — each of them will be
    /// "new" to Codex (trust is keyed by index) and need approving again. For the log.
    static func shiftedForeignEvents(before: [String: Any], after: [String: Any]) -> [String] {
        func foreign(_ root: [String: Any]) -> [String: [Int]] {
            let hooks = root["hooks"] as? [String: Any] ?? [:]
            return hooks.mapValues { value in
                ((value as? [[String: Any]]) ?? []).enumerated().filter { !isOurs($0.element) }.map(\.offset)
            }.filter { !$0.value.isEmpty }
        }
        let a = foreign(before), b = foreign(after)
        return a.keys.filter { a[$0] != b[$0] }.sorted()
    }

    private static func logShiftedForeignHooks(before: [String: Any], after: [String: Any]) {
        let shifted = shiftedForeignEvents(before: before, after: after)
        guard !shifted.isEmpty else { return }
        Log.codex.warn("removing our entries moved the user's own hooks on \(shifted.joined(separator: ", ")) — Codex will ask to approve those again")
    }

    /// The pure half of `uninstall`. Empty event arrays and an empty `hooks` object are dropped.
    static func removed(_ root: [String: Any]) -> [String: Any] {
        var out = root
        guard var hooks = out["hooks"] as? [String: Any] else { return out }
        for (event, value) in hooks {
            guard var arr = value as? [[String: Any]] else { continue }
            arr.removeAll(where: isOurs)
            if arr.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = arr }
        }
        if hooks.isEmpty { out.removeValue(forKey: "hooks") } else { out["hooks"] = hooks }
        return out
    }

    static func entry(event: String, keyword: String, exe: String) -> [String: Any] {
        ["hooks": [[
            "type": "command",
            "command": HooksInstaller.command(keyword: keyword, exe: exe, agent: .codex),
            "timeout": timeout(for: event),
        ]]]
    }

    /// Refresh-only self-heal, deliberately NARROWER than Claude's (`HooksInstaller.healInstalled`): every
    /// changed byte of one of our entries costs the user a fresh approval in Codex, so an entry is
    /// re-pointed at THIS binary only when the binary it names is GONE (a deleted DerivedData build, an
    /// app that moved). Two coexisting builds (Xcode's and /Applications') never churn a trusted file:
    /// whichever one the entries name keeps running, and both read the same status files.
    static func healInstalled() throws {
        var root = try HooksInstaller.loadStrict(path: hooksPath)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        let exe = HooksInstaller.executablePath
        var changed = false
        for e in events {
            guard var arr = hooks[e.event] as? [[String: Any]] else { continue }
            let desired = entry(event: e.event, keyword: e.keyword, exe: exe)
            var touched = false
            for i in arr.indices where isOurs(arr[i]) && isDangling(arr[i])
                && commands(arr[i]).contains(where: { $0.hasSuffix(" --hook \(e.keyword) --agent codex") })
                && !HooksInstaller.nsEqual(arr[i], desired) {
                arr[i] = desired
                touched = true
            }
            if touched { hooks[e.event] = arr; changed = true }
        }
        guard changed else { return }
        root["hooks"] = hooks
        try HooksInstaller.write(root, to: hooksPath)
        Log.codex.warn("self-healed codex hook commands whose binary was gone → \(exe); Codex will ask to approve them again")
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

    // MARK: - Ownership (structural + ccemaphore-anchored)

    private static func commands(_ entry: [String: Any]) -> [String] {
        (entry["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
    }

    /// A Codex-tagged command of ours, from any version: `"<path with ccemaphore>" --hook <kw> --agent codex`.
    /// The quoted-path + `ccemaphore` anchors keep a user's own command that merely mentions us safe.
    static func isOurCommand(_ cmd: String) -> Bool {
        cmd.hasPrefix("\"") && cmd.contains("ccemaphore") && cmd.contains(" --hook ") && cmd.hasSuffix(" --agent codex")
    }

    /// Ours to replace / remove: a Codex-tagged entry, or an imported Claude-shaped one of ours.
    static func isOurs(_ entry: [String: Any]) -> Bool {
        commands(entry).contains(where: isOurCommand) || HooksInstaller.isAnyOurs(entry)
    }

    private static func readLenient() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: hooksPath),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return obj
    }
}
