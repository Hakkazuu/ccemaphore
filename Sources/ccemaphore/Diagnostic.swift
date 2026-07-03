import Foundation

/// `ccemaphore --scan` — run a single classification pass over ~/.claude/projects and print the
/// result to stdout, then exit. No GUI. Useful for debugging the heuristic and for CI smoke tests.
enum Diagnostic {
    /// `ccemaphore --probe <file.jsonl>` — dump the per-stage results of the heuristic for one file.
    static func probe(_ path: String) {
        let lines = TailReader.tailLines(path: path)
        let parsed = lines.compactMap(LogLine.decode)
        let real = parsed.filter { ($0.type == "assistant" || $0.type == "user") && $0.timestamp != nil }
        print("tail complete lines: \(lines.count)")
        print("decoded LogLines:    \(parsed.count)")
        print("real lines (a/u+ts): \(real.count)")
        let typeCounts = Dictionary(grouping: parsed, by: { $0.type ?? "nil" }).mapValues(\.count)
        print("types: \(typeCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        if let last = real.last {
            print("last real: type=\(last.type ?? "?") role=\(last.message?.role ?? "?") stop=\(last.message?.stopReason ?? "nil")")
            print("last real timestamp string: \(last.timestamp ?? "nil")")
            let ms = ISO8601DateFormatter(); ms.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
            let parsedDate = last.timestamp.flatMap { ms.date(from: $0) ?? plain.date(from: $0) }
            print("parsed Date: \(parsedDate.map(String.init(describing:)) ?? "FAILED TO PARSE")")
            if let d = parsedDate { print("age: \(Int(Date().timeIntervalSince(d)))s") }
        } else {
            print("NO real lines found — sample of last 3 decoded line types:")
            for l in parsed.suffix(3) { print("  type=\(l.type ?? "nil") ts=\(l.timestamp ?? "nil")") }
        }
    }

    /// `ccemaphore --l10n-check` — print localized samples (incl. plurals + dates) for every shipped
    /// language, so string resolution can be verified headlessly without launching the GUI. Uses an
    /// in-memory override, so it never touches the user's saved language preference.
    static func l10nCheck() {
        let sampleKeys = [
            "menu.quit", "popover.noActiveSessions", "settings.hooks.title",
            "settings.permission.subtitle.off", "perm.allInChat", "history.title", "reset.done",
            "status.compacting", "settings.trusted.section", "settings.trusted.empty",
            "panel.claudeMissing",
        ]
        defer { Loc.setOverride(nil) }
        for code in Loc.supported {
            Loc.setOverride(code)
            let missing = L("menu.quit") == "menu.quit"
            print("\n=== \(code)\(missing ? "   [!! strings NOT found in bundle]" : "") ===")
            for k in sampleKeys { print("  \(k) = \(L(k))") }
            print("  count.working(3) = \(Lf("count.working", 3))")
            for n in [1, 2, 5, 21, 22] {
                print("  chats(\(n)) = \(Lcount("noun.chats", n))   days(\(n)) = \(Lcount("noun.days", n))   retention=\(Lcount("noun.daysShort", n))")
            }
            print("  dayFull(2026-06-30) = \(Fmt.dayFull("2026-06-30"))")
            print("  resetIn(+4h19m) = \(Fmt.resetIn(Date().addingTimeInterval(4 * 3600 + 19 * 60)))")
        }
    }

    /// `ccemaphore --check-perm` — read a PreToolUse-shaped JSON payload from stdin and print whether
    /// the permission broker would SKIP it (Claude auto-resolves → no notification) and which rule
    /// matched. Lets the auto-approve matcher be verified headlessly, without the GUI or a live Claude
    /// session. Example:
    ///   echo '{"tool_name":"Bash","tool_input":{"command":"find . -name x"},"cwd":"/p","permission_mode":"default"}' \
    ///     | ccemaphore --check-perm
    static func checkPermission() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let tool = json["tool_name"] as? String ?? "?"
        let cwd = json["cwd"] as? String ?? ""
        let input = json["tool_input"]
        let mode = PermissionRules.resolveMode(payload: json, cwd: cwd)
        let rules = PermissionRules.loadMergedRules(cwd: cwd)

        print("tool=\(tool)  mode=\(mode ?? "default")  cwd=\(cwd.isEmpty ? "-" : cwd)")
        print("merged rules: allow=\(rules.allow.count) deny=\(rules.deny.count) ask=\(rules.ask.count)")
        for (label, set) in [("deny", rules.deny), ("ask", rules.ask), ("allow", rules.allow)] {
            let hits = set.filter { PermissionRules.ruleMatches($0, tool: tool, input: input) }
            if !hits.isEmpty { print("  matched \(label): \(hits.joined(separator: ", "))") }
        }
        let trusted = TrustedCommands.isTrusted(tool: tool, input: input)
        if trusted { print("  trusted-commands: MATCH → hook returns allow (no dialog, no ribbon)") }
        let skip = PermissionRules.claudeWillNotPrompt(tool: tool, input: input, permissionMode: mode, cwd: cwd)
        let verdict: String
        if trusted { verdict = "AUTO-ALLOW — trusted command (hook emits allow)" }
        else if skip { verdict = "SKIP broker — no notification (Claude auto-resolves)" }
        else { verdict = "SHOW broker — interactive permission" }
        print("verdict: \(verdict)")
    }

    /// `ccemaphore --perm-diag` — print the raw stdin payload captured the last time each permission
    /// hook event fired (PreToolUse / PermissionRequest). Confirms a host (Cursor, terminal…) actually
    /// delivers the event, and shows its exact field shape. "(never fired)" ⇒ no capture yet.
    static func permDiag() {
        for event in ["PreToolUse", "PermissionRequest"] {
            let path = (PermissionBroker.diagDir as NSString).appendingPathComponent("permission-\(event).json")
            print("\n=== \(event)  (\(path)) ===")
            guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
                print("  (never fired — no capture)")
                continue
            }
            if let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                print("  captured \(Int(Date().timeIntervalSince(mtime)))s ago")
            }
            if let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let s = String(data: pretty, encoding: .utf8) {
                print(s)
            } else {
                print(String(data: data, encoding: .utf8) ?? "  (unreadable)")
            }
        }
    }

    /// Async so the entry point can drive it with structured concurrency (no semaphore/box bridge).
    static func run() async {
        let store = SessionStore()
        let usage = UsageProvider()
        let paths = SessionPath.enumerateTranscripts()

        let sessions = await store.ingest(paths: paths, now: Date())
        await usage.refresh()
        let usageBySession = await usage.bySession
        let days = await usage.days

        let now = Date()
        print("scanned \(paths.count) *.jsonl files under \(SessionPath.projectsRoot)")
        print("aggregate: \(aggregate(sessions).rawValue)")
        print("live sessions: \(sessions.count)")
        for s in sessions {
            let age = Int(now.timeIntervalSince(s.lastActivity))
            let branch = s.gitBranch ?? "-"
            let u = usageBySession[s.id]
            let tok = u.map { "  tokens=\($0.totalTokens) $\(String(format: "%.2f", $0.costUsd))" } ?? "  tokens=?(no ccusage match)"
            let label = s.isCompacting ? "compact" : s.state.rawValue
            print("  [\(label.padding(toLength: 7, withPad: " ", startingAt: 0))] "
                  + "\(s.displayName)  age=\(age)s  id=\(s.id.prefix(8))\(tok)")
        }
        print("\ndaily history (\(days.count) days):")
        for d in days.prefix(5) {
            print("  \(d.date)  chats=\(d.chatCount)  tokens=\(d.totalTokens)  $\(String(format: "%.2f", d.costUsd))")
        }
    }
}
