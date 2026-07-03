import Foundation
import Darwin

/// Runs when ccemaphore is invoked as a Claude Code hook: `ccemaphore --hook <event>`. Reads the
/// hook JSON from stdin, maps the event to a precise state, and writes a tiny status file. Must be
/// fast and must NOT start the GUI (routed before App.main in Entry).
///
/// Status contract: ~/.claude/status/<session_id>.json
///   { session_id, cwd, project, state: working|waiting|done|compacting, last_event, updated_at, pid,
///     nb_seq, nb_event }
/// `nb_seq`/`nb_event` count/name the last NON-broker event (any event outside
/// `PermissionBroker.brokerStatusEvents`). The file is last-writer-wins, so a blocking broker polling
/// `last_event` alone can MISS a `pre`/`post` that a second broker's own `permission` write overwrites
/// within one poll interval; the monotonic counter survives that overwrite and is what the broker's
/// external-resolution check compares against its baseline. See memory/permission-stale-ribbon-incident.
enum HookHandler {
    static let statusDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/status")

    static func run(_ event: String) {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let sid = json["session_id"] as? String, !sid.isEmpty else {
            Log.hooks.warn("hook=\(event) ignored: missing/empty session_id (\(data.count)B stdin)")
            return
        }
        // `pre`/`post` fire for EVERY tool (hundreds/day) — they're heartbeats, so log them at debug to
        // keep the info stream scannable for state-meaningful events (start/stop/precompact/prompt/notify).
        // Debug is still persisted to the log file, just filtered out of an info-level scan.
        let isHeartbeat = (event == "pre" || event == "post")
        let project = (json["cwd"] as? String ?? "").split(separator: "/").last.map(String.init) ?? "?"
        if isHeartbeat {
            Log.hooks.debug("hook=\(event) sid=\(sid.prefix(8)) project=\(project)")
        } else {
            Log.hooks.info("hook=\(event) sid=\(sid.prefix(8)) project=\(project)")
        }

        try? FileManager.default.createDirectory(atPath: statusDir, withIntermediateDirectories: true)
        let cwd = json["cwd"] as? String ?? ""

        if event == "end" {
            // Tombstone rather than delete. Writing a `done` record (which captures the owner pid) lets
            // the GUI reap the chat the instant the owning process dies — the common terminal exit
            // (`/exit`, Ctrl-D) — instead of losing the pid and letting a cleanly-finished session linger
            // green until `staleWindow` (30 min). A session whose CLI keeps running (`/clear`, `/logout`)
            // simply settles at `done` and ages out like any other finished chat. The old unconditional
            // delete inverted this: a killed window (file left behind, pid dead) reaped instantly, but a
            // clean exit (file removed) hung. See memory/terminal-mode-review.md.
            writeStatus(sessionId: sid, cwd: cwd, state: "done", event: "end")
            PermissionBroker.clearAllowAll(sid)   // don't leave an auto-allow marker for a dead session
            Log.hooks.info("hook=end sid=\(sid.prefix(8)) → done tombstone (pid-reap on exit)")
            return
        }

        // `Notification` fires only when the agent PAUSES to wait — for permission, or for idle input
        // ("Claude is waiting for your input") — never during active work. Claude Code documents a
        // `notification_type` (permission_prompt / idle_prompt …) as the discriminator; PREFER it when
        // present. It is, however, absent from the stdin payload on some hosts (Claude Code #11964), so
        // we fall back to a `message` substring only when the typed field is missing. That fallback is
        // English-only (Claude's notification strings are English regardless of the app locale, so it
        // works today) — the typed field is the locale-proof path. Either way NEVER write `done` from
        // here — `done` is owned by `Stop`, `waiting` by the permission broker — and the old
        // `(nt == "permission_prompt") ? "waiting" : "done"` fall-through to `done` is why we don't.
        if event == "notify" {
            let type = (json["notification_type"] as? String)?.lowercased()
            let msg = (json["message"] as? String ?? "").lowercased()
            let isPermission = type.map { $0.contains("permission") }
                ?? (msg.contains("permission") || msg.contains("approve"))
            if isPermission {
                // Write the SAME `permission-native` event the broker uses for a handed-off prompt, not a
                // bare `notify`. This is the only permission signal a terminal user gets when the broker
                // took its no-wait fast path and already returned (host != .ide): routing it through
                // `permission-native` reuses the render() ground-truth force-red (nativeWaitEvents) and the
                // ".permission" attention ribbon ("нужен ввод → перейти в чат"). A bare `notify` mapped to
                // neither, so it silently overwrote the broker's `permission-native` and dropped that
                // ribbon — the terminal user's only which-chat/click-to-jump surface. See
                // memory/terminal-mode-review.md.
                writeStatus(sessionId: sid, cwd: cwd, state: "waiting", event: "permission-native")
                Log.hooks.info("hook=notify sid=\(sid.prefix(8)) type=\(type ?? "?") → waiting (permission-native)")
            } else {
                Log.hooks.debug("hook=notify sid=\(sid.prefix(8)) ignored (idle/auth, type=\(type ?? "?")): \(msg.prefix(40))")
            }
            return   // idle / auth / unknown notifications: leave the existing state untouched
        }

        let state: String
        switch event {
        case "stop", "start": state = "done"   // stop = finished; start = registered, idle until first prompt
        case "precompact":     state = "compacting"   // context compaction started — a `working` sub-state
        default:               state = "working"   // prompt / pre / post heartbeat
        }
        // `post` (PostToolUse) is the load-bearing addition: after the user approves a tool in Cursor's
        // OWN dialog, the tool runs and this fires on completion — a NON-broker event the permission
        // broker's poll loop reads as "resolved externally", dropping the ribbon within ~200 ms instead
        // of hanging until the next unrelated hook. See docs/permission-and-waiting-fixes-plan.md (bug #2).
        writeStatus(sessionId: sid, cwd: cwd, state: state, event: event)
        if isHeartbeat {
            Log.hooks.debug("hook=\(event) sid=\(sid.prefix(8)) → \(state)")
        } else {
            Log.hooks.info("hook=\(event) sid=\(sid.prefix(8)) → \(state)")
        }
    }

    /// Write one status file. Shared by the event hooks and the permission broker.
    static func writeStatus(sessionId: String, cwd: String, state: String, event: String) {
        try? FileManager.default.createDirectory(atPath: statusDir, withIntermediateDirectories: true)
        let file = (statusDir as NSString).appendingPathComponent("\(sessionId).json")
        var out: [String: Any] = [
            "session_id": sessionId,
            "cwd": cwd,
            "project": (cwd as NSString).lastPathComponent,
            "state": state,
            "last_event": event,
            "updated_at": Date().formatted(.iso8601),
        ]
        // One ancestry walk binds this session to BOTH its owning agent process (so the GUI can reap it
        // the instant the process dies, instead of waiting out `staleWindow`) and its host (IDE vs.
        // terminal — drives the permission wait window + where "перейти в чат" jumps). Best-effort: a
        // nil owner pid is omitted; host defaults to `.unknown`. Walked OUTSIDE the lock below — it can
        // take a few ms and needs nothing from the file.
        let ctx = ProcTree.sessionContext()
        if let pid = ctx.ownerPid { out["pid"] = Int(pid) }
        out["host"] = ctx.host.rawValue
        if let bundleId = ctx.hostBundleId { out["host_app"] = bundleId }
        // The read-carry-write of the non-broker counter must be serialized across the concurrent hook /
        // broker processes that all write this session's one file — two unserialized writers could both
        // read the same `nb_seq` and one increment would vanish, reopening (at µs scale) exactly the
        // masked-event gap the counter closes. `withStatusLock` is best-effort: if the lock can't be
        // taken the write still happens (a status file must never be lost to a locking failure).
        withStatusLock {
            var (nbSeq, nbEvent) = nonBrokerCarry(sessionId: sessionId)
            // A broker-originated event (see `PermissionBroker.brokerStatusEvents`) carries the counter
            // forward untouched — that's the whole point: its overwrite of `last_event` can no longer
            // hide the `pre`/`post`/`stop` that landed just before it.
            if !PermissionBroker.brokerStatusEvents.contains(event) {
                nbSeq += 1
                nbEvent = event
            }
            out["nb_seq"] = nbSeq
            if let nbEvent { out["nb_event"] = nbEvent }
            // writeStatus is the single load-bearing side effect of every mode-B hook — the GUI drives
            // all precise done/waiting state from these files. A swallowed failure here used to leave the
            // log claiming "→ \(state)" with no file behind it, so log both failure points instead.
            guard let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) else {
                Log.hooks.warn("status write FAILED (encode) sid=\(sessionId.prefix(8)) state=\(state) event=\(event)")
                return
            }
            do {
                try d.write(to: URL(fileURLWithPath: file), options: [.atomic])
            } catch {
                Log.hooks.warn("status write FAILED sid=\(sessionId.prefix(8)) state=\(state) file=\(file): \(error.localizedDescription)")
            }
        }
    }

    /// The current non-broker counter of a session's status file, read LENIENTLY (raw JSON, keyed on the
    /// two fields alone) — (0, nil) when the file is absent/unreadable. This is the ONE reader for both
    /// `writeStatus`'s carry and the broker's `externalBaseline` snapshot: if the baseline used
    /// `StatusReader.parse` (strict — nils the whole entry on a garbled core field) against a file whose
    /// intact `nb_seq` this carry would still preserve, the broker would compare a carried-forward high
    /// seq to a fallback-0 baseline and falsely insta-resolve. One reader ⇒ the two sides can never
    /// disagree about the same bytes.
    static func nonBrokerCarry(sessionId: String) -> (seq: Int, event: String?) {
        let file = (statusDir as NSString).appendingPathComponent("\(sessionId).json")
        guard let data = FileManager.default.contents(atPath: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (0, nil) }
        return ((json["nb_seq"] as? NSNumber)?.intValue ?? 0, json["nb_event"] as? String)
    }

    /// Serialize status read-modify-writes across processes with one `flock`'d sidecar (`.lock` in the
    /// status dir — a single stable inode, deliberately NOT the status file itself: the `.atomic` write
    /// replaces the status file's inode on every save, so a lock taken on it wouldn't exclude the next
    /// opener). Best-effort: if the lock file can't be opened, `body` runs unlocked — same behavior as
    /// before the counter existed, and strictly better than dropping the write. The critical section is
    /// one small-JSON read + rewrite, so contention is microseconds; `flock` self-releases if the
    /// process dies mid-section, so a SIGKILLed hook can't wedge the directory.
    private static func withStatusLock(_ body: () -> Void) {
        let lockPath = (statusDir as NSString).appendingPathComponent(".lock")
        let fd = open(lockPath, O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { body(); return }
        defer { close(fd) }   // close releases the flock too
        if flock(fd, LOCK_EX) != 0 {
            Log.hooks.debug("status lock unavailable (errno=\(errno)) — writing unlocked")
        }
        body()
    }

    /// GC status files the reap path can't reclaim: a window killed WITHOUT a `SessionEnd` (no tombstone,
    /// no fresh render to reap it) and anything left far past `staleWindow`. Without this, `~/.claude/
    /// status` grows one file per session for the GUI's whole life (Claude Code mints a fresh UUID per
    /// chat), and `StatusReader.readAll` re-parses every one on each status-dir FSEvents tick.
    ///
    /// Safe by construction — it only removes what the UI already hides: `render()` drops any status
    /// older than `staleWindow`, and a still-live session rewrites its file on its next hook event, so a
    /// deleted-too-eagerly file simply reappears. Removes a file when it is either far past `staleWindow`
    /// (idle/abandoned) or past `staleWindow` with a confirmed-dead owner (a killed window). Unparseable
    /// files fall back to mtime so a corrupt one can't wedge the directory forever.
    static func sweepStale(now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: statusDir) else { return }
        let entries = StatusReader.readAll(dir: statusDir)
        for name in names where name.hasSuffix(".json") {
            let path = (statusDir as NSString).appendingPathComponent(name)
            let id = String(name.dropLast(".json".count))
            let age: TimeInterval
            if let e = entries[id] {
                age = now.timeIntervalSince(e.updatedAt)
            } else if let a = try? fm.attributesOfItem(atPath: path), let m = a[.modificationDate] as? Date {
                age = now.timeIntervalSince(m)   // unparseable → last write time is the best signal
            } else { continue }
            let deadOwner = entries[id]?.ownerPid.map { !ProcTree.isAlive($0) } ?? false
            guard age > Tuning.staleWindow * 2 || (age > Tuning.staleWindow && deadOwner) else { continue }
            try? fm.removeItem(atPath: path)
            Log.hooks.debug("swept status sid=\(id.prefix(8)) age=\(Int(age))s deadOwner=\(deadOwner)")
        }
    }
}
