import Foundation

/// The Codex suites of `--self-test`: rollout reading, the hook trust model, config.toml reading, the
/// hooks.json installer and the hook overlay.
extension SelfTest {
    static func codexSuites() -> [Suite] {
        [
            Suite(name: "TailReader resumable", body: tailReaderResumable),
            Suite(name: "Rollout incremental parse", body: rolloutIncremental),
            Suite(name: "Rollout turns and inherited history", body: rolloutTurns),
            Suite(name: "Rollout first read widens", body: rolloutWidening),
            Suite(name: "Rollout meta", body: rolloutMeta),
            Suite(name: "Canonical JSON", body: canonicalJSON),
            Suite(name: "Codex trust hash (vectors from codex 0.163)", body: trustHashVectors),
            Suite(name: "Codex trust identity rules", body: trustIdentityRules),
            Suite(name: "MiniTOML", body: miniTOML),
            Suite(name: "Codex config state", body: codexConfigState),
            Suite(name: "Codex hooks installer", body: codexInstaller),
            Suite(name: "Codex hooks status", body: codexHooksStatus),
            Suite(name: "Codex hook overlay", body: codexOverlay),
            Suite(name: "Hook status key", body: hookStatusKey),
        ]
    }

    // MARK: - Fixtures

    private static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// One rollout line, the way Codex writes it.
    private static func line(_ at: Date, _ type: String, _ payload: [String: Any] = [:], ordinal: Int? = nil) -> String {
        var obj: [String: Any] = ["timestamp": at.formatted(iso), "type": type, "payload": payload]
        if let ordinal { obj["ordinal"] = ordinal }
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func event(_ at: Date, _ type: String, turn: String? = nil, ordinal: Int? = nil) -> String {
        var p: [String: Any] = ["type": type]
        if let turn { p["turn_id"] = turn }
        return line(at, "event_msg", p, ordinal: ordinal)
    }

    private static func write(_ text: String, to path: String) {
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
    }

    private static func append(_ text: String, to path: String) {
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(text.utf8))
    }

    // MARK: - TailReader

    private static func tailReaderResumable(_ t: inout Tester) {
        let path = (t.tempDir() as NSString).appendingPathComponent("r.jsonl")
        write("a\nb\npart", to: path)
        let first = TailReader.readResumable(path: path, from: 0)
        t.equal(first?.lines, ["a", "b"], "a half-written last line is left for later")
        t.equal(first?.resumeAt, 4, "resume offset sits just past the last newline")
        t.equal(first?.size, 8, "size is what the read saw")

        append("ial\nc\n", to: path)
        let second = TailReader.readResumable(path: path, from: first?.resumeAt)
        t.equal(second?.lines, ["partial", "c"], "the completed line is read whole on the next call")
        t.equal(second?.resumeAt, 14, "resume offset advances to EOF")

        let third = TailReader.readResumable(path: path, from: 14)
        t.equal(third?.lines, [], "nothing new → no lines")
        t.equal(third?.resumeAt, 14, "…and the offset stays")

        t.expect(TailReader.readResumable(path: path, from: 99) == nil, "an offset past EOF means the file was replaced")
        t.expect(TailReader.readResumable(path: path + ".missing", from: nil) == nil, "a missing file reads nil")

        // Window mode drops the partial first line.
        let tail = TailReader.readResumable(path: path, from: nil, window: 5)
        t.equal(tail?.lines, ["c"], "a window starting mid-line drops that line")

        // A window inside one giant line falls back to the whole file.
        let giant = (t.tempDir() as NSString).appendingPathComponent("g.jsonl")
        write("x\n" + String(repeating: "y", count: 100) + "\n", to: giant)
        let whole = TailReader.readResumable(path: giant, from: nil, window: 20)
        t.equal(whole?.lines.count, 2, "a window inside one giant (newline-terminated) last line re-reads the whole file")
        t.equal(whole?.resumeAt, 103, "…and resumes at EOF")
        append(String(repeating: "z", count: 50), to: giant)
        let unterminated = TailReader.readResumable(path: giant, from: nil, window: 20)
        t.equal(unterminated?.lines.count, 2, "a window inside a line still being written re-reads the whole file")
        t.equal(unterminated?.resumeAt, 103, "…and leaves that line for later")
    }

    // MARK: - Rollout parser

    private static func rolloutIncremental(_ t: inout Tester) {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = [
            line(t0, "session_meta", ["id": "x"]),
            event(t0 + 1, "task_started", turn: "t1"),
            line(t0 + 2, "response_item", ["type": "message"]),
            event(t0 + 3, "task_complete", turn: "t1"),
            event(t0 + 4, "task_started", turn: "t2"),
            line(t0 + 5, "response_item", ["type": "function_call"]),
        ]
        let whole = CodexRolloutParser.parseTail(lines: lines)
        var chunked = CodexTail()
        for chunk in [Array(lines[0..<2]), Array(lines[2..<5]), Array(lines[5...])] {
            chunked = CodexRolloutParser.parseTail(lines: chunk, continuing: chunked)
        }
        t.equal(chunked.openTurnId, whole.openTurnId, "chunked and whole parses agree on the open turn")
        t.equal(chunked.openTurnId, "t2", "the newest turn is open")
        t.equal(chunked.lastTurnEnd, "task_complete", "the turn end carries across chunks")
        t.equal(chunked.turnsSeen, whole.turnsSeen, "turn count carries across chunks")
        t.equal(chunked.linesParsed, 6, "every line counted once")
        t.equal(chunked.lastActivity, t0 + 5, "last activity is the newest line")

        // The same through files: `read` then `readMore` after an append.
        let path = (t.tempDir() as NSString).appendingPathComponent("rollout.jsonl")
        write(lines[0..<3].joined(separator: "\n") + "\n", to: path)
        guard let r1 = CodexRolloutParser.read(path: path) else { return t.expect(false, "read") }
        t.equal(r1.tail.openTurnId, "t1", "after the first read t1 is open")
        append(lines[3...].joined(separator: "\n") + "\n", to: path)
        guard let r2 = CodexRolloutParser.readMore(path: path, after: r1.tail, from: r1.resumeAt) else {
            return t.expect(false, "readMore")
        }
        t.equal(r2.tail.openTurnId, "t2", "readMore sees the turn that started after the first read")
        t.equal(r2.tail.linesParsed, 6, "readMore parses only the appended lines")

        // A file that SHRANK can't be resumed.
        write(lines[0] + "\n", to: path)
        t.expect(CodexRolloutParser.readMore(path: path, after: r2.tail, from: r2.resumeAt) == nil,
                 "a truncated rollout must be read from scratch")
    }

    private static func rolloutTurns(_ t: inout Tester) {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        // A forked sub-agent rollout: its own meta (history starts at ordinal 3), the parent's copied
        // history with the parent's UNCLOSED turn, then the sub-agent's own turn.
        let forked = [
            line(t0, "session_meta", ["id": "child", "subagent_history_start_ordinal": 3], ordinal: 0),
            line(t0, "session_meta", ["id": "parent"], ordinal: 1),
            event(t0, "task_started", turn: "parent-turn", ordinal: 2),
            event(t0 + 1, "task_started", turn: "own", ordinal: 3),
            event(t0 + 9, "task_complete", turn: "own", ordinal: 4),
        ]
        let child = CodexRolloutParser.parseTail(lines: forked)
        t.equal(child.historyStartOrdinal, 3, "the own meta's history start is read")
        t.equal(child.openTurnId, nil, "the parent's copied turn never keeps the sub-agent working")
        t.equal(child.turnsSeen, 1, "copied history isn't counted as this thread's turns")

        // Without the ordinal marker, a newer task_started still supersedes an unclosed older one.
        let unmarked = CodexRolloutParser.parseTail(lines: [
            event(t0, "task_started", turn: "old"),
            event(t0 + 1, "task_started", turn: "new"),
            event(t0 + 2, "task_complete", turn: "new"),
        ])
        t.equal(unmarked.openTurnId, nil, "one turn at a time: the newer start replaces the unclosed one")

        // A completion of some other turn doesn't close the running one.
        let other = CodexRolloutParser.parseTail(lines: [
            event(t0, "task_started", turn: "a"),
            event(t0 + 1, "task_complete", turn: "zzz"),
        ])
        t.equal(other.openTurnId, "a", "an unrelated task_complete leaves the open turn open")

        // Who reviews approvals: the latest of thread_settings_applied / turn_context; the user by default.
        t.equal(CodexTail().approvalsGoToUser, true, "nothing said → the user reviews approvals")
        let auto = CodexRolloutParser.parseTail(lines: [
            line(t0, "event_msg", ["type": "thread_settings_applied", "thread_settings": ["approvals_reviewer": "user"]]),
            line(t0 + 1, "turn_context", ["approvals_reviewer": "auto_review"]),
        ])
        t.equal(auto.approvalsReviewer, "auto_review", "the newest setting wins")
        t.equal(auto.approvalsGoToUser, false, "auto_review: a guardian decides, nobody is asked")
        t.equal(CodexRolloutParser.parseTail(lines: [
            line(t0, "event_msg", ["type": "thread_settings_applied", "thread_settings": ["approvals_reviewer": "guardian_subagent"]]),
        ]).approvalsGoToUser, false, "the legacy guardian_subagent value too")

        // A history start seeded from the head meta holds even when the window starts mid-file (here: on
        // the parent's copied meta) and isn't overwritten by that copy.
        var seed = CodexTail()
        seed.historyStartOrdinal = 3
        let midFile = CodexRolloutParser.parseTail(lines: Array(forked[1...]), continuing: seed)
        t.equal(midFile.historyStartOrdinal, 3, "the seeded history start survives the copied meta")
        t.equal(midFile.openTurnId, nil, "…so the copied turn is still skipped")
        t.equal(midFile.turnsSeen, 1, "…and only the own turn counts")

        // State rules.
        var open = CodexTail()
        open.openTurn = ("a", t0)
        open.lastActivity = t0
        t.equal(CodexRolloutParser.state(of: open, now: t0 + 300, lockHeld: true), .working,
                "an open turn in a live process is working however quiet")
        t.equal(CodexRolloutParser.state(of: open, now: t0 + 300, lockHeld: false), .done,
                "an open turn whose process is gone and silent past the window is over")
        t.equal(CodexRolloutParser.state(of: open, now: t0 + 30, lockHeld: false), .working,
                "…but not before the active window passes")
        t.equal(CodexRolloutParser.state(of: open, now: t0 + 31 * 60, lockHeld: true), .stale,
                "past the stale window everything is stale")
        var closed = CodexTail()
        closed.lastActivity = t0
        closed.lastTurnEnd = "task_complete"
        t.equal(CodexRolloutParser.state(of: closed, now: t0 + 5, lockHeld: true), .done, "no open turn → done")
    }

    private static func rolloutWidening(_ t: inout Tester) {
        // The turn starts, then > 512 KB of turn work follows: the tail window alone can't see the start.
        let t0 = Date().addingTimeInterval(-10)
        let path = (t.tempDir() as NSString).appendingPathComponent("long.jsonl")
        let filler = line(t0 + 2, "response_item", ["type": "function_call_output", "output": String(repeating: "x", count: 64 * 1024)])
        var text = line(t0, "session_meta", ["id": "x"]) + "\n"
            + line(t0, "event_msg", ["type": "thread_settings_applied", "thread_settings": ["approvals_reviewer": "auto_review"]]) + "\n"
            + event(t0 + 1, "task_started", turn: "long") + "\n"
        for _ in 0..<10 { text += filler + "\n" }
        write(text, to: path)
        t.expect(CodexRolloutParser.parseTail(lines: TailReader.tailLines(path: path)).openTurnId == nil,
                 "precondition: the 512 KB window alone misses the turn start")
        let r = CodexRolloutParser.read(path: path)
        t.equal(r?.tail.openTurnId, "long", "the first read widens to the whole file and finds the open turn")
        t.equal(r?.tail.approvalsReviewer, "auto_review", "…and who reviews its approvals")

        // The turn start is in the window, but the reviewer setting before it is not: widen too.
        let path2 = (t.tempDir() as NSString).appendingPathComponent("settings-out.jsonl")
        var text2 = line(t0, "event_msg", ["type": "thread_settings_applied", "thread_settings": ["approvals_reviewer": "auto_review"]]) + "\n"
        for _ in 0..<10 { text2 += filler + "\n" }
        text2 += event(t0 + 3, "task_started", turn: "late") + "\n"
        write(text2, to: path2)
        let r2 = CodexRolloutParser.read(path: path2)
        t.equal(r2?.tail.openTurnId, "late", "the open turn is in the window")
        t.equal(r2?.tail.approvalsReviewer, "auto_review", "a running turn without a known reviewer widens the read")
        if let tail = r?.tail {
            t.equal(CodexRolloutParser.state(of: tail, now: t0 + 600, lockHeld: true), .working,
                    "a long quiet turn of a live thread stays working")
        }
    }

    private static func rolloutMeta(_ t: inout Tester) {
        let dir = t.tempDir()
        func meta(_ payload: [String: Any]) -> CodexRolloutMeta? {
            let path = (dir as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
            write(line(Date(), "session_meta", payload) + "\n", to: path)
            return CodexRolloutParser.readMeta(path: path)
        }
        let user = meta(["id": "U", "thread_source": "user", "source": "vscode", "originator": "codex_work_desktop"])
        t.equal(user?.isSubagent, false, "a user thread is a chat")
        t.equal(user?.threadId, "u", "thread ids are lower-cased")
        let spawn = meta(["id": "c", "thread_source": "subagent",
                          "source": ["subagent": ["thread_spawn": ["parent_thread_id": "P", "agent_nickname": "Hooke"]]]])
        t.equal(spawn?.isSubagent, true, "a spawned sub-agent is not a chat")
        t.equal(spawn?.parentThreadId, "p", "its parent is read from thread_spawn")
        t.equal(spawn?.agentNickname, "Hooke", "its nickname is read")
        let guardian = meta(["id": "g", "thread_source": "guardian_review", "parent_thread_id": "c",
                             "source": ["subagent": ["other": "guardian"]]])
        t.equal(guardian?.isSubagent, true, "a guardian review is a helper, not a chat")
        t.equal(guardian?.parentThreadId, nil, "a guardian has no thread_spawn parent")
        t.equal(meta(["id": "f", "subagent_history_start_ordinal": 16])?.historyStartOrdinal, 16,
                "a fork's history start is read from its own meta")
    }

    // MARK: - Trust model

    private static func canonicalJSON(_ t: inout Tester) {
        t.equal(CanonicalJSON.encode(["b": 1, "a": ["z": true, "_": false]]), #"{"a":{"_":false,"z":true},"b":1}"#,
                "keys are sorted at every level, no whitespace")
        t.equal(CanonicalJSON.encode(["p": "/a/b é \"q\" \\ \n\t\u{01}"]), "{\"p\":\"/a/b é \\\"q\\\" \\\\ \\n\\t\\u0001\"}",
                "slash and non-ASCII stay raw; quote, backslash and control characters are escaped")
        t.equal(CanonicalJSON.encode(["Z": 1, "a": 2]), #"{"Z":1,"a":2}"#, "byte order: upper case sorts first")
        t.equal(CanonicalJSON.encode(["x": [1, "s"]]), #"{"x":[1,"s"]}"#, "arrays keep their order")
    }

    /// `current_hash` values reported by the real codex-cli 0.163 app-server (`hooks/list`) for these
    /// exact handlers on an isolated CODEX_HOME, 2026-10-20.
    private static func trustHashVectors(_ t: inout Tester) {
        let exe = "\"/Applications/ccemaphore.app/Contents/MacOS/ccemaphore\""
        func cmd(_ timeout: Int?, _ command: String) -> [String: Any] {
            var h: [String: Any] = ["type": "command", "command": command]
            if let timeout { h["timeout"] = timeout }
            return h
        }
        let vectors: [(event: String, matcher: String?, handler: [String: Any], hash: String)] = [
            ("PermissionRequest", nil, cmd(30, "\(exe) --hook permission-request --agent codex"),
             "sha256:123f52d935408208700306a41cc3d34aba4c4973f3bfb8a6c26297390e54978a"),
            ("Stop", nil, cmd(10, "\(exe) --hook stop --agent codex"),
             "sha256:593896ba48c12e0bf58c608842a4a98f0f96cec7d414660f2ff47d26683680b2"),
            // Codex clamps Interrupt to 3 s, so 10 and 3 hash alike.
            ("Interrupt", nil, cmd(10, "\(exe) --hook interrupt --agent codex"),
             "sha256:4705d9f52c73105e3745d9a8c3d328faa7c0e51b21e7009679c84e18a83319cf"),
            ("Interrupt", nil, cmd(3, "\(exe) --hook interrupt --agent codex"),
             "sha256:4705d9f52c73105e3745d9a8c3d328faa7c0e51b21e7009679c84e18a83319cf"),
            ("PreCompact", "", cmd(10, "\(exe) --hook precompact --agent codex"),
             "sha256:75bf3d339bc53b93ea59553fb421b30b76f88d625956f92b640036f2ac5d9a5a"),
            // No timeout → Codex's default 600.
            ("PostCompact", nil, cmd(nil, "'/x/y' --hook postcompact --agent codex"),
             "sha256:8be4a75a24bf09d64313f40766983c6a86f3d78b0b49510ca0ce0f55a63af6e1"),
            ("PostCompact", "auto", cmd(5, "echo é/ü \"q\""),
             "sha256:bfde592b5cebed769d76791a24be2d0d79f530866ead1c51fad8cc00674a61c3"),
        ]
        for v in vectors {
            t.equal(CodexHookTrust.declarationHash(event: v.event, matcher: v.matcher, handler: v.handler), v.hash,
                    "hash of \(v.event) matcher=\(v.matcher ?? "nil") \(v.handler["command"] ?? "")")
        }
    }

    private static func trustIdentityRules(_ t: inout Tester) {
        let h: [String: Any] = ["type": "command", "command": "\"/a/ccemaphore\" --hook stop --agent codex", "timeout": 10]
        t.equal(CodexHookTrust.declarationHash(event: "Stop", matcher: "Bash", handler: h),
                CodexHookTrust.declarationHash(event: "Stop", matcher: nil, handler: h),
                "Stop ignores its matcher, so the matcher isn't part of its identity")
        t.expect(CodexHookTrust.declarationHash(event: "PreCompact", matcher: "manual", handler: h)
                 != CodexHookTrust.declarationHash(event: "PreCompact", matcher: nil, handler: h),
                 "PreCompact's matcher is part of its identity")
        t.equal(CodexHookTrust.declarationHash(event: "Stop", matcher: nil, handler: ["type": "command", "command": "  "]), nil,
                "an empty command is skipped by Codex, so it has no hash")
        t.equal(CodexHookTrust.declarationHash(event: "Stop", matcher: nil, handler: ["type": "prompt"]), nil,
                "only command handlers are modelled")
        t.equal(CodexHookTrust.declarationHash(event: "Bogus", matcher: nil, handler: h), nil, "unknown events have no hash")
        t.equal(CodexHookTrust.normalizedTimeout(event: "Interrupt", timeout: nil), 1, "Interrupt defaults to 1 s")
        t.equal(CodexHookTrust.normalizedTimeout(event: "SessionEnd", timeout: 0), 1, "SessionEnd is at least 1 s")
        t.equal(CodexHookTrust.normalizedTimeout(event: "Stop", timeout: nil), 600, "others default to 600 s")
        t.equal(CodexHookTrust.normalizedTimeout(event: "Stop", timeout: 0), 1, "others are at least 1 s")
        t.equal(CodexHookTrust.key(hooksPath: "/h/hooks.json", event: "PermissionRequest", group: 2, handler: 0),
                "/h/hooks.json:permission_request:2:0", "trust key format")
    }

    // MARK: - config.toml

    private static func miniTOML(_ t: inout Tester) {
        let doc = #"""
        # comment with [hooks.state."fake"] inside
        model = "gpt-5" # trailing comment
        notes = """
        [hooks.state."/also/fake:stop:0:0"]
        trusted_hash = "sha256:nope"
        """
        list = [ "a", "b]", { x = 1 },
          "c" ]

        [features]
        hooks = false
        js_repl = true

        [hooks.state."/u/.codex/hooks.json:stop:0:0"]
        trusted_hash = "sha256:aa"

        [hooks.state."/u/.codex/hooks.json:pre_compact:0:0"]
        enabled = false
        trusted_hash = "sha256:bb"

        [hooks.state]
        "/u/.codex/hooks.json:interrupt:0:0" = { trusted_hash = "sha256:cc", enabled = true }
        'lit:key'.trusted_hash = 'sha256:\dd'

        [[mcp_servers.list]]
        trusted_hash = "sha256:array-table"

        [esc]
        s = "q\"uote é \\ end"
        """#
        let f = MiniTOML.flatten(doc)
        t.equal(f[["model"]], .string("gpt-5"), "a basic string with a trailing comment")
        t.equal(f[["features", "hooks"]], .bool(false), "a bool in a table")
        t.equal(f[["features", "js_repl"]], .bool(true), "true")
        t.equal(f[["list"]], .other, "an array (multi-line, with brackets in strings) is skipped as one value")
        t.equal(f[["hooks", "state", "/u/.codex/hooks.json:stop:0:0", "trusted_hash"]], .string("sha256:aa"),
                "the table form Codex writes")
        t.equal(f[["hooks", "state", "/u/.codex/hooks.json:pre_compact:0:0", "enabled"]], .bool(false), "enabled = false")
        t.equal(f[["hooks", "state", "/u/.codex/hooks.json:interrupt:0:0", "trusted_hash"]], .string("sha256:cc"),
                "an inline table under [hooks.state]")
        t.equal(f[["hooks", "state", "lit:key", "trusted_hash"]], .string(#"sha256:\dd"#), "literal strings keep backslashes")
        t.expect(f[["hooks", "state", "/also/fake:stop:0:0", "trusted_hash"]] == nil, "text inside a multi-line string is not parsed")
        t.expect(f[["hooks", "state", "fake"]] == nil, "comments are not parsed")
        t.expect(f[["mcp_servers", "list", "trusted_hash"]] == nil, "an array-of-tables body is never read as a plain table")
        t.equal(f[["esc", "s"]], .string("q\"uote é \\ end"), "escapes in basic strings")
        t.equal(MiniTOML.flatten("garbage = = =\nok = true")[["ok"]], .bool(true), "a malformed line doesn't stop the next one")
        let broken = MiniTOML.flatten("[[\nx = \"unterminated\n[a\ny = 'z")
        t.equal(broken[["a", "y"]], .other, "unterminated strings are present but unreadable, and parsing goes on")
        t.equal(MiniTOML.flatten("a = true\nb.c = 'x'")[["b", "c"]], .string("x"), "dotted keys at the root")
    }

    private static func codexConfigState(_ t: inout Tester) {
        let f = MiniTOML.flatten("""
        [hooks.state."/h:stop:0:0"]
        trusted_hash = "sha256:1"
        [hooks.state."/h:interrupt:0:0"]
        enabled = false
        """)
        let states = CodexHookTrust.states(in: f)
        t.equal(states["/h:stop:0:0"], CodexHookTrust.State(trustedHash: "sha256:1", enabled: nil), "trusted record")
        t.equal(states["/h:interrupt:0:0"], CodexHookTrust.State(trustedHash: nil, enabled: false), "disabled record")
        t.equal(CodexHookTrust.hooksFeatureEnabled(in: f), true, "hooks are on by default")
        t.equal(CodexHookTrust.hooksFeatureEnabled(in: MiniTOML.flatten("[features]\ncodex_hooks = false")), false,
                "the deprecated codex_hooks key turns them off too")
        t.equal(CodexHookTrust.hooksFeatureEnabled(in: MiniTOML.flatten("features.hooks = false")), false,
                "a dotted root key works too")
        t.equal(CodexHookTrust.hooksFeatureEnabled(in: MiniTOML.flatten("[features]\nhooks = true")), true, "explicit on")
    }

    // MARK: - Installer

    private static let exe = "/Applications/ccemaphore.app/Contents/MacOS/ccemaphore"

    /// A hooks.json as ChatGPT.app + a user might have it: someone else's hooks on the same events.
    private static func foreignHooks() -> [String: Any] {
        ["hooks": [
            "PreToolUse": [["matcher": "Grep|Glob", "hooks": [["type": "command", "command": "'/u/.codex/hooks/gate'", "timeout": 5]]]],
            "Stop": [["hooks": [["type": "command", "command": "'/u/.codex/hooks/notify'"]]]],
        ]]
    }

    private static func codexInstaller(_ t: inout Tester) {
        guard let installed = try? CodexHooksInstaller.merged(foreignHooks(), exe: exe) else {
            return t.expect(false, "merge throws on a valid file")
        }
        t.equal(CodexHooksInstaller.installState(installed), .current, "install yields the current set")
        let hooks = installed["hooks"] as? [String: Any] ?? [:]
        for e in CodexHooksInstaller.events {
            let ours = (hooks[e.event] as? [[String: Any]] ?? []).filter(CodexHooksInstaller.isOurs)
            t.equal(ours.count, 1, "exactly one entry of ours on \(e.event)")
        }
        let stop = hooks["Stop"] as? [[String: Any]] ?? []
        t.equal(((stop.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String), "'/u/.codex/hooks/notify'",
                "a foreign Stop hook keeps index 0 (its trust key)")
        t.equal((hooks["PreToolUse"] as? [[String: Any]])?.count, 1, "foreign events are untouched")
        let interrupt = ((hooks["Interrupt"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        t.equal(interrupt?["timeout"] as? Int, 3, "Interrupt gets the 3 s Codex allows")
        t.equal(interrupt?["command"] as? String, "\"\(exe)\" --hook interrupt --agent codex", "tagged command")
        t.expect(((hooks["PermissionRequest"] as? [[String: Any]])?.first?["matcher"]) == nil, "no matcher key")

        let again = try? CodexHooksInstaller.merged(installed, exe: exe)
        t.expect(again.map { HooksInstaller.nsEqual($0, installed) } ?? false, "installing twice changes nothing")

        // Removal leaves exactly the foreign file.
        let removed = CodexHooksInstaller.removed(installed)
        t.expect(HooksInstaller.nsEqual(removed, foreignHooks()), "uninstall restores the foreign hooks as they were")
        t.equal(CodexHooksInstaller.installState(removed), CodexHooksStatus.Install.none, "nothing of ours left")
        t.expect(HooksInstaller.nsEqual(CodexHooksInstaller.removed(["hooks": ["Stop": [["hooks": [["type": "command", "command": "\"\(exe)\" --hook stop --agent codex"]]]]]]), [:]),
                 "an empty hooks object is dropped entirely")

        // Migration from the 1.3.0 layout (10 events + a matcher'd permission entry) and the imported
        // Claude-shaped copies.
        var legacy = foreignHooks()
        var lh = legacy["hooks"] as! [String: Any]
        for (event, kw) in [("SessionStart", "start"), ("UserPromptSubmit", "prompt"), ("PreToolUse", "pre"),
                            ("PostToolUse", "post"), ("Stop", "stop"), ("Interrupt", "interrupt")] {
            var arr = lh[event] as? [[String: Any]] ?? []
            arr.append(["hooks": [["type": "command", "command": "\"/old/ccemaphore\" --hook \(kw) --agent codex", "timeout": 10]]])
            lh[event] = arr
        }
        lh["PermissionRequest"] = [["matcher": "", "hooks": [["type": "command",
                                    "command": "\"/old/ccemaphore\" --hook permission-request --agent codex", "timeout": 300]]]]
        lh["Notification"] = [["hooks": [["type": "command", "command": "\"/old/ccemaphore.app/x\" --hook notify"]]]]
        legacy["hooks"] = lh
        t.equal(CodexHooksInstaller.installState(legacy), .outdated, "the 1.3.0 layout reads as outdated")
        if let migrated = try? CodexHooksInstaller.merged(legacy, exe: exe) {
            t.equal(CodexHooksInstaller.installState(migrated), .current, "update migrates to the current set")
            let mh = migrated["hooks"] as? [String: Any] ?? [:]
            for event in ["SessionStart", "UserPromptSubmit", "PostToolUse", "Notification"] {
                t.expect(mh[event] == nil, "the old \(event) entry is gone")
            }
            t.equal((mh["PreToolUse"] as? [[String: Any]])?.count, 1, "only the foreign PreToolUse hook remains")
        } else {
            t.expect(false, "migration merge throws")
        }

        // An update rewrites our entry IN PLACE: a user's hook after ours keeps its index (its trust key).
        let mine: [String: Any] = ["hooks": [["type": "command", "command": "'/u/mine'"]]]
        let gate: [String: Any] = ["matcher": "Grep", "hooks": [["type": "command", "command": "'/u/gate'"]]]
        let oldStop: [String: Any] = ["hooks": [["type": "command", "command": "\"/old/ccemaphore\" --hook stop --agent codex", "timeout": 10]]]
        let oldPre: [String: Any] = ["hooks": [["type": "command", "command": "\"/old/ccemaphore\" --hook pre --agent codex", "timeout": 10]]]
        let before: [String: Any] = ["hooks": ["Stop": [oldStop, mine], "PreToolUse": [oldPre, gate]]]
        if let after = try? CodexHooksInstaller.merged(before, exe: exe) {
            let ah = after["hooks"] as? [String: Any] ?? [:]
            let stopArr = ah["Stop"] as? [[String: Any]] ?? []
            t.expect(stopArr.count == 2 && CodexHooksInstaller.isOurs(stopArr[0])
                     && HooksInstaller.nsEqual(stopArr[1], mine), "our Stop entry is rewritten at index 0, the user's stays at 1")
            t.equal(CodexHooksInstaller.shiftedForeignEvents(before: before, after: after), ["PreToolUse"],
                    "dropping our old PreToolUse entry moves the user's hook after it — and that is reported")
            t.equal(CodexHooksInstaller.installState(after), .current, "…and the result is the current set")
            t.equal(CodexHooksInstaller.shiftedForeignEvents(before: after, after: CodexHooksInstaller.removed(after)), ["Stop"],
                    "uninstall reports the hooks it moves")
        } else {
            t.expect(false, "in-place merge throws")
        }
        // Duplicates of ours collapse to the first.
        let dup: [String: Any] = ["hooks": ["Stop": [oldStop, mine, oldStop]]]
        if let d = try? CodexHooksInstaller.merged(dup, exe: exe) {
            let arr = (d["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
            t.equal(arr.filter(CodexHooksInstaller.isOurs).count, 1, "duplicate entries of ours collapse to one")
        }

        // Partial installs are outdated too.
        var partial = installed
        var ph = partial["hooks"] as! [String: Any]
        ph.removeValue(forKey: "PreCompact")
        partial["hooks"] = ph
        t.equal(CodexHooksInstaller.installState(partial), .outdated, "a missing event is outdated")

        // Ownership is anchored: a user's own command that mentions us is never ours.
        t.expect(!CodexHooksInstaller.isOurCommand("echo ccemaphore --hook stop --agent codex"), "unquoted user command")
        t.expect(!CodexHooksInstaller.isOurCommand("\"/bin/notify\" --hook stop --agent codex"), "no ccemaphore in the path")
        t.expect(CodexHooksInstaller.isOurCommand("\"/x/ccemaphore\" --hook anything --agent codex"), "any keyword of ours")

        do {
            _ = try CodexHooksInstaller.merged(["hooks": ["Stop": "nope"]], exe: exe)
            t.expect(false, "a malformed event array must not be overwritten")
        } catch {
            t.expect(true, "malformed file refused")
        }

        t.equal(CodexHooksInstaller.commandExe("\"/a b/c\\\"d\" --hook x"), "/a b/c\"d", "quoted exe with escapes")
        t.equal(CodexHooksInstaller.commandExe("/bin/x --y"), "/bin/x", "bare exe")
    }

    private static func codexHooksStatus(_ t: inout Tester) {
        let path = "/u/.codex/hooks.json"
        guard let root = try? CodexHooksInstaller.merged(foreignHooks(), exe: exe) else { return t.expect(false, "merge") }
        func status(_ toml: String) -> CodexHooksStatus {
            CodexHooksInstaller.status(hooksRoot: root, hooksPath: path, config: MiniTOML.flatten(toml))
        }
        let fresh = status("")
        t.equal(fresh.entries.count, CodexHooksInstaller.events.count, "one trust entry per hook of ours (foreign ones ignored)")
        t.equal(fresh.summary, .needsApproval(count: CodexHooksInstaller.events.count, modifiedOnly: false),
                "freshly installed hooks wait for approval")
        let stopKey = fresh.entries.first { $0.event == "Stop" }?.key
        t.equal(stopKey, "/u/.codex/hooks.json:stop:1:0", "our Stop entry sits after the foreign one")

        // Approve everything the way Codex records it.
        func record(_ e: CodexHookTrust.Entry, hash: String? = nil, enabled: Bool? = nil) -> String {
            var s = "[hooks.state.\"\(e.key)\"]\n"
            if let enabled { s += "enabled = \(enabled)\n" }
            s += "trusted_hash = \"\(hash ?? e.currentHash)\"\n"
            return s
        }
        let all = fresh.entries.map { record($0) }.joined(separator: "\n")
        t.equal(status(all).summary, .trusted, "every hook approved → trusted")

        let modified = fresh.entries.map { e in record(e, hash: e.event == "Stop" ? "sha256:old" : nil) }.joined(separator: "\n")
        t.equal(status(modified).summary, .needsApproval(count: 1, modifiedOnly: true), "one changed since approval")

        // PermissionRequest never approved, Stop changed since: counted together, worded "needs approval".
        let mixed = fresh.entries.compactMap { e -> String? in
            e.event == "PermissionRequest" ? nil : record(e, hash: e.event == "Stop" ? "sha256:old" : nil)
        }.joined(separator: "\n")
        t.equal(status(mixed).summary, .needsApproval(count: 2, modifiedOnly: false),
                "new and changed hooks are counted together")

        let disabled = fresh.entries.map { e in record(e, enabled: e.event == "PreCompact" ? false : nil) }.joined(separator: "\n")
        t.equal(status(disabled).summary, .disabled(count: 1), "a hook switched off in Codex")
        t.equal(status(all + "\n[features]\nhooks = false\n").summary, .featureOff, "hooks off in config.toml")

        t.equal(CodexHooksInstaller.status(hooksRoot: foreignHooks(), hooksPath: path, config: [:]), .notInstalled,
                "no hooks of ours → not installed")
    }

    // MARK: - Overlay

    private static func codexOverlay(_ t: inout Tester) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let root = SessionInfo.codexID(threadId: "root")
        let kid = SessionInfo.codexID(threadId: "kid")
        func row(_ state: SessionState = .working) -> SessionInfo {
            var s = SessionInfo(id: root, project: "p", cwd: nil, gitBranch: nil, title: nil, state: state, lastActivity: now)
            s.agent = .codex
            return s
        }
        func snap(root rootState: SessionState = .working, rootActivity: Date? = nil,
                  kid kidState: SessionState = .working, kidActivity: Date? = nil) -> CodexSnapshot {
            CodexSnapshot(sessions: [row()], threads: [
                root: CodexThreadFacts(chatId: root, state: rootState, lastActivity: rootActivity ?? now - 30),
                kid: CodexThreadFacts(chatId: root, state: kidState, lastActivity: kidActivity ?? now - 30),
            ])
        }
        func st(_ id: String, _ state: SessionState, _ event: String, at: Date, compacting: Bool = false) -> StatusEntry {
            StatusEntry(id: id, state: state, project: "p", cwd: nil, updatedAt: at, lastEvent: event,
                        isCompacting: compacting, ownerPid: nil, host: .codexApp, hostBundleId: nil,
                        nonBrokerSeq: nil, nonBrokerEvent: nil, agent: .codex)
        }
        func apply(_ s: CodexSnapshot, _ entries: [StatusEntry]) -> SessionInfo? {
            CodexHookOverlay.apply(s, status: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }), now: now).first
        }

        let waiting = st(root, .waiting, "permission-native", at: now - 10)
        let r1 = apply(snap(), [waiting])
        t.equal(r1?.state, .waiting, "a pending approval turns the chat red")
        t.equal(r1?.waitingKind, .permission, "…as a permission wait")

        t.equal(apply(snap(rootActivity: now - 5), [waiting])?.state, .working,
                "the thread wrote after the hook (approved / denied) → no longer waiting")
        t.equal(apply(snap(rootActivity: now - 9), [waiting])?.state, .waiting,
                "a write within the grace of the hook itself doesn't clear it")
        t.equal(apply(snap(root: .done), [waiting])?.state, .working,
                "the turn is over (mode A) → no pending approval")
        t.equal(apply(snap(), [st(root, .waiting, "permission-native", at: now - 31 * 60)])?.state, .working,
                "a record past the stale window is ignored")
        t.equal(apply(snap(), [st(root, .done, "stop", at: now - 1)])?.state, .working,
                "a hook never sets done — the rollout owns working/done")

        let kidWaiting = apply(snap(), [st(kid, .waiting, "permission-native", at: now - 10)])
        t.equal(kidWaiting?.state, .waiting, "a sub-agent's approval turns its PARENT chat red")
        t.equal(apply(snap(rootActivity: now - 1), [st(kid, .waiting, "permission-native", at: now - 10)])?.state, .waiting,
                "the parent's own activity doesn't clear a sub-agent's wait")
        t.equal(apply(snap(kidActivity: now - 1), [st(kid, .waiting, "permission-native", at: now - 10)])?.state, .working,
                "the sub-agent's own activity does")

        let both = apply(snap(), [st(root, .waiting, "question-native", at: now - 10), st(kid, .waiting, "permission-native", at: now - 10)])
        t.equal(both?.waitingKind, .permission, "a permission prompt outranks a question on the same chat")

        t.equal(apply(snap(), [st(root, .working, "precompact", at: now - 10, compacting: true)])?.isCompacting, true,
                "PreCompact → the compacting chip")
        t.equal(apply(snap(rootActivity: now - 1), [st(root, .working, "precompact", at: now - 10, compacting: true)])?.isCompacting, false,
                "the compacted rollout line ends it")

        var guarded = snap()
        guarded.threads[root] = CodexThreadFacts(chatId: root, state: .working, lastActivity: now - 30, approvalsGoToUser: false)
        t.equal(apply(guarded, [waiting])?.state, .working,
                "under auto-review the hook fires but nobody is asked → no red")
        t.equal(apply(guarded, [st(kid, .waiting, "permission-native", at: now - 10)])?.state, .waiting,
                "the reviewer is per thread: a user-reviewed sub-agent still turns its chat red")

        let unknown = st(SessionInfo.codexID(threadId: "elsewhere"), .waiting, "permission-native", at: now - 1)
        t.equal(apply(snap(), [unknown])?.state, .working, "a record for a thread we don't track changes nothing")
    }

    private static func hookStatusKey(_ t: inout Tester) {
        let rollout = "/u/.codex/sessions/2026/10/20/rollout-2026-10-20T00-53-37-01A155F0-F475-7153-8AF0-4C9D46DF48DC.jsonl"
        t.equal(HookHandler.statusKey(agent: .codex, payload: ["session_id": "ROOT", "transcript_path": rollout]),
                "codex:01a155f0-f475-7153-8af0-4c9d46df48dc", "Codex: the thread the hook ran in, from its rollout")
        t.equal(HookHandler.statusKey(agent: .codex, payload: ["session_id": "ROOT", "transcript_path": NSNull()]),
                "codex:root", "Codex without a transcript path: the session id")
        t.equal(HookHandler.statusKey(agent: .codex, payload: ["session_id": "ROOT", "transcript_path": "/tmp/other.jsonl"]),
                "codex:root", "a path that isn't a rollout falls back to the session id")
        t.equal(HookHandler.statusKey(agent: .claude, payload: ["session_id": "abc", "transcript_path": rollout]), "abc",
                "Claude: the session id as is")
        t.equal(HookHandler.statusKey(agent: .codex, payload: [:]), nil, "no id at all")
    }
}
