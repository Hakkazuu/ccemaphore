import Foundation

/// Installs/removes ccemaphore's hooks in ~/.claude/settings.json (user scope → all projects).
///
/// Safety is the whole point of this file — it edits the user's real, shared Claude Code config:
///  - It NEVER writes unless it parsed the existing file cleanly. A present-but-unparseable
///    settings.json (mid-edit, a bad hand-edit) makes install/uninstall THROW instead of clobbering;
///    an unexpected shape under a key we touch also throws rather than dropping the user's data.
///  - Writes are atomic (temp file + rename), so a crash or power loss can't leave a half-written file.
///  - It merges only its own entries (matched structurally and anchored to ccemaphore), never rewrites
///    the whole file, and removes only what it added. Every other key is preserved verbatim.
enum HooksInstaller {
    /// (Claude Code event, our `--hook` keyword, whether the event uses a tool matcher).
    static let events: [(event: String, keyword: String, matcher: Bool)] = [
        ("SessionStart", "start", false),
        ("SessionEnd", "end", false),
        ("UserPromptSubmit", "prompt", false),
        ("PreToolUse", "pre", true),
        ("PostToolUse", "post", true),
        ("Stop", "stop", false),
        ("Notification", "notify", false),
        ("PreCompact", "precompact", false),
    ]

    /// Keywords used by the basic (status/notify) hooks — never "permission" (the opt-in broker).
    private static let basicKeywords = ["start", "end", "prompt", "pre", "post", "stop", "notify", "precompact"]

    /// Basic events introduced AFTER the original install set. These are back-filled into an existing
    /// install by `healInstalled` so users get the new signal on next launch without re-toggling. ONLY
    /// these — not the whole `events` list: an event's absence here means "old install predating it", not
    /// "user deliberately removed it", so back-filling can't resurrect a hook the user chose to drop
    /// (which `healInstalled` must never do). `PostToolUse` lets the broker learn a permission was
    /// resolved in Cursor's own dialog the instant the approved tool finishes, instead of hanging until
    /// the next unrelated hook. See docs/permission-and-waiting-fixes-plan.md (bug #2).
    private static let migratableAdditions: Set<String> = ["PreCompact", "PostToolUse"]

    /// Matcher for the `PermissionRequest` hook. EMPTY = all tools — correct here because
    /// PermissionRequest fires ONLY when Claude actually shows a permission dialog, so matching
    /// everything has zero false positives and, crucially, also catches `WebSearch`, `Task`,
    /// `ExitPlanMode` and `mcp__*` tools. The old narrow `Bash|Edit|…` list silently missed those: a
    /// WebSearch prompt fired no hook → no notification, no red, light stayed yellow. (This is the same
    /// "" convention the basic `pre` PreToolUse entry uses to match every tool.)
    private static let permissionMatcher = ""

    /// Why a mutation was refused. Surfaced to the user instead of silently corrupting their file.
    enum HookError: LocalizedError {
        case unparseableSettings(String)
        case unexpectedShape(String)

        var errorDescription: String? {
            switch self {
            case .unparseableSettings(let path):
                return Lf("error.settings.unparseable", path)
            case .unexpectedShape(let what):
                return Lf("error.settings.unexpectedShape", what)
            }
        }
    }

    static var settingsPath: String {
        // Test seam: point at a throwaway file to verify merge/uninstall without touching real settings.
        if let p = ProcessInfo.processInfo.environment["CCEMAPHORE_SETTINGS_PATH"], !p.isEmpty { return p }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
    }

    /// Absolute path to this binary — the hook command target. Quoted + escaped at use.
    static var executablePath: String {
        if let p = Bundle.main.executableURL?.path { return p }
        let arg0 = CommandLine.arguments.first ?? "ccemaphore"
        return arg0.hasPrefix("/") ? arg0 : FileManager.default.currentDirectoryPath + "/" + arg0
    }

    // MARK: - Status (read-only; safe to be lenient)

    static func isInstalled() -> Bool {
        guard let hooks = readSettingsLenient()["hooks"] as? [String: Any] else { return false }
        return events.contains { e in
            (hooks[e.event] as? [[String: Any]])?.contains(where: isOurBasic) ?? false
        }
    }

    static func isPermissionHookInstalled() -> Bool {
        let hooks = readSettingsLenient()["hooks"] as? [String: Any]
        if let arr = hooks?["PermissionRequest"] as? [[String: Any]], arr.contains(where: isPermissionEntry) {
            return true
        }
        // Legacy installs (pre-migration) still count as "on"; healInstalled migrates them on next launch.
        if let arr = hooks?["PreToolUse"] as? [[String: Any]], arr.contains(where: isLegacyPermissionEntry) {
            return true
        }
        return false
    }

    // MARK: - Install / uninstall (mutating; strict — abort rather than risk the file)

    static func install() throws {
        let root = try mergeInstall(root: try loadSettingsStrict(), exe: executablePath)
        try writeSettings(root)
        Log.settings.info("installed basic hooks → \(settingsPath) (exe=\(executablePath))")
    }

    static func installPermissionHook() throws {
        let root = try mergeInstallPermission(root: try loadSettingsStrict(), exe: executablePath)
        try writeSettings(root)
        Log.settings.info("installed PermissionRequest hook → \(settingsPath)")
    }

    // MARK: - Transport-agnostic merge (pure — no IO). Shared with `RemoteHooksInstaller`, which reads/
    // writes the SAME `~/.claude/settings.json` shape over SSH instead of the local filesystem; `exe` is
    // whatever path the hook should invoke (local binary path here, the remote shim path there).

    static func mergeInstall(root: [String: Any], exe: String) throws -> [String: Any] {
        var root = root
        var hooks = try hooksObject(root)
        for e in events {
            var arr = try eventArray(hooks, e.event)
            arr.removeAll(where: isOurBasic)                   // idempotent; leaves permission entry intact
            arr.append(entry(keyword: e.keyword, matcher: e.matcher, exe: exe))
            hooks[e.event] = arr
        }
        root["hooks"] = hooks
        return root
    }

    static func mergeInstallPermission(root: [String: Any], exe: String) throws -> [String: Any] {
        var root = root
        var hooks = try hooksObject(root)
        // Migrate away any legacy PreToolUse front-run entry we used to install (keeps the basic `pre`).
        var pre = try eventArray(hooks, "PreToolUse")
        if pre.contains(where: isLegacyPermissionEntry) {
            pre.removeAll(where: isLegacyPermissionEntry)
            if pre.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else { hooks["PreToolUse"] = pre }
        }
        var arr = try eventArray(hooks, "PermissionRequest")
        arr.removeAll(where: isPermissionEntry)
        arr.append(permissionEntry(exe: exe))
        hooks["PermissionRequest"] = arr
        root["hooks"] = hooks
        return root
    }

    static func mergeUninstall(root: [String: Any]) throws -> [String: Any] {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for event in Set(events.map(\.event) + ["PreToolUse", "PermissionRequest"]) {
            guard var arr = hooks[event] as? [[String: Any]] else { continue }   // preserve unknown shapes
            arr.removeAll(where: isAnyOurs)
            if arr.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = arr }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return root
    }

    static func isAnyInstalled(root: [String: Any]) -> Bool {
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.contains { e in
            (hooks[e.event] as? [[String: Any]])?.contains(where: isOurBasic) ?? false
        }
    }

    /// The interactive permission entry we own — the `PermissionRequest` hook, which fires precisely when
    /// Claude shows a permission dialog. `timeout` here is Claude Code's outer kill-deadline; the hook's
    /// actual wait is the (shorter) `Tuning.permissionPollTimeout`, so this must stay above it.
    static func permissionEntry(exe: String) -> [String: Any] {
        ["matcher": permissionMatcher, "hooks": [[
            "type": "command",
            "command": command(keyword: "permission-request", exe: exe),
            "timeout": 300,
        ]]]
    }

    static func uninstallPermissionHook() throws {
        var root = try loadSettingsStrict()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        if var arr = hooks["PermissionRequest"] as? [[String: Any]] {
            arr.removeAll(where: isPermissionEntry)
            if arr.isEmpty { hooks.removeValue(forKey: "PermissionRequest") } else { hooks["PermissionRequest"] = arr }
        }
        if var arr = hooks["PreToolUse"] as? [[String: Any]] {   // also clear any legacy front-run entry
            arr.removeAll(where: isLegacyPermissionEntry)
            if arr.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else { hooks["PreToolUse"] = arr }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try writeSettings(root)
        Log.settings.info("removed permission hook → \(settingsPath)")
    }

    /// Full removal of everything ccemaphore added (basic + permission). No-write guard: if there is
    /// nothing of ours to remove (no ccemaphore entries, or no file at all), leave the file exactly as-is
    /// instead of re-serializing it — an absent settings.json must NOT be materialized as `{}`, and a file
    /// with no hooks of ours must NOT be reformatted.
    static func uninstall() throws {
        let before = try loadSettingsStrict()
        let after = try mergeUninstall(root: before)
        guard !nsEqual(before, after) else {
            Log.settings.info("uninstall: nothing of ours in \(settingsPath) → left untouched")
            return
        }
        try writeSettings(after)
        Log.settings.info("uninstalled all hooks → \(settingsPath)")
    }

    // MARK: - Self-heal (refresh-only) — keep our entries pointed at the CURRENT binary

    /// Refresh the hook entries we ALREADY own so their command (absolute binary path,
    /// timeout, matcher) matches this build — e.g. after the app moves from a DerivedData build to
    /// /Applications, where the baked-in path would otherwise dangle and silently break the hooks.
    ///
    /// Strictly refresh-only: it never re-adds an entry the user removed, and it writes nothing when
    /// everything already matches (so it can run on every launch without churning settings.json). Like
    /// install/uninstall it loads STRICT and throws rather than clobber an unparseable file.
    static func healInstalled() throws {
        var root = try loadSettingsStrict()
        var changed = false
        let exe = executablePath

        if var hooks = root["hooks"] as? [String: Any] {
            for e in events {
                guard var arr = hooks[e.event] as? [[String: Any]] else { continue }
                let desired = entry(keyword: e.keyword, matcher: e.matcher, exe: exe)
                var touched = false
                for i in arr.indices where isOurBasic(arr[i]) && !nsEqual(arr[i], desired) {
                    arr[i] = desired
                    touched = true
                }
                if touched { hooks[e.event] = arr; changed = true }
            }
            // Migration/back-fill: basic events we introduced AFTER the original hook set (see
            // `migratableAdditions` — PreCompact, PostToolUse) are completed into an existing install so
            // users get the new signal on next launch without re-toggling — same spirit as the
            // permission-hook migration below. Gated on basic-hooks-present, so it never installs into a
            // config the user never opted into; idempotent (skips events already present). Restricting to
            // `migratableAdditions` (not the whole `events` list) is what keeps this from resurrecting a
            // basic hook the user deliberately removed.
            let basicInstalled = events.contains { e in
                (hooks[e.event] as? [[String: Any]])?.contains(where: isOurBasic) ?? false
            }
            if basicInstalled {
                for e in events where migratableAdditions.contains(e.event) {
                    var arr = hooks[e.event] as? [[String: Any]] ?? []
                    guard !arr.contains(where: isOurBasic) else { continue }
                    arr.append(entry(keyword: e.keyword, matcher: e.matcher, exe: exe))
                    hooks[e.event] = arr
                    changed = true
                    Log.settings.info("added \(e.event) hook to existing install (migration)")
                }
            }
            // Migrate the legacy PreToolUse front-run entry to the precise PermissionRequest event. This
            // is our OWN entry moved to its current shape (same spirit as the binary-path self-heal), so
            // existing users get the fix on next launch without re-toggling — never re-adds a removed one.
            if var pre = hooks["PreToolUse"] as? [[String: Any]], pre.contains(where: isLegacyPermissionEntry) {
                pre.removeAll(where: isLegacyPermissionEntry)
                if pre.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else { hooks["PreToolUse"] = pre }
                var pr = hooks["PermissionRequest"] as? [[String: Any]] ?? []
                if !pr.contains(where: isPermissionEntry) { pr.append(permissionEntry(exe: exe)) }
                hooks["PermissionRequest"] = pr
                changed = true
                Log.settings.info("migrated legacy PreToolUse permission hook → PermissionRequest")
            }
            // Refresh our PermissionRequest entry (binary path / timeout / matcher) to match this build.
            if var arr = hooks["PermissionRequest"] as? [[String: Any]] {
                let desired = permissionEntry(exe: exe)
                var touched = false
                for i in arr.indices where isPermissionEntry(arr[i]) && !nsEqual(arr[i], desired) {
                    arr[i] = desired
                    touched = true
                }
                if touched { hooks["PermissionRequest"] = arr; changed = true }
            }
            if changed { root["hooks"] = hooks }
        }

        if changed {
            try writeSettings(root)
            Log.settings.info("self-healed hook commands → \(exe)")
        }
    }

    /// Deep value-equality for our JSON-derived dictionaries (handles nested arrays + NSNumber). Internal
    /// so `RemoteHooksInstaller` can share the "nothing changed → don't rewrite" guard.
    static func nsEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        (a as NSDictionary).isEqual(to: b)
    }

    // MARK: - Entry construction

    static func entry(keyword: String, matcher: Bool, exe: String) -> [String: Any] {
        let hook: [String: Any] = [
            "type": "command",
            "command": command(keyword: keyword, exe: exe),
            "timeout": 10,
        ]
        var entry: [String: Any] = ["hooks": [hook]]
        if matcher { entry["matcher"] = "" }   // empty matcher = all tools
        return entry
    }

    /// `"<escaped-exe>" --hook <keyword>` — the exact command we own. Quoted + escaped for /bin/sh.
    static func command(keyword: String, exe: String) -> String {
        "\(shQuote(exe)) --hook \(keyword)"
    }

    /// Wrap a path in double quotes and escape the characters still special inside "" for /bin/sh.
    /// Backslash first so we don't double-escape the escapes we add.
    static func shQuote(_ path: String) -> String {
        var s = path
        for (from, to) in [("\\", "\\\\"), ("\"", "\\\""), ("`", "\\`"), ("$", "\\$")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return "\"\(s)\""
    }

    // MARK: - Ownership predicates (structural + ccemaphore-anchored → never delete a user's entry)

    private static func commands(_ entry: [String: Any]) -> [String] {
        (entry["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
    }
    /// Our basic entry: a quoted-path invocation referencing ccemaphore that ends in one of OUR basic
    /// `--hook <kw>` keywords. The structural match stops us deleting a user command that merely
    /// mentions "ccemaphore"; the ccemaphore anchor stops us deleting an unrelated `"x" --hook stop`.
    static func isOurBasic(_ entry: [String: Any]) -> Bool {
        commands(entry).contains { cmd in
            cmd.hasPrefix("\"") && cmd.contains("ccemaphore")
                && basicKeywords.contains { cmd.hasSuffix(" --hook \($0)") }
        }
    }
    /// Our current permission entry: the `PermissionRequest` hook (`--hook permission-request`).
    static func isPermissionEntry(_ entry: [String: Any]) -> Bool {
        commands(entry).contains {
            $0.hasPrefix("\"") && $0.contains("ccemaphore") && $0.hasSuffix(" --hook permission-request")
        }
    }
    /// The legacy permission entry: the old `PreToolUse` front-run (`--hook permission`). Recognized only
    /// so install/uninstall/heal can migrate or remove it; it is never re-added. The ` --hook permission`
    /// suffix can't collide with ` --hook permission-request` (different trailing text).
    static func isLegacyPermissionEntry(_ entry: [String: Any]) -> Bool {
        commands(entry).contains {
            $0.hasPrefix("\"") && $0.contains("ccemaphore") && $0.hasSuffix(" --hook permission")
        }
    }
    static func isAnyOurs(_ entry: [String: Any]) -> Bool {
        isOurBasic(entry) || isPermissionEntry(entry) || isLegacyPermissionEntry(entry)
    }

    // MARK: - IO

    /// Lenient read for status checks: any problem → empty (reports "not installed", never throws).
    static func readSettingsLenient() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return obj
    }

    /// Strict read for mutation. Distinguishes "file absent" (ok → start fresh) from "file present but
    /// unparseable / wrong root type" (throw — never overwrite a file we couldn't understand).
    private static func loadSettingsStrict() throws -> [String: Any] {
        try parseSettingsStrict(data: FileManager.default.contents(atPath: settingsPath), path: settingsPath)
    }

    /// Transport-free strict parse — the pure half of `loadSettingsStrict`, SHARED with
    /// `RemoteHooksInstaller` (which supplies bytes read over SSH). nil/empty → `[:]` (absent → start
    /// fresh); unparseable / non-object root → throw (never overwrite a file we couldn't understand).
    static func parseSettingsStrict(data: Data?, path: String) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw HookError.unparseableSettings(path)
        }
        guard let dict = obj as? [String: Any] else {
            throw HookError.unexpectedShape(L("shape.rootNotObject"))
        }
        return dict
    }

    /// Transport-free strict encode — the pure half of `writeSettings`, SHARED with
    /// `RemoteHooksInstaller`. Same options on both sides so local and remote settings.json stay identical.
    static func encodeSettings(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func hooksObject(_ root: [String: Any]) throws -> [String: Any] {
        guard let v = root["hooks"] else { return [:] }
        guard let dict = v as? [String: Any] else { throw HookError.unexpectedShape(L("shape.hooksNotObject")) }
        return dict
    }

    static func eventArray(_ hooks: [String: Any], _ event: String) throws -> [[String: Any]] {
        guard let v = hooks[event] else { return [] }
        guard let arr = v as? [[String: Any]] else {
            throw HookError.unexpectedShape(Lf("shape.eventNotArray", event))
        }
        return arr
    }

    private static func writeSettings(_ root: [String: Any]) throws {
        let dir = (settingsPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try encodeSettings(root)
        // Atomic: writes to a temp file and renames into place, so a crash can't truncate the file.
        try data.write(to: URL(fileURLWithPath: settingsPath), options: [.atomic])
    }
}
