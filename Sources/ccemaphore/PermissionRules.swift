import Foundation

/// Decides whether Claude Code will resolve a tool call WITHOUT prompting the user — so the
/// interactive permission broker can stay out of the way (write no pending request, post no
/// notification) for calls the user never needs to see.
///
/// Why this exists: a `PreToolUse` hook fires for EVERY matched tool call, BEFORE Claude evaluates
/// its own permission rules. So the broker used to intercept (and notify about) calls Claude would
/// have auto-approved on its own — auto-accepted edits, allow-listed `Bash`, allow-listed `WebFetch`
/// — producing spurious "🔐 permission" banners. This recreates a CONSERVATIVE subset of Claude's
/// permission evaluation so the broker can skip those.
///
/// **Failure-safe by construction.** The caller reacts to a `true` verdict by emitting NOTHING from
/// the hook (exit 0, no JSON), which hands control to Claude's NATIVE permission flow. So a wrong
/// `true` is still safe — Claude re-evaluates and prompts if the call isn't really auto-approved; we
/// only ever skip OUR banner, never force-approve a call. That lets the matcher stay conservative:
/// when in doubt, return false and behave exactly as before.
///
/// Verified against the Claude Code hooks/permissions/settings docs (2026-06-30): empty hook output
/// = native evaluation; `deny`/`ask` settings rules are enforced regardless of the hook; `ask` forces
/// a prompt even over an `allow`; `permission_mode` is present in the PreToolUse payload.
enum PermissionRules {
    /// Tools that `acceptEdits` mode auto-approves (file mutations).
    private static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// True ⇢ Claude resolves this call (auto-allow OR auto-deny) without ever prompting the user.
    static func claudeWillNotPrompt(tool: String, input: Any?, permissionMode: String?, cwd: String) -> Bool {
        // Option 2 — permission mode. Auto-run modes approve EVERY tool with no prompt: `auto` (the
        // Cursor Claude Code extension's auto-run), `bypassPermissions`, `dontAsk`. `acceptEdits`
        // approves only file-edit tools (Bash/WebFetch still prompt). `plan`/`default` fall through to
        // the rule check. (Resolve the mode via `resolveMode` first — some hosts omit `permission_mode`
        // from the hook stdin, so it's recovered from the transcript.)
        switch permissionMode {
        case "auto", "bypassPermissions", "dontAsk": return true
        case "acceptEdits" where editTools.contains(tool): return true
        default: break
        }

        // Option 1 — the user's own allow/deny/ask rules, merged across all settings files. Precedence
        // (verified): a matching `deny` blocks (no prompt); a matching `ask` always prompts; otherwise
        // a matching `allow` auto-approves (no prompt). Anything unmatched → Claude prompts.
        let rules = loadMergedRules(cwd: cwd)
        if matchesAny(rules.deny, tool: tool, input: input) { return true }   // blocked → no prompt
        if matchesAny(rules.ask, tool: tool, input: input) { return false }   // forced prompt → keep broker
        return matchesAny(rules.allow, tool: tool, input: input)              // allow-listed → no prompt
    }

    // MARK: - Permission mode resolution

    /// The session's permission mode. The authoritative source is the hook payload — Claude Code's
    /// core assembles `permission_mode` into the PreToolUse stdin (we also accept a camelCase
    /// `permissionMode` defensively). Only if the payload omits it do we fall back to the transcript;
    /// that fallback is BEST-EFFORT (the mode is recorded on the user's prompt line, which a long
    /// tool-heavy turn can push arbitrarily far back), so it can return nil → caller treats it as
    /// `default` and the broker behaves as before (the safe status quo).
    static func resolveMode(payload: [String: Any], cwd: String) -> String? {
        if let m = (payload["permission_mode"] ?? payload["permissionMode"]) as? String, !m.isEmpty {
            return m
        }
        let transcriptPath = (payload["transcript_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let path = transcriptPath ?? derivedTranscriptPath(sessionId: payload["session_id"] as? String, cwd: cwd)
        return path.flatMap(latestPermissionMode)
    }

    /// `~/.claude/projects/<slug>/<sessionId>.jsonl`, where the slug is the cwd with every non-alnum
    /// character replaced by `-` (Claude Code's own project-dir encoding).
    private static func derivedTranscriptPath(sessionId: String?, cwd: String) -> String? {
        guard let sid = sessionId, !sid.isEmpty, !cwd.isEmpty else { return nil }
        let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let dir = (SessionPath.projectsRoot as NSString).appendingPathComponent(slug)
        return (dir as NSString).appendingPathComponent("\(sid).jsonl")
    }

    /// Most recent NON-NULL `permissionMode` string in the transcript (scanned newest-first). Two-stage
    /// window: the cheap default first, then a generous one — a turn's multi-MB tool_result lines can
    /// push the user-prompt line (which carries the mode) past the small window. Recent entries often
    /// carry `permissionMode: null`, so non-string values are skipped, not treated as the mode.
    static func latestPermissionMode(_ transcriptPath: String) -> String? {
        for window in [TailReader.defaultWindow, 4 * 1024 * 1024] as [UInt64] {
            for line in TailReader.tailLines(path: transcriptPath, window: window).reversed() {
                guard let data = line.data(using: .utf8),
                      let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let m = o["permissionMode"] as? String, !m.isEmpty else { continue }
                return m
            }
        }
        return nil
    }

    // MARK: - Rule sets

    struct RuleSet { var allow: [String] = []; var deny: [String] = []; var ask: [String] = [] }

    /// Read & union `permissions.{allow,deny,ask}` from every settings file Claude Code consults:
    /// enterprise-managed, project-local (`settings.local.json`), project (`settings.json`) and user
    /// (`~/.claude`). Union is correct here because `deny` is evaluated first and `ask` always prompts,
    /// so a higher-precedence override can only ever make us MORE conservative (never wrongly skip).
    static func loadMergedRules(cwd: String) -> RuleSet {
        var out = RuleSet()
        for path in settingsFiles(cwd: cwd) {
            guard let perms = readPermissions(path) else { continue }
            out.allow += perms.allow; out.deny += perms.deny; out.ask += perms.ask
        }
        return out
    }

    /// Files in Claude Code's documented precedence. `HooksInstaller.settingsPath` is reused for the
    /// user file so the `CCEMAPHORE_SETTINGS_PATH` test seam redirects this matcher too.
    private static func settingsFiles(cwd: String) -> [String] {
        var files = ["/Library/Application Support/ClaudeCode/managed-settings.json"]
        if !cwd.isEmpty {
            files.append((cwd as NSString).appendingPathComponent(".claude/settings.local.json"))
            files.append((cwd as NSString).appendingPathComponent(".claude/settings.json"))
        }
        files.append(HooksInstaller.settingsPath)   // ~/.claude/settings.json (or the test override)
        return files
    }

    private static func readPermissions(_ path: String) -> RuleSet? {
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let perms = root["permissions"] as? [String: Any] else { return nil }
        func arr(_ k: String) -> [String] { (perms[k] as? [String])?.filter { !$0.isEmpty } ?? [] }
        return RuleSet(allow: arr("allow"), deny: arr("deny"), ask: arr("ask"))
    }

    // MARK: - Matching

    private static func matchesAny(_ rules: [String], tool: String, input: Any?) -> Bool {
        rules.contains { ruleMatches($0, tool: tool, input: input) }
    }

    /// Match one `Tool` / `Tool(specifier)` rule against a tool call. Unknown shapes → no match (so the
    /// broker behaves as before). Per-tool specifiers handled precisely: `Bash` command patterns and
    /// `WebFetch` domains (the tools that actually drove the spurious-banner reports); other tools get
    /// the bare/`*` "all uses" form plus a best-effort path glob.
    static func ruleMatches(_ rule: String, tool: String, input: Any?) -> Bool {
        let (ruleTool, spec) = parseRule(rule)
        guard ruleTool == tool else { return false }
        guard let spec, spec != "*" else { return true }   // bare `Tool` or `Tool(*)` → all uses
        let dict = input as? [String: Any]
        switch tool {
        case "Bash":
            guard let cmd = dict?["command"] as? String else { return false }
            return bashMatches(spec, command: cmd)
        case "WebFetch":
            guard spec.hasPrefix("domain:"), let url = dict?["url"] as? String,
                  let host = URLComponents(string: url)?.host else { return false }
            return domainMatches(String(spec.dropFirst("domain:".count)), host: host)
        default:
            // File/other tools: best-effort glob against the path argument. Conservative — unknown
            // shapes fall through to `false`, leaving the broker's prior behavior intact.
            let path = (dict?["file_path"] as? String) ?? (dict?["notebook_path"] as? String)
            return path.map { globMatches(spec, $0) } ?? false
        }
    }

    /// `Tool` → (Tool, nil); `Tool(spec)` → (Tool, spec). Uses the FIRST `(` and trailing `)` so a
    /// specifier may itself contain parentheses.
    private static func parseRule(_ rule: String) -> (String, String?) {
        let r = rule.trimmingCharacters(in: .whitespaces)
        guard let open = r.firstIndex(of: "("), r.hasSuffix(")") else { return (r, nil) }
        let tool = String(r[r.startIndex..<open])
        let spec = String(r[r.index(after: open)..<r.index(before: r.endIndex)])
        return (tool, spec)
    }

    // MARK: Bash

    /// A Bash command is auto-approved by ONE rule only if EVERY sub-command (split on shell control
    /// operators) matches that rule's pattern — mirroring Claude's "all sub-commands must be allowed".
    /// So `find . | rm -rf x` is NOT matched by `Bash(find:*)` alone.
    static func bashMatches(_ spec: String, command: String) -> Bool {
        let subs = subcommands(of: command)
        guard !subs.isEmpty else { return false }
        return subs.allSatisfy { bashPattern(spec, matches: $0) }
    }

    private static func subcommands(of command: String) -> [String] {
        var parts = [command]
        for sep in ["&&", "||", ";", "|", "\n"] {   // not bare `&` — it would split `2>&1`/redirections
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Match one Bash pattern against one (sub)command. Handles the boundary-prefix forms `p:*` and
    /// `p *` (command is `p` exactly, or starts with `p ` + anything), the raw-prefix/mid-string `*`
    /// glob, and exact match. Conservative: anything we can't confidently match → false.
    private static func bashPattern(_ pattern: String, matches command: String) -> Bool {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        if pattern == "*" { return true }
        for suffix in [":*", " *"] where pattern.hasSuffix(suffix) {
            let p = String(pattern.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            return !p.isEmpty && (cmd == p || cmd.hasPrefix(p + " "))
        }
        if pattern.contains("*") { return globMatches(pattern, cmd) }
        return cmd == pattern
    }

    // MARK: WebFetch

    /// Match a `domain:` spec against a hostname. Supports `*` (any), `*.host` (any subdomain, but not
    /// the bare apex), `host.*` (exactly one trailing label) and exact. Case-insensitive; trailing dots
    /// ignored.
    static func domainMatches(_ spec: String, host: String) -> Bool {
        let dots = CharacterSet(charactersIn: " .")
        let s = spec.lowercased().trimmingCharacters(in: .whitespaces)
        let h = host.lowercased().trimmingCharacters(in: dots)
        if s == "*" { return true }
        if s.hasPrefix("*.") { return h.hasSuffix("." + String(s.dropFirst(2))) }
        if s.hasSuffix(".*") {
            let prefix = String(s.dropLast(2))
            guard !prefix.isEmpty, h.hasPrefix(prefix + ".") else { return false }
            return !h.dropFirst(prefix.count + 1).contains(".")
        }
        let exact = s.trimmingCharacters(in: dots)
        return !exact.isEmpty && h == exact
    }

    // MARK: Glob

    /// Minimal glob: `*` matches any run of characters (no path-segment semantics). A best-effort
    /// fallback for file patterns and `*`-bearing Bash patterns; anchored full-string match.
    static func globMatches(_ pattern: String, _ string: String) -> Bool {
        let body = pattern.components(separatedBy: "*")
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: ".*")
        guard let re = try? NSRegularExpression(pattern: "^" + body + "$", options: [.dotMatchesLineSeparators])
        else { return false }
        return re.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }
}

/// User-curated list of tool calls ccemaphore auto-approves via its OWN permission hook, so they
/// never raise Cursor's native dialog OR our ribbon — the "auto-allow trusted commands" feature.
///
/// Distinct from the per-session "Allow all in this chat" (`PermissionBroker` allow-all memory): a
/// trusted entry persists across ALL chats and is scoped to a tool + command pattern. It solves the
/// recurring case where the same command (e.g. a build) keeps prompting: mark it trusted once and it
/// stops asking — and because our hook returns `allow`, the tool runs with NO native Cursor dialog and
/// NO ribbon (verified live: Cursor's extension log shows our `permissionDecision: allow` suppresses
/// the dialog — see memory/permission-resume-signal.md).
///
/// **Safety.** A trusted entry is a REAL auto-approval, exactly like a Claude `permissions.allow` rule
/// or "Allow all" — it only ever runs commands the user explicitly blessed. Matching is deliberately
/// TIGHTER than a raw substring, so a trusted fragment can't smuggle a chained command through:
///   • Bash — the command is split on `&&`/`||`/`;`/newline (NOT `|`: a pipeline is one command) and
///     EVERY resulting segment must contain the pattern; pure `VAR=…` assignment segments are exempt.
///     So trusting `xcodebuild` covers `DD=$(mktemp -d)` ⏎ `xcodebuild … | tail` but NOT
///     `xcodebuild && rm -rf ~` (the `rm` segment lacks the pattern → not trusted).
///   • WebFetch — the pattern is matched against the URL HOST via `PermissionRules.domainMatches`
///     (anchored), so `example.com` does not match `evil.com/?x=example.com` or `example.com.evil.net`.
///   • other tools — a case-sensitive substring of the file path.
/// An empty pattern trusts every use of that tool (a concrete tool is then required — the
/// "any tool + any use" catch-all is refused at BOTH write time AND match time). Claude Code still
/// enforces any `deny`/`ask` rule regardless of our hook, so a trusted entry can never bypass a user deny.
///
/// Stored as JSON at `<baseDir>/trusted.json` (honors `CCEMAPHORE_BASE_DIR`) — written ONLY by the GUI,
/// read by the short-lived hook on every invocation, so edits take effect immediately (no watcher).
enum TrustedCommands {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        /// Tool this applies to ("Bash", "WebFetch", …). Empty = any tool.
        var tool: String
        /// Case-sensitive substring the call must contain (command / url / path). Empty = any use of `tool`.
        var pattern: String
        /// Stable identity for SwiftUI (tool + pattern are unique together; `add` dedupes).
        var id: String { "\(tool)\u{1}\(pattern)" }
    }

    private struct Store: Codable { var version: Int; var entries: [Entry] }

    static var path: String {
        (PermissionBroker.baseDir as NSString).appendingPathComponent("trusted.json")
    }

    // MARK: - Load / mutate (GUI writes; hook reads)

    static func load() -> [Entry] {
        guard let data = FileManager.default.contents(atPath: path),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return [] }
        return store.entries
    }

    @discardableResult
    private static func save(_ entries: [Entry]) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Store(version: 1, entries: entries)) else { return false }
        do { try data.write(to: URL(fileURLWithPath: path), options: [.atomic]); return true }
        catch { Log.permissions.warn("trusted.json write failed: \(error.localizedDescription)"); return false }
    }

    /// Add an entry (deduped), returning the new list. Refuses the "trust everything" entry
    /// (empty pattern AND no concrete tool) — that would silence all prompts.
    @discardableResult
    static func add(tool: String, pattern: String) -> [Entry] {
        let t = tool.trimmingCharacters(in: .whitespaces)
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty || (!t.isEmpty && t != "*") else { return load() }
        var entries = load()
        let entry = Entry(tool: (t == "*" ? "" : t), pattern: p)
        if !entries.contains(entry) { entries.append(entry); save(entries) }
        return entries
    }

    @discardableResult
    static func remove(_ entry: Entry) -> [Entry] {
        var entries = load()
        entries.removeAll { $0 == entry }
        save(entries)
        return entries
    }

    // MARK: - Matching (hook side)

    /// True ⇢ this tool call matches a trusted entry, so the hook should auto-allow it.
    static func isTrusted(tool: String, input: Any?) -> Bool {
        let entries = load()
        guard !entries.isEmpty else { return false }
        return entries.contains { e in
            // Defense in depth: NEVER honor a fully-empty catch-all entry, even if one reached the file
            // via a hand-edit / version drift / corruption. (`add` already refuses to write it.)
            guard !(e.tool.isEmpty && e.pattern.isEmpty) else { return false }
            guard e.tool.isEmpty || e.tool == tool else { return false }
            guard !e.pattern.isEmpty else { return true }   // concrete-tool + empty pattern = whole-tool trust
            return matches(tool: tool, pattern: e.pattern, input: input)
        }
    }

    /// Per-tool pattern match (see the type doc for the exact, deliberately-tight semantics).
    private static func matches(tool: String, pattern: String, input: Any?) -> Bool {
        let dict = input as? [String: Any]
        switch tool {
        case "Bash":
            guard let cmd = dict?["command"] as? String else { return false }
            return bashTrusted(pattern: pattern, command: cmd)
        case "WebFetch":
            // Anchor on the parsed HOST, not a raw substring of the whole URL — else "example.com"
            // would match `evil.com/?x=example.com` or `example.com.attacker.net`.
            guard let url = dict?["url"] as? String,
                  let host = URLComponents(string: url)?.host else { return false }
            return PermissionRules.domainMatches(pattern, host: host)
        default:
            let path = (dict?["file_path"] as? String) ?? (dict?["notebook_path"] as? String) ?? ""
            return !path.isEmpty && path.contains(pattern)
        }
    }

    /// A Bash command is trusted iff EVERY chained sub-command contains the pattern. Split on the
    /// command-chaining operators (`&&`/`||`/`;`/newline) but NOT `|` — a pipeline is one logical command
    /// (`build … | tail`), whereas `&&`/`;`/`||` introduce independent commands. Pure `VAR=value`
    /// assignment segments (setup like `DD="$(mktemp -d)"`) are exempt. This blocks a trusted prefix from
    /// auto-approving an unrelated command tacked on after it, while still covering real build lines.
    private static func bashTrusted(pattern: String, command: String) -> Bool {
        var segs = [command]
        for sep in ["&&", "||", ";", "\n"] { segs = segs.flatMap { $0.components(separatedBy: sep) } }
        let commands = segs
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isPureAssignment($0) }
        // Require at least one real command (all-assignments trusts nothing) and every one to contain it.
        return !commands.isEmpty && commands.allSatisfy { $0.contains(pattern) }
    }

    /// True for a segment that is only a `NAME=value` shell assignment (no command follows) — the `=`
    /// is preceded solely by a valid identifier. Conservative: anything with a space/command before the
    /// first `=` (e.g. `CODE_SIGNING_ALLOWED=NO` inside an `xcodebuild …` invocation) is NOT an assignment.
    private static func isPureAssignment(_ segment: String) -> Bool {
        guard let eq = segment.firstIndex(of: "=") else { return false }
        let name = segment[segment.startIndex..<eq]
        return !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: - Diagnostic (`ccemaphore --trusted-dump`)

    static func dump() {
        let entries = load()
        print("trusted.json (\(path))")
        guard !entries.isEmpty else { print("  (no trusted commands)"); return }
        for e in entries {
            let tool = e.tool.isEmpty ? "*" : e.tool
            let pat = e.pattern.isEmpty ? "(any use)" : "contains \"\(e.pattern)\""
            print("  \(tool)  \(pat)")
        }
    }
}
