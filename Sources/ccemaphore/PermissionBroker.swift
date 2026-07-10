import Foundation

/// File-based broker for the interactive permission flow (the opt-in "3-button" mode).
///
/// Driven by the `PermissionRequest` hook (`--hook permission-request`), which fires precisely when
/// Claude puts up a permission dialog. The blocking handler writes a pending request and polls for a
/// decision; ccemaphore shows a notification with [Allow once] [Allow all] [Deny] and writes the
/// decision back. "Allow all in this chat" is remembered by us — Claude Code has no runtime API to add
/// a session permission rule — so the hook auto-allows the rest of that session.
///
/// The legacy `PreToolUse` path (`--hook permission`) is still honored for already-installed configs:
/// it fires for every matched tool BEFORE Claude's own permission check, so it needs `PermissionRules`
/// to guess whether a prompt would even happen. `PermissionRequest` needs no such guess. New installs
/// register only `PermissionRequest`; `HooksInstaller` migrates the old entry across.
///
/// Honest limits (verified): `deny` only blocks that one tool call (the chat continues); the hook
/// can't override explicit deny/ask rules in settings; on timeout it falls back to Claude's own prompt.
enum PermissionBroker {
    /// Test seam: redirect all ccemaphore working files (pending/allowall/usage/chain) to a throwaway
    /// dir so the handler/broker can be exercised without touching the real ~/.claude/ccemaphore.
    static var baseDir: String {
        if let p = ProcessInfo.processInfo.environment["CCEMAPHORE_BASE_DIR"], !p.isEmpty { return p }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".claude/ccemaphore")
    }
    static var pendingDir: String { (baseDir as NSString).appendingPathComponent("pending") }
    static var allowAllDir: String { (baseDir as NSString).appendingPathComponent("allowall") }
    /// Raw last-payload snapshots per hook event — lets `--perm-diag` confirm an event fires on a given
    /// host (Cursor, terminal…) and inspect its exact field shape, without the GUI.
    static var diagDir: String { (baseDir as NSString).appendingPathComponent("diag") }

    /// Marker the GUI writes iff the IDE-log watch is enabled (`WidgetSettings.watchIDELog`, on by
    /// default). The blocking hook checks it to SKIP the transcript-tail toolUseId reconstruction when
    /// the feature is off — the hook is a separate process and can't read the GUI's UserDefaults.
    /// Written/removed by `StateEngine.updateIDELogWatch`.
    static var watchMarker: String { (baseDir as NSString).appendingPathComponent("watch-ide-log") }
    static func isWatchIDELogEnabled() -> Bool { FileManager.default.fileExists(atPath: watchMarker) }

    /// Upper bound on how long the hook blocks waiting for the user — used here only to GC orphaned
    /// requests. The per-call wait is chosen by GUI readiness (90s with notifications, 30s popover-only,
    /// 0s when the app is closed); this MAX value bounds `listPending`/`sweep` and must stay < the
    /// hook's settings.json timeout (300).
    static var pollTimeout: TimeInterval { Tuning.permissionPollTimeout }

    enum Decision: String {
        case allowOnce = "allow", allowAll = "allow-all", deny = "deny"
        /// Body-tap / "go decide in the app": release the hook so Claude shows its own prompt.
        case ask = "ask"
    }

    /// Which Claude Code hook event drove this invocation. Both feed the same notification UI; they
    /// differ in WHEN they fire and in the stdout schema they expect back (see `emit`).
    ///  - `preToolUse`: legacy front-run path. Fires for EVERY matched tool BEFORE Claude's own
    ///    permission check, so it must guess (via `PermissionRules`) whether a prompt would even happen.
    ///  - `permissionRequest`: the precise path. Fires ONLY when Claude actually puts up a permission
    ///    dialog — no guessing, no spurious banners on auto-approved calls.
    enum HookEvent {
        case preToolUse, permissionRequest
        var wire: String {
            switch self {
            case .preToolUse: return "PreToolUse"
            case .permissionRequest: return "PermissionRequest"
            }
        }
    }

    struct PendingRequest: Codable, Sendable {
        let requestId: String
        let sessionId: String
        let tool: String
        let summary: String
        /// The raw command / file path / URL being requested — shown in the ribbon's `$ …` chip
        /// (the floating-widget UI), distinct from the "tool: …" `summary` used by list rows.
        /// Optional so older pending files (written before this field) still decode.
        let detail: String?
        let cwd: String
        let createdAt: String
        /// The `tool_use.id` this request is for, reconstructed from the transcript at request time.
        /// Lets the `IDELogWatcher` join a Cursor/VS Code `tool_dispatch_start toolUseId=…` line
        /// (which fires at approval, before completion) to THIS request. nil ⇒ no early IDE-log detection
        /// for this request (falls back to completion-time resolution). Optional for back-compat decode.
        let toolUseId: String?
    }

    // MARK: - Hook side (blocking; runs as `--hook permission` [PreToolUse] / `--hook permission-request`)

    /// Tools that ask the USER a question (options + context) rather than request a permission. There's
    /// no allow/deny to make — the user must answer IN the chat — so we never front them with decision
    /// buttons: we release the hook at once (the question shows in Cursor) and the widget surfaces a
    /// persistent "needs your input → open chat" attention ribbon (see `question-native` below).
    private static let questionTools: Set<String> = ["AskUserQuestion"]

    /// Status events that do NOT mean "the user answered in the native dialog", so the poll loop must NOT
    /// treat them as an external resolution: the events WE write during the blocking wait, plus the
    /// `Notification` hook's permission notification — which now writes `permission-native` (already
    /// listed), NOT a bare `notify`, precisely so a notification firing mid-wait for the SAME prompt isn't
    /// misread as a later NON-broker event that drops the live Allow/Deny buttons (see HookHandler's
    /// notify branch + memory/terminal-mode-review.md). Any OTHER `last_event` (`pre`/`post`/`stop`/…)
    /// genuinely means the turn advanced — the user answered in the native dialog — so the request was
    /// resolved externally and the ribbon drops.
    ///
    /// Internal (not private): `HookHandler.writeStatus` keys the `nb_seq` non-broker event counter on
    /// this same set, so the two can't drift apart. That counter is what lets a blocking broker see a
    /// non-broker event that was OVERWRITTEN before its next 200 ms poll — a second PermissionRequest on
    /// the same session writes its own `permission` status ~24 ms after the new tool's `pre`, which used
    /// to blind every earlier broker of that session (its stale ribbon then lived until an unrelated
    /// event or the wait-window timeout). See memory/permission-stale-ribbon-incident.
    static let brokerStatusEvents: Set<String> =
        ["permission", "permission-native", "permission-resolved", "permission-app-quit", "question-native"]

    static func runHook(event: HookEvent) {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        // Snapshot the raw payload (overwrite per event) so the first real prompt on any host — Cursor
        // included — lets `--perm-diag` confirm the event fires AND reveal its exact field shape.
        writeDiag(event: event, raw: data)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let sid = json["session_id"] as? String, !sid.isEmpty else {
            // Mirror HookHandler's guard log: a dropped permission prompt must be visible in the log,
            // not only recoverable via a manual `--perm-diag` snapshot.
            Log.permissions.warn("request event=\(event.wire) ignored: missing/empty session_id (\(data.count)B stdin)")
            return
        }
        let tool = json["tool_name"] as? String ?? L("permission.tool.fallback")
        let cwd = json["cwd"] as? String ?? ""

        Log.permissions.info("request event=\(event.wire) sid=\(sid.prefix(8)) tool=\(tool)")

        // Question tools (AskUserQuestion): NOT a permission — nothing to allow/deny, the user must
        // answer in the chat. Don't block and don't create a decision request; mark the chat red with a
        // distinct `question-native` event (so the widget shows an "input needed → open chat" ribbon
        // that persists until answered) and release the hook so the question appears in Cursor at once.
        if questionTools.contains(tool) {
            HookHandler.writeStatus(sessionId: sid, cwd: cwd, state: "waiting", event: "question-native")
            Log.permissions.info("decision sid=\(sid.prefix(8)) tool=\(tool) → ask (question tool, kept red)")
            emit(.ask, event: event); return
        }

        // Remembered "allow all for this chat" → allow instantly, no notification.
        if isAllowAll(sid) {
            Log.permissions.info("decision sid=\(sid.prefix(8)) tool=\(tool) → allow (remembered allow-all)")
            emit(.allowOnce, event: event); return
        }

        // User-curated "trusted commands": a persistent, cross-chat auto-allow scoped to a tool/command
        // pattern (unlike the per-session allow-all above). Returning `allow` here runs the tool with NO
        // native Cursor dialog and NO ribbon — the fix the user chose for the "same build keeps
        // prompting" case. Claude still enforces any deny/ask rule regardless of our hook, so this can
        // never bypass a user deny. Applies to both events (allow is what we want; not a defer).
        if TrustedCommands.isTrusted(tool: tool, input: json["tool_input"]) {
            Log.permissions.info("decision sid=\(sid.prefix(8)) tool=\(tool) → allow (trusted command)")
            emit(.allowOnce, event: event); return
        }

        // PreToolUse fires for EVERY matched tool, BEFORE Claude evaluates its own permission rules, so
        // it cannot tell an auto-approved call from a real prompt. We recreate a CONSERVATIVE subset of
        // that evaluation and, when Claude would resolve the call without prompting, emit NOTHING (defer
        // to Claude's native flow): no pending request, no notification. This is what killed the
        // spurious "🔐 permission" banners on auto-approved Bash / WebFetch / edits. Emitting nothing
        // (not `allow`) is failure-safe — a wrong guess just lets Claude re-evaluate and still prompt.
        //
        // PermissionRequest needs NONE of this: it fires ONLY when Claude actually shows a permission
        // dialog, so its mere arrival IS the "real prompt" signal — we skip the guess entirely.
        if case .preToolUse = event {
            let mode = PermissionRules.resolveMode(payload: json, cwd: cwd)
            if PermissionRules.claudeWillNotPrompt(tool: tool, input: json["tool_input"], permissionMode: mode, cwd: cwd) {
                Log.permissions.info("decision sid=\(sid.prefix(8)) tool=\(tool) → defer (Claude auto-resolves, mode=\(mode ?? "default"))")
                return
            }
        }

        // Readiness gate: only block if the GUI is actually running. If it's closed (or crashed, or
        // these hooks are simply left over from an uninstalled app), no decision can ever arrive — so
        // hand the request straight to Claude's own prompt instead of stalling, leaving nothing behind.
        let readiness = AppPresence.readiness()
        if case .notRunning = readiness {
            Log.permissions.info("decision sid=\(sid.prefix(8)) tool=\(tool) → ask (GUI not running)")
            emit(.ask, event: event); return
        }
        // Where this chat runs decides whether we may block at all. In an IDE (Cursor / VS Code) the
        // native permission dialog shows ALONGSIDE our ribbon (verified in Cursor: the user answers it
        // while we're still blocking, which the external-resolution detection below catches), so blocking
        // is safe and the Allow/Deny buttons are useful. In a TERMINAL the native prompt is inline in
        // front of the user — blocking risks a frozen agent with no on-widget benefit — so we give it no
        // wait window and hand straight to that prompt. `.unknown` is treated like a terminal here (fail
        // safe: never freeze an unclassified host), while focus still falls back to the Cursor path.
        let host = ProcTree.sessionContext().host
        // The wait window is a real one only for an IDE host AND a VISIBLE widget (the ribbon is then on
        // screen with live buttons); terminal/unknown host, or a hidden widget → 0, hand off at once.
        let waitWindow = (host == .ide) ? AppPresence.waitWindow(readiness) : 0

        // No wait window → don't flash a decision ribbon whose buttons can't be answered (the broker
        // won't be here to read them). Keep the chat red with the informational `permission-native`
        // attention ribbon and hand straight to the native prompt. This is the terminal/unknown path and
        // the hidden-widget IDE path; both used to write-then-immediately-GC a pending, briefly flashing
        // an un-actionable decision ribbon (now visible on a terminal with the widget up) — skip it.
        if waitWindow <= 0 {
            HookHandler.writeStatus(sessionId: sid, cwd: cwd, state: "waiting", event: "permission-native")
            Log.permissions.info("decision sid=\(sid.prefix(8)) tool=\(tool) → ask (no wait, host=\(host.rawValue), kept red)")
            emit(.ask, event: event)
            return
        }
        Log.permissions.debug("prompting sid=\(sid.prefix(8)) tool=\(tool) host=\(host.rawValue) wait=\(Int(waitWindow))s")

        let reqId = "\(sid)__\(UUID().uuidString)"   // unique regardless of timing
        // Only pay the transcript-tail toolUseId reconstruction when the IDE-log watch is enabled
        // (checked via the GUI-written marker). A nil id with the watch ON means THIS request falls back
        // to completion-time resolution — log it, or the "~1s after IDE approval" promise degrades with
        // no diagnostic trail (the watcher never even arms for an id-less request).
        let watchIDELog = isWatchIDELogEnabled()
        let toolUseId = watchIDELog ? reconstructToolUseId(payload: json, tool: tool) : nil
        if watchIDELog, toolUseId == nil {
            Log.permissions.debug("no toolUseId reconstructed sid=\(sid.prefix(8)) tool=\(tool) "
                + "— early IDE-log resolution unavailable for this request")
        }
        let req = PendingRequest(requestId: reqId, sessionId: sid, tool: tool,
                                 summary: summarize(tool: tool, input: json["tool_input"]),
                                 detail: rawDetail(input: json["tool_input"]),
                                 cwd: cwd, createdAt: Date().formatted(.iso8601),
                                 toolUseId: toolUseId)
        // Baseline for the counter-based external-resolution check, taken BEFORE our own status write.
        // On PermissionRequest the same tool's `pre` has already fired (events are ordered pre →
        // PermissionRequest), so its increment is inside the baseline and can't self-resolve this
        // request; anything that lands from here on — even if a LATER broker's `permission` write masks
        // its `last_event` within one poll interval — raises the counter above this value and is caught
        // in the loop below. Read via the same LENIENT reader `writeStatus`'s carry uses (see
        // `nonBrokerCarry`) — a strict parse here could disagree with the carry on a garbled file and
        // fabricate a resolution.
        let externalBaseline = HookHandler.nonBrokerCarry(sessionId: sid).seq
        writePending(req)
        // This synchronous atomic write has landed before the loop starts, so the first status read
        // below sees OUR `permission` event — any later NON-broker event then means a subsequent hook
        // fired (the user resolved in Cursor's own dialog).
        HookHandler.writeStatus(sessionId: sid, cwd: cwd, state: "waiting", event: "permission")

        let decisionFile = (pendingDir as NSString).appendingPathComponent("\(reqId).decision")
        let deadline = Date().addingTimeInterval(waitWindow)
        var lastLiveness = Date()
        while Date() < deadline {
            if let raw = try? String(contentsOfFile: decisionFile, encoding: .utf8) {
                let dec = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                cleanup(reqId)
                HookHandler.writeStatus(sessionId: sid, cwd: cwd, state: "working", event: "permission-resolved")
                Log.permissions.info("decision sid=\(sid.prefix(8)) tool=\(tool) → \(dec)")
                switch dec {
                case Decision.allowOnce.rawValue: emit(.allowOnce, event: event)
                case Decision.allowAll.rawValue: setAllowAll(sid); emit(.allowOnce, event: event)
                case Decision.deny.rawValue: emit(.deny, event: event)
                // Unknown/garbled (or explicit "ask") → escalate to Claude's prompt, never silent-allow.
                default: emit(.ask, event: event)
                }
                return
            }
            // External resolution: the user answered in Cursor's OWN dialog (it shows alongside our
            // ribbon). The tool then ran and a later hook (`pre`/`stop`/…) overwrote our `permission`
            // status with a NON-broker event. Detecting that here lets the ribbon drop within ~200 ms
            // instead of hanging until the timeout. Two checks over one read:
            //  - `last_event` is currently a non-broker event — the direct case;
            //  - the non-broker counter rose past our baseline — the MASKED case: the event's
            //    `last_event` was already overwritten (typically by a back-to-back PermissionRequest's
            //    own `permission` write, ~24 ms later — far under our 200 ms poll), which used to blind
            //    this broker and leave its stale ribbon up for minutes. See
            //    memory/permission-stale-ribbon-incident.
            // Failure-safe: a spurious bail (e.g. a PARALLEL tool's `pre` in the same chat) just hands
            // the call back to Claude's flow. We DON'T rewrite the status — the external event already
            // set the correct one; we just drop our pending.
            if let st = StatusReader.readOne(sessionId: sid) {
                if let ev = st.lastEvent, !brokerStatusEvents.contains(ev) {
                    cleanup(reqId)
                    Log.permissions.info("decision sid=\(sid.prefix(8)) tool=\(tool) → resolved externally (event=\(ev))")
                    emit(.ask, event: event)
                    return
                }
                // PermissionRequest only: its ordering guarantee (the same tool's `pre` precedes the
                // request, so it's inside the baseline) is what makes the counter sound. On the legacy
                // PreToolUse path `pre` and this broker race on the SAME event — a `pre` landing after
                // the baseline read would make the counter insta-resolve a request the old check let
                // block; that deprecated path keeps the `last_event` check alone.
                if case .permissionRequest = event, let seq = st.nonBrokerSeq, seq > externalBaseline {
                    cleanup(reqId)
                    Log.permissions.info("decision sid=\(sid.prefix(8)) tool=\(tool) → resolved externally "
                        + "(event=\(st.nonBrokerEvent ?? "?"), masked)")
                    emit(.ask, event: event)
                    return
                }
            }
            // The GUI can quit while we wait. Re-check liveness periodically so "app closed mid-wait"
            // recovers in ~presenceLivenessRecheck seconds instead of stalling for the whole window.
            // App gone → no GUI to keep red, so reset to `working` and let mode A take over.
            if Date().timeIntervalSince(lastLiveness) >= Tuning.presenceLivenessRecheck {
                lastLiveness = Date()
                if case .notRunning = AppPresence.readiness() {
                    cleanup(reqId)
                    HookHandler.writeStatus(sessionId: sid, cwd: cwd, state: "working", event: "permission-app-quit")
                    Log.permissions.info("decision sid=\(sid.prefix(8)) tool=\(tool) → ask (GUI quit mid-wait)")
                    emit(.ask, event: event)
                    return
                }
            }
            usleep(200_000)   // 200 ms
        }
        // Handing off to Claude's own prompt (`.ask`). We're no longer blocking on a decision, so drop
        // the pending request — but KEEP the chat red: Claude is about to show (PreToolUse) or is
        // already showing (PermissionRequest) its native permission prompt and the chat genuinely needs
        // the user. We use a DISTINCT event (`permission-native`) rather than the live-broker
        // `permission`, because the render() backstop only downgrades a dangling `permission` waiting (a
        // SIGKILLed hook) to `working`; `permission-native` is a real, intentional wait that must stay
        // red until the next hook event (the resumed tool's `pre`, or the turn's `stop`) clears it.
        cleanup(reqId)
        HookHandler.writeStatus(sessionId: sid, cwd: cwd, state: "waiting", event: "permission-native")
        Log.permissions.info("decision sid=\(sid.prefix(8)) tool=\(tool) → ask (handoff after \(Int(waitWindow))s, kept red)")
        emit(.ask, event: event)
    }

    // MARK: - ccemaphore side (decision + queries)

    static func decide(requestId: String, _ decision: Decision) {
        let file = (pendingDir as NSString).appendingPathComponent("\(requestId).decision")
        let sid = requestId.split(separator: "_").first.map(String.init) ?? requestId
        // The blocking hook is polling for exactly this file; if the write fails the user's click is
        // lost (the hook times out to Claude's native prompt). Log the ACTUAL outcome — the old
        // unconditional "user chose …" line claimed success even when the write silently failed.
        do {
            try FileManager.default.createDirectory(atPath: pendingDir, withIntermediateDirectories: true)
            try decision.rawValue.write(toFile: file, atomically: true, encoding: .utf8)
            Log.permissions.info("user chose \(decision.rawValue) for sid=\(sid.prefix(8)) (GUI)")
        } catch {
            Log.permissions.error("failed to persist decision \(decision.rawValue) for sid=\(sid.prefix(8)): \(error.localizedDescription)")
        }
    }

    /// The IDE-log watcher saw this request's tool get dispatched (the user answered in the IDE's OWN
    /// dialog). Resolve it like a body-tap: write an `ask` decision so the still-blocking hook cleans up
    /// its pending file + flips the status to `working` within one poll (~200 ms). Safe — the tool was
    /// already dispatched by Claude, so `ask` (defer → emit nothing) changes nothing on Claude's side; we
    /// only drop OUR ribbon early. If the hook already exited, this decision is a harmless GC'd orphan.
    static func resolveExternally(requestId: String) {
        let file = (pendingDir as NSString).appendingPathComponent("\(requestId).decision")
        let sid = requestId.split(separator: "_").first.map(String.init) ?? requestId
        do {
            try FileManager.default.createDirectory(atPath: pendingDir, withIntermediateDirectories: true)
            try Decision.ask.rawValue.write(toFile: file, atomically: true, encoding: .utf8)
            Log.permissions.info("resolved via IDE log for sid=\(sid.prefix(8)) (answered in IDE dialog)")
        } catch {
            Log.permissions.error("failed to persist IDE-log resolution for sid=\(sid.prefix(8)): \(error.localizedDescription)")
        }
    }

    static func listPending() -> [PendingRequest] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: pendingDir) else { return [] }
        let now = Date()
        var out: [PendingRequest] = []
        for name in names where name.hasSuffix(".json") {
            let path = (pendingDir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: path),
                  let req = try? JSONDecoder().decode(PendingRequest.self, from: data) else { continue }
            // Orphaned (the hook was killed mid-wait): the request can never be answered, so GC it
            // instead of letting it pin this session in `activePendingSessions` and permanently
            // suppress its "waiting" notification.
            if let created = parseISO(req.createdAt), now.timeIntervalSince(created) > pollTimeout {
                cleanup(req.requestId)
                continue
            }
            // Decided but not yet GC'd: the user answered via our button, `decide()` wrote
            // `<reqId>.decision`, and the blocking hook removes BOTH files on its next ~200 ms poll.
            // Treat it as no longer pending NOW so the FSEvents that the `.decision` write itself fires
            // on this directory can't re-populate `activePendingSessions` and flash the ribbon red again
            // in the gap between the click and that cleanup — the flicker that re-armed the chime. The
            // hook reads the decision by exact path, so skipping it here is invisible to it; the orphan
            // GC above still reclaims an abandoned decided request once it ages out.
            if fm.fileExists(atPath: (pendingDir as NSString).appendingPathComponent("\(req.requestId).decision")) {
                Log.permissions.debug("listPending skip decided sid=\(req.sessionId.prefix(8)) req=\(req.requestId.prefix(12))")
                continue
            }
            out.append(req)
        }
        return out
    }

    static func clearAllowAll(_ sessionId: String) {
        try? FileManager.default.removeItem(atPath: allowAllMarker(sessionId))
    }

    /// Best-effort GC of stale broker files. Call once at startup. `listPending()` already removes
    /// orphaned pending requests; this also sweeps leftover decision files and long-idle allow-all
    /// markers (a backstop in case a SessionEnd hook never fired to clear them).
    static func sweep() {
        let fm = FileManager.default
        let now = Date()
        _ = listPending()   // side effect: GC stale .json
        if let names = try? fm.contentsOfDirectory(atPath: pendingDir) {
            for name in names where name.hasSuffix(".decision") {
                removeIfOlder((pendingDir as NSString).appendingPathComponent(name), than: pollTimeout, now: now)
            }
        }
        if let names = try? fm.contentsOfDirectory(atPath: allowAllDir) {
            for name in names {
                removeIfOlder((allowAllDir as NSString).appendingPathComponent(name), than: 24 * 3600, now: now)
            }
        }
    }

    private static func removeIfOlder(_ path: String, than age: TimeInterval, now: Date) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              now.timeIntervalSince(mtime) > age else { return }
        try? fm.removeItem(atPath: path)
    }

    private static func parseISO(_ s: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s))
            ?? (try? Date.ISO8601FormatStyle().parse(s))
    }

    // MARK: - Internals

    /// Best-effort recovery of the `tool_use.id` this permission request is for, by scanning the session
    /// transcript newest-first for the matching tool_use block. The PermissionRequest payload carries
    /// `transcript_path` but NOT the tool_use_id, so we reconstruct it once (at request time) and store it
    /// on the pending request for the IDE-log join. Matches on tool name plus — when present — the Bash
    /// command (disambiguates parallel same-tool calls). nil ⇒ no early IDE-log detection for this request.
    private static func reconstructToolUseId(payload: [String: Any], tool: String) -> String? {
        guard let path = payload["transcript_path"] as? String, !path.isEmpty else { return nil }
        // Disambiguate parallel same-tool calls by the tool's primary identifier (command / file_path /
        // url / …), not just Bash's command — else two parallel Reads could pick the wrong tool_use.id.
        let wantSig = inputSignature(payload["tool_input"])
        for line in TailReader.tailLines(path: path).reversed() {
            guard let data = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (o["type"] as? String) == "assistant",
                  let msg = o["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }
            for block in content.reversed() where (block["type"] as? String) == "tool_use" {
                guard (block["name"] as? String) == tool, let id = block["id"] as? String else { continue }
                // Both sides must expose a matching identifier. A tool whose input has none of the known
                // keys (e.g. WebSearch's `query`, or most MCP tools) can't be disambiguated from an
                // EARLIER call of the same tool name earlier in this session — one that may already be
                // dispatched, with its `tool_dispatch_start` line already sitting in the IDE log tail.
                // Matching it anyway used to resolve the ribbon the instant the watcher's first poll ran,
                // even though the CURRENT request was still genuinely pending (live-caught: the ribbon
                // vanishing right away for a repeated WebSearch/MCP call in the same chat). Skip rather
                // than guess — this is exactly what "nil ⇒ no early IDE-log detection" already promised.
                guard let wantSig, let bsig = inputSignature(block["input"]), bsig == wantSig else { continue }
                return id
            }
        }
        return nil
    }

    /// A tool call's primary identifier for matching a transcript tool_use to a hook payload — the first
    /// present of command / file_path / url / notebook_path / pattern / path. nil ⇒ nothing to compare on.
    private static func inputSignature(_ input: Any?) -> String? {
        guard let d = input as? [String: Any] else { return nil }
        for k in ["command", "file_path", "url", "notebook_path", "pattern", "path"] {
            if let v = d[k] as? String { return "\(k):\(v)" }
        }
        return nil
    }

    private static func writePending(_ req: PendingRequest) {
        try? FileManager.default.createDirectory(atPath: pendingDir, withIntermediateDirectories: true)
        let file = (pendingDir as NSString).appendingPathComponent("\(req.requestId).json")
        // This is the ONE write that makes an interactive request visible to the GUI (it drives the red
        // ribbon via activePendingSessions). A swallowed failure = no ribbon and a silent full-timeout
        // stall, so log it. Atomic: the FSEvents-driven reader (listPending) only ever sees a complete file.
        do {
            let data = try JSONEncoder().encode(req)
            try data.write(to: URL(fileURLWithPath: file), options: [.atomic])
        } catch {
            Log.permissions.warn("pending write failed sid=\(req.sessionId.prefix(8)) req=\(req.requestId.prefix(12)): \(error.localizedDescription)")
        }
    }

    private static func cleanup(_ reqId: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: (pendingDir as NSString).appendingPathComponent("\(reqId).json"))
        try? fm.removeItem(atPath: (pendingDir as NSString).appendingPathComponent("\(reqId).decision"))
    }

    private static func allowAllMarker(_ sid: String) -> String {
        (allowAllDir as NSString).appendingPathComponent(sid)
    }
    private static func isAllowAll(_ sid: String) -> Bool {
        FileManager.default.fileExists(atPath: allowAllMarker(sid))
    }
    private static func setAllowAll(_ sid: String) {
        try? FileManager.default.createDirectory(atPath: allowAllDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: allowAllMarker(sid), contents: Data())
    }

    /// Short, content-light description of what's being requested (no full command/file bodies).
    private static func summarize(tool: String, input: Any?) -> String {
        guard let input = input as? [String: Any] else { return tool }
        if let cmd = input["command"] as? String { return "\(tool): \(truncate(oneLine(cmd)))" }
        if let path = input["file_path"] as? String { return "\(tool): \((path as NSString).lastPathComponent)" }
        if let url = input["url"] as? String { return "\(tool): \(truncate(oneLine(url)))" }
        return tool
    }
    /// The raw command / file path / URL (lightly normalized), for the ribbon's `$ …` chip. Distinct
    /// from `summarize` (which prefixes the tool name) — the ribbon already labels it as a command.
    private static func rawDetail(input: Any?) -> String? {
        guard let input = input as? [String: Any] else { return nil }
        if let cmd = input["command"] as? String { return truncate(oneLine(cmd), 300) }
        if let path = input["file_path"] as? String { return (path as NSString).abbreviatingWithTildeInPath }
        if let url = input["url"] as? String { return truncate(oneLine(url), 300) }
        return nil
    }

    private static func truncate(_ s: String, _ n: Int = 70) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }
    /// Collapse newlines/runs of whitespace so a multi-line command renders as one tidy banner line.
    private static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // Decision emission to stdout. The two events expect DIFFERENT schemas:
    //  - PreToolUse:        { hookSpecificOutput: { hookEventName, permissionDecision: allow|deny|ask } }
    //  - PermissionRequest: { hookSpecificOutput: { hookEventName, decision: { behavior: allow|deny } } }
    //    There is no "ask" verb here: the native dialog is already on screen, so to hand off we emit
    //    nothing and let the user answer it in the IDE.
    private enum DecisionOut { case allowOnce, deny, ask }
    private static func emit(_ d: DecisionOut, event: HookEvent) {
        let behavior: String
        switch d {
        case .allowOnce: behavior = "allow"
        case .deny:      behavior = "deny"
        case .ask:       behavior = "ask"
        }
        let obj: [String: Any]
        switch event {
        case .preToolUse:
            obj = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": behavior]]
        case .permissionRequest:
            switch d {
            case .ask: return   // defer: leave Claude's already-visible native dialog for the user
            case .allowOnce, .deny:
                obj = ["hookSpecificOutput": [
                    "hookEventName": "PermissionRequest", "decision": ["behavior": behavior],
                ]]
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            FileHandle.standardOutput.write(data)
        }
    }

    /// Overwrite the raw stdin snapshot for this event (see `diagDir`). Tiny + bounded (one file per
    /// event). Best-effort: a diagnostic must never affect the decision path.
    private static func writeDiag(event: HookEvent, raw: Data) {
        try? FileManager.default.createDirectory(atPath: diagDir, withIntermediateDirectories: true)
        let file = (diagDir as NSString).appendingPathComponent("permission-\(event.wire).json")
        try? raw.write(to: URL(fileURLWithPath: file), options: [.atomic])
    }
}
