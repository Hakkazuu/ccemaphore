import Foundation

/// One Codex thread as mode A sees it — its OWN state, never folded with its sub-agents' — and the listed
/// chat it belongs to (itself for a top-level thread, the parent for a sub-agent). What the hook overlay
/// needs to tell whether a hook record is still current.
struct CodexThreadFacts: Sendable, Equatable {
    /// `codex:<thread_id>` of the chat row this thread shows under.
    let chatId: String
    let state: SessionState
    /// The thread's last rollout line (nil: nothing parseable yet).
    let lastActivity: Date?
    /// The USER answers this thread's approval prompts. False under Codex's auto-review, where a guardian
    /// sub-agent decides alone — the `PermissionRequest` hook still fires there, but nobody is asked.
    var approvalsGoToUser = true
}

/// What `CodexSessionStore` publishes per pass: the chat rows, plus per-thread facts keyed
/// `codex:<thread_id>` for every tracked thread (rows and sub-agents alike).
struct CodexSnapshot: Sendable {
    var sessions: [SessionInfo] = []
    var threads: [String: CodexThreadFacts] = [:]
}

/// Folds Codex hook records (`~/.claude/status/codex-<thread>.json`) into the Codex chat rows. Pure.
///
/// Division of labour (see `CodexHooksInstaller`): the rollout is the authority on working / done — it is
/// precise and can't be left stale by a hook Codex didn't run — so a hook NEVER sets either. Hooks add
/// only what a rollout can't show:
///  - waiting: the `PermissionRequest` hook's `permission-native` record → the chat goes red
///    (`waitingKind` drives the "open chat" attention ribbon) — only where the USER reviews approvals.
///    Codex runs that hook BEFORE routing the request to its reviewer, so under auto-review (a guardian
///    sub-agent decides, nobody is asked) the same record means nothing to the user;
///  - compacting: `PreCompact` → the chip on a working chat; `PostCompact` overwrites it.
///
/// A record counts only while it is still CURRENT, judged against the thread it was written for:
///  - the thread's own turn is still open (mode A says `working`) — a finished or interrupted turn has no
///    pending approval;
///  - the thread has written nothing since the hook fired (+ `resolveGrace`). A denial appends the
///    refusal at once; an approval appends nothing until the approved command FINISHES (Codex persists
///    no "exec started" event, and no hook fires at approval time) — so after approving a long command
///    the chat stays red until it completes. Accepted: a time cap would hide genuine waits, and every
///    other signal (Codex's process tree, its debug log) is shared by all threads of one app-server;
///  - it is younger than `staleWindow`.
/// A record from a sub-agent's thread lands on its parent chat — that is the row the user sees.
enum CodexHookOverlay {
    /// Rollout lines written up to this long after the hook record don't count as "moved on": the hook
    /// process and Codex's own writer race by a few milliseconds around the same event.
    static let resolveGrace: TimeInterval = 2

    static func apply(_ snapshot: CodexSnapshot, status: [String: StatusEntry], now: Date,
                      staleWindow: TimeInterval = Tuning.staleWindow) -> [SessionInfo] {
        var waits: [String: WaitingKind] = [:]
        var compacting: Set<String> = []
        for (id, st) in status {
            guard let facts = snapshot.threads[id], isCurrent(st, facts: facts, now: now, staleWindow: staleWindow)
            else { continue }
            if st.state == .waiting, let kind = st.lastEvent.flatMap(waitKind) {
                guard facts.approvalsGoToUser else { continue }
                // A permission prompt outranks a question on the same chat (two threads may wait at once).
                if waits[facts.chatId] != .permission { waits[facts.chatId] = kind }
            } else if st.isCompacting {
                compacting.insert(facts.chatId)
            }
        }
        return snapshot.sessions.map { s in
            var s = s
            if let kind = waits[s.id] {
                s.state = .waiting
                s.waitingKind = kind
                s.isCompacting = false
            } else if compacting.contains(s.id), s.state == .working {
                s.isCompacting = true
            }
            return s
        }
    }

    static func isCurrent(_ st: StatusEntry, facts: CodexThreadFacts, now: Date, staleWindow: TimeInterval) -> Bool {
        guard now.timeIntervalSince(st.updatedAt) <= staleWindow, facts.state == .working else { return false }
        if let last = facts.lastActivity, last > st.updatedAt.addingTimeInterval(resolveGrace) { return false }
        return true
    }

    /// The broker's "parked on the agent's own prompt" events (shared with Claude's force-red rule).
    static func waitKind(_ event: String) -> WaitingKind? {
        switch event {
        case "permission-native": return .permission
        case "question-native":   return .input
        default:                  return nil
        }
    }
}
