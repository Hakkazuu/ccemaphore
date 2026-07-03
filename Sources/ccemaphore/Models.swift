import Foundation

/// Single source of truth for the liveness/refresh tuning constants. Mode A (SessionStore) and
/// mode B (StateEngine status-overlay aging) must agree on what "live" means, so they share these
/// rather than each hard-coding a literal that can silently drift apart.
enum Tuning {
    static let activeWindow: TimeInterval = 60       // recency for "working"
    static let staleWindow: TimeInterval = 30 * 60   // drop from the traffic light entirely
    static let stateTick: TimeInterval = 5           // re-derive states as windows elapse
    static let usageRefresh: TimeInterval = 45       // ccusage cadence (expensive — keep slow)
    /// Keep a parent chat "working" this long after its last sub-agent / workflow transcript write.
    /// Wider than `activeWindow` because sub-agents (and workflow fan-outs) go silent mid-task between
    /// stages; without the slack the chat would briefly flip to "done" while real work continues.
    static let subagentGrace: TimeInterval = 120
    /// How long a workflow stays "live" after its last fan-out-agent write WITHOUT a completion record —
    /// a backstop for a run hard-killed before it could write `wf_*.json`, so it can't pin the chat
    /// yellow forever. Graceful finishes are retired instantly by the record, so this only has to span a
    /// single long, silent sub-agent (e.g. a multi-minute build/test).
    static let workflowLiveWindow: TimeInterval = 240
    /// Interactive permission broker (mode B). How long the blocking permission handler waits for the
    /// user before handing the request to Claude's own prompt. MUST stay < the hook's settings.json
    /// timeout (300), so the loop hands off cleanly before Claude SIGKILLs it. Applies ONLY when the
    /// widget is VISIBLE — the ribbon is then on screen the whole time (not a transient popover), so the
    /// [Allow]/[Deny]/[All] buttons stay live and useful for the "stepped away a few minutes" case
    /// (widget hidden → `AppPresence.waitWindow` returns 0: no on-screen surface, hand off at once). This
    /// is a MAX rarely reached: the loop bails the instant the user resolves — via our button, in
    /// Cursor's own dialog (external-resolution detection in `runHook`), or if the GUI quits
    /// (`presenceLivenessRecheck`). In Cursor the native prompt shows alongside the ribbon, so a long
    /// window doesn't freeze the agent — it's the escape hatch that ends the wait.
    static let permissionPollTimeout: TimeInterval = 240
    /// How often the blocking hook re-checks that the GUI is still alive while waiting, so "app quit
    /// mid-wait" recovers in seconds instead of stalling for the whole window.
    static let presenceLivenessRecheck: TimeInterval = 2
    /// How often (seconds) the IDE-log watcher polls while a permission request is pending, to drop
    /// the ribbon when the user answers in the IDE's own dialog. Only runs while enabled + a request pends.
    static let ideLogPoll: TimeInterval = 1
    /// How long a "chat finished" notice rides the light before auto-clearing — the redesign's in-widget
    /// replacement for the old done toast. Long enough to notice, short enough not to clutter; expiry is
    /// enforced on the next render, so the 5 s `stateTick` bounds the lag.
    static let doneNoticeWindow: TimeInterval = 12
}

/// Per-session state in the traffic-light model (mode A, file-watch).
enum SessionState: String, Sendable {
    case working   // a turn is actively running
    case waiting   // best-effort: looks like it is paused needing the user (see StateEngine notes)
    case done      // turn finished cleanly, nothing pending
    case stale     // no recent activity — not shown in the traffic light
}

/// Where a Claude Code session is hosted, inferred from the hook process's ancestry (see
/// `ProcTree.sessionContext`). Drives two decisions: how long the permission broker may block (an IDE
/// shows its native prompt ALONGSIDE our ribbon, so blocking is safe and the buttons are useful; a
/// terminal's prompt is inline in front of the user, so we hand off at once instead of risking a
/// frozen agent), and where "перейти в чат" jumps (a `cursor://` tab vs. just raising the terminal).
enum SessionHost: String, Sendable {
    case ide        // Cursor / VS Code / VSCodium (hosts the Anthropic.claude-code extension)
    case terminal   // Terminal.app / iTerm2 / Ghostty / tmux / … — Claude Code CLI in a real terminal
    /// Couldn't classify (hooks off / integrated terminal / ssh / an unlisted emulator). Fail-safe on
    /// both host-gated decisions: no permission wait window (like `.terminal` — never freeze an
    /// unclassified agent), and focus opens the project's Cursor WINDOW only — never the `cursor://`
    /// chat-tab deep-link, which would RESUME (fork) a session that isn't actually open in Cursor.
    case unknown
}

/// Aggregate menu-bar color across all live sessions. Precedence: working > waiting > done > none.
enum AggregateColor: String, Sendable {
    case yellow    // >=1 session working
    case red       // none working AND >=1 waiting
    case green     // none working, none waiting, all done
    case gray      // no live sessions
}

/// Token/cost usage for one session or one day (numbers come from `ccusage`, which dedupes).
struct TokenUsage: Sendable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0
    var totalTokens: Int = 0
    var costUsd: Double = 0

    /// Tokens that reflect "real" work (input+output), excluding the huge-but-cheap cache reads.
    var billableTokens: Int { inputTokens + outputTokens + cacheCreationTokens }
}

/// Live context-window occupancy for one chat, reconstructed from the transcript's most recent
/// assistant `usage` (input + cache tokens). `sizeTokens` is INFERRED — the transcript never records
/// the window size, so we assume 200k until a turn exceeds it, then 1M. The token count is therefore
/// exact, but the percent is approximate for a sub-200k session running on the 1M-context model.
struct ContextInfo: Sendable, Equatable {
    var usedPercent: Double
    var sizeTokens: Int
    var inputTokens: Int

    /// Compaction looms — Claude Code auto-compacts near the top of the window.
    var nearCompact: Bool { usedPercent >= 80 }
}

/// One chat (session) inside a day's history breakdown. Tokens/cost come from `ccusage session`;
/// `project`/`title` are recovered from the transcript by UUID (ccusage doesn't carry them).
struct ChatStat: Identifiable, Sendable, Equatable {
    let sessionId: String     // ccusage session `period` (the UUID)
    let project: String       // last path component of cwd, or slug fallback
    let title: String?        // aiTitle → lastPrompt → nil (shown as "(untitled)")
    let tokens: Int
    let cost: Double
    let models: [String]      // ccusage `modelsUsed`
    let lastActivity: Date
    var id: String { sessionId }
}

/// One day in the history view. `totalTokens`/`costUsd` are the authoritative per-day numbers from
/// `ccusage daily`; `chats` is the per-session breakdown grouped by each session's last activity.
struct DayStat: Identifiable, Sendable, Equatable {
    let date: String          // "YYYY-MM-DD" (local)
    var chatCount: Int
    var totalTokens: Int
    var costUsd: Double
    var chats: [ChatStat] = []
    var id: String { date }
}

/// UI-facing snapshot of one live session.
struct SessionInfo: Identifiable, Sendable {
    let id: String            // sessionId (uuid)
    let project: String       // last path component of cwd (fallback: slug-derived)
    var cwd: String? = nil    // full project path — for `cursor -r <cwd>` deep-link
    let gitBranch: String?
    let title: String?        // aiTitle / lastPrompt
    var state: SessionState   // var: the mode-B status overlay can override mode A
    var lastActivity: Date
    var tokens: TokenUsage? = nil   // filled in by StateEngine from UsageProvider (join: id == ccusage period)
    var context: ContextInfo? = nil // reconstructed from the transcript tail (last turn's input + cache)
    /// Where this chat runs (IDE vs. terminal), from the mode-B status file's `host` (see `SessionHost`).
    /// Governs how "перейти в чат" jumps to it. Defaults to `.unknown` (no mode-B record → assume the
    /// Cursor path, the historical behaviour). `hostBundleId` is the host app's bundle id when known —
    /// used to raise a terminal app that Claude Code can't deep-link into by tab.
    var host: SessionHost = .unknown
    var hostBundleId: String? = nil
    /// The chat is compacting its context right now (mode B `PreCompact` hook). A sub-state of `working`
    /// — the state stays `.working` (yellow), this flag only DECORATES it so the UI can say "сжимается,
    /// not stuck" without minting a 5th traffic-light colour. Purely mode B: the transcript is silent
    /// during the (up to ~90s) compaction, so mode A can't see it.
    var isCompacting: Bool = false

    var dot: String {
        switch state {
        case .working: "🟡"
        case .waiting: "🔴"
        case .done: "🟢"
        case .stale: "⚪"
        }
    }

    /// A stable, human display name for the chat — derived automatically from what we already read off
    /// the transcript (`folder · branch`), so two chats in the same repo but different worktrees/branches
    /// stay distinguishable at a glance. This is our take on gmr/claude-status's manual `/name-session`:
    /// no command to run, it just falls out of `cwd` + `gitBranch`. `title` (aiTitle/lastPrompt) is the
    /// finer disambiguator shown beneath it.
    var displayName: String {
        if let gitBranch, !gitBranch.isEmpty { return "\(project) · \(gitBranch)" }
        return project
    }

    var menuLine: String {
        var s = "\(dot) \(project)"
        if let gitBranch, !gitBranch.isEmpty { s += " (\(gitBranch))" }
        if let title, !title.isEmpty { s += " — \(title)" }
        return s
    }
}

/// A chat parked on a NATIVE prompt that only the user can clear in Cursor: a real permission handed off
/// to Claude's own dialog after the wait window (`permission-native`), or a question tool the user must
/// answer (`question-native`). The widget shows these as an INFORMATIONAL "→ open chat" ribbon — no
/// Allow/Deny (the broker hook is no longer listening) — persisting until the next hook event flips the
/// chat off `waiting`. Distinct from a LIVE `PendingRequest` (broker still blocking → actionable buttons).
struct AttentionItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case permission, question }
    let id: String            // sessionId (one attention item per chat)
    let cwd: String?
    let project: String
    let branch: String
    let kind: Kind
}

/// A transient "this chat just finished" notice — shown as a green ribbon at the light, the redesign's
/// in-widget replacement for the old "done" toast. Minted on the working/waiting → done edge (see
/// `StateEngine.manageCompletions`), auto-expires after `Tuning.doneNoticeWindow`, and clears early if
/// the chat resumes or the user jumps to it. Distinct from `AttentionItem` (which persists until a hook
/// clears it) — a completion is informational and self-dismissing.
struct CompletionNotice: Identifiable, Equatable, Sendable {
    let id: String            // sessionId (one notice per chat)
    let cwd: String?
    let project: String
    let branch: String
    let createdAt: Date
}

/// Sort key so the dropdown shows the important sessions first: waiting, then working, then done.
private func sortRank(_ state: SessionState) -> Int {
    switch state {
    case .waiting: 0
    case .working: 1
    case .done: 2
    case .stale: 3
    }
}

func sortedForDisplay(_ sessions: [SessionInfo]) -> [SessionInfo] {
    sessions.sorted {
        let a = sortRank($0.state), b = sortRank($1.state)
        return a != b ? a < b : $0.lastActivity > $1.lastActivity
    }
}

/// Collapse all live sessions into one menu-bar color (§4.1 of the spec).
///
/// `waiting` (needs you) outranks `working`: with many parallel chats something is almost always
/// working, so if working won it would mask a chat that needs your action — and "🔴 needs you" is the
/// app's whole point. A dangling permission `waiting` from a dead hook can't cause a false red — the
/// render() backstop demotes it to `working` first (StateEngine). So: any waiting → red; else any
/// working → yellow; else (all done) → green.
func aggregate(_ sessions: [SessionInfo]) -> AggregateColor {
    let live = sessions.filter { $0.state != .stale }
    if live.isEmpty { return .gray }
    if live.contains(where: { $0.state == .waiting }) { return .red }
    if live.contains(where: { $0.state == .working }) { return .yellow }
    return .green
}
