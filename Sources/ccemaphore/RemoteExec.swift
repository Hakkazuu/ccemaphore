import Foundation

/// Thin `Process`-based wrapper around `/usr/bin/ssh` — the single place that shells out to a remote
/// host. Every call builds `Process.arguments` as an ARRAY (never a single interpolated shell string for
/// the LOCAL invocation), so `hostname`/`sshUser`/`identityFile` can never cause local command injection
/// regardless of their contents. The command string handed to the REMOTE shell is always ccemaphore-
/// authored (fixed format + a single escaped path argument) — callers must never splice free text
/// (host labels, user input) into it; reuse `shQuote` for the one variable component.
///
/// Host-key trust: routine calls use `BatchMode=yes` (never prompts, fails fast instead of hanging a
/// poll tick) and never force `StrictHostKeyChecking=no` — a first connection must go through
/// `testConnection`, which omits `BatchMode` so the normal interactive known_hosts prompt can run once.
/// After that, `known_hosts` has the key and every later `BatchMode=yes` call succeeds silently; if the
/// remote host key ever changes, ssh refuses rather than us silently trusting a new one.
enum RemoteExec {
    struct SSHError: Error, LocalizedError, Sendable {
        let message: String
        let exitCode: Int32
        var errorDescription: String? { message }
    }

    private static let sshBin = "/usr/bin/ssh"

    /// Deliberately NOT using `ControlMaster`/`ControlPersist` connection reuse: a persistent master ssh
    /// process backgrounds itself but keeps inheriting the FOREGROUND command's stdout/stderr pipe file
    /// descriptors, so `readDataToEndOfFile()` in `runProcess` never sees EOF (some writer — the still-
    /// running master — still holds the pipe open) and every call hangs until the timeout kills it. That
    /// was the exact cause of "ssh timed out" on every remote poll despite the host being reachable
    /// (`testConnection`/manual `ssh` both worked fine). A fresh connection per call is slower but correct.
    private static func connectionArgs(for host: RemoteHost, batch: Bool) -> [String] {
        var a: [String] = []
        if batch { a += ["-o", "BatchMode=yes"] }
        a += ["-o", "ConnectTimeout=5"]
        // Force ControlMaster OFF regardless of the user's ~/.ssh/config: a shared master keeps the
        // foreground command's stdout/stderr pipe FDs open, so runProcess's drains never see EOF and the
        // final wait hangs forever, eating a cooperative-pool thread each poll tick. Our own code never
        // opts in (see the type-level note) — this defends against a user config (`ControlMaster auto`)
        // that does.
        a += ["-o", "ControlMaster=no", "-o", "ControlPath=none"]
        if let port = host.port, !host.useSSHConfigOnly { a += ["-p", String(port)] }
        if !host.useSSHConfigOnly, let idf = host.identityFile, !idf.isEmpty { a += ["-i", idf] }
        let target: String
        if host.useSSHConfigOnly || host.sshUser == nil || host.sshUser!.isEmpty {
            target = host.hostname
        } else {
            target = "\(host.sshUser!)@\(host.hostname)"
        }
        // `--` ends option parsing so a hostname that starts with `-` (a typo, or a hand-edited
        // remote_hosts.json) is treated as the destination — never as an ssh option like
        // `-oProxyCommand=…`, which would run an arbitrary LOCAL command. Verified accepted by OpenSSH.
        a.append("--")
        a.append(target)
        return a
    }

    /// Wrap a path in single quotes for the REMOTE shell (POSIX-safe: replace `'` with `'\''`). Use this
    /// for the one variable component (a path) ever spliced into a remote command string.
    ///
    /// Tilde-aware: EVERY path this app builds (`~/.claude/projects`, `~/.claude/settings.json`, `~/.claude/
    /// ccemaphore/pending/…`) starts with `~`, but a leading `~` inside single quotes is NOT expanded by
    /// the shell — single quotes suppress ALL expansion, including the tilde. Naively single-quoting
    /// `~/.claude/projects` makes the remote shell look for a literal directory named `~` in the login
    /// cwd, which silently finds nothing (a real host with real sessions then reads as "no sessions" —
    /// the exact bug behind "remote host is green/connected but no chats ever show up"). So a leading
    /// `~/` (or a bare `~`) is split off and re-emitted as the UNQUOTED `$HOME` variable, immediately
    /// followed by the single-quoted remainder — adjacent shell words with no space between them
    /// concatenate into one argument, so `$HOME` expands while the rest stays a safe literal.
    static func shQuote(_ path: String) -> String {
        func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        if path == "~" { return "$HOME" }
        if path.hasPrefix("~/") { return "$HOME" + quoted(String(path.dropFirst(1))) }
        return quoted(path)
    }

    @discardableResult
    private static func runProcess(_ argv: [String], stdin: Data? = nil, timeout: TimeInterval) throws -> (out: Data, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sshBin)
        p.arguments = argv
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let inPipe = Pipe()
        if stdin != nil { p.standardInput = inPipe }

        // Event-driven exit wait: the kernel signals this the instant ssh exits, instead of a 50ms
        // `while isRunning` poll that both added latency and pinned a cooperative-pool thread spinning
        // (V6). A signal delivered before we reach `.wait` isn't lost — the semaphore counts it — so
        // there's no race with a fast-exiting process. Must be set BEFORE `run()`.
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }

        try p.run()
        if let stdin {
            // Throwing write (not the raising `write(_:)`) + the process-wide SIGPIPE ignore (Entry.main):
            // if the remote closed its stdin (host dropped mid-write), this throws EPIPE instead of
            // crashing the app. `try?` — a failed stdin write just means the command won't get its input;
            // the exit-code / stderr path below reports the real failure.
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inPipe.fileHandleForWriting.close()
        }

        // Drain stdout/stderr CONCURRENTLY with waiting for exit, on their own queues. Reading only
        // AFTER the process finishes (the previous approach) deadlocks the instant output exceeds the
        // kernel pipe buffer (~64KB on macOS) — a `tail -c 512KB` transcript window or a `find` over many
        // files easily does. The child then blocks writing to a full, undrained pipe, so it never exits,
        // so the exit-poll below never sees it finish — this was the actual cause of "ssh timed out" on
        // every real host (SSH connectivity itself was fine; the pipe just wedged).
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async { outData = outHandle.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .utility).async { errData = errHandle.readDataToEndOfFile(); group.leave() }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()                                   // SIGTERM
            if group.wait(timeout: .now() + 1) == .timedOut {
                kill(p.processIdentifier, SIGKILL)          // escalate: SIGTERM ignored / child wedged on the pipe
                _ = group.wait(timeout: .now() + 1)
            }
            throw SSHError(message: L("remote.ssh.timeout"), exitCode: -1)
        }
        // Bounded even on the success path: the process has exited so the drains EOF promptly, but a stray
        // descendant that inherited the pipe write-end must never wedge this thread forever (ControlMaster
        // is forced off above, so this is belt-and-suspenders).
        _ = group.wait(timeout: .now() + 2)
        let code = p.terminationStatus
        let out = outData
        if code != 0 {
            // Raw ssh stderr is the real diagnostic (kept verbatim); only the app-authored fallback for an
            // empty/undecodable stderr is localized (C1/C3).
            let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SSHError(message: stderr.isEmpty ? Lf("remote.ssh.exited", Int(code)) : stderr, exitCode: code)
        }
        return (out, code)
    }

    /// Run a remote command (ccemaphore-authored string, see type doc), return stdout.
    @discardableResult
    static func run(_ host: RemoteHost, command: String, timeout: TimeInterval = 8) throws -> String {
        let argv = connectionArgs(for: host, batch: true) + [command]
        let (out, _) = try runProcess(argv, timeout: timeout)
        return String(data: out, encoding: .utf8) ?? ""
    }

    /// `ssh host cat <path>` — full remote file read. Returns nil ONLY when the file genuinely doesn't
    /// exist (sentinel exit 44 from the guarded command). A transport/permission failure (ssh 255, cat
    /// denied) THROWS instead of masquerading as "empty file", so a caller that would otherwise overwrite
    /// (`RemoteHooksInstaller.readRemoteSettings`) can refuse rather than clobber the remote file — the
    /// remote analogue of the local strict read.
    static func readFile(_ host: RemoteHost, path: String, timeout: TimeInterval = 8) throws -> Data? {
        let q = shQuote(path)
        let argv = connectionArgs(for: host, batch: true) + ["if [ -f \(q) ]; then cat \(q); else exit 44; fi"]
        do {
            let (out, _) = try runProcess(argv, timeout: timeout)
            return out
        } catch let e as SSHError where e.exitCode == 44 {
            return nil   // file absent — an expected, non-error outcome
        }
    }

    /// `ssh host tail -c <window> <path>` — byte-window tail read, the remote analogue of `TailReader`.
    static func tailFile(_ host: RemoteHost, path: String, window: Int, timeout: TimeInterval = 8) throws -> Data? {
        let cmd = "tail -c \(window) \(shQuote(path)) 2>/dev/null"
        let argv = connectionArgs(for: host, batch: true) + [cmd]
        let (out, code) = try runProcessAllowingNonZero(argv, timeout: timeout)
        if code != 0 && out.isEmpty { return nil }
        return out
    }

    /// Write remote file content, atomically on the remote side (write to `.tmp`, then `mv`).
    static func writeFile(_ host: RemoteHost, path: String, data: Data, timeout: TimeInterval = 8) throws {
        let tmp = path + ".ccemaphore-tmp"
        let cmd = "mkdir -p \(shQuote((path as NSString).deletingLastPathComponent)) && cat > \(shQuote(tmp)) && mv \(shQuote(tmp)) \(shQuote(path))"
        let argv = connectionArgs(for: host, batch: true) + [cmd]
        try runProcess(argv, stdin: data, timeout: timeout)
    }

    /// Upload a local file to the remote host and make it executable (used to deploy the remote hook
    /// shim script) — writes the bytes, then `chmod +x`.
    static func uploadExecutable(_ host: RemoteHost, data: Data, remotePath: String, timeout: TimeInterval = 15) throws {
        try writeFile(host, path: remotePath, data: data, timeout: timeout)
        _ = try run(host, command: "chmod +x \(shQuote(remotePath))", timeout: timeout)
    }

    /// List filenames (non-recursive) matching a remote glob, e.g. `~/.claude/status/*.json`. Empty on
    /// no matches (never throws for "nothing found" — only for a genuine connection failure).
    ///
    /// The trailing `; true` matters: when the glob matches nothing (e.g. the directory doesn't exist
    /// yet — a fresh host with no hooks installed), the shell's un-expanded literal pattern fails the
    /// `[ -e "$f" ]` test, so the loop's own exit status is 1 — which `run()` would otherwise treat as a
    /// connection failure and paint the whole host red for a perfectly normal "nothing here yet" case.
    static func listGlob(_ host: RemoteHost, glob: String, timeout: TimeInterval = 8) throws -> [String] {
        let cmd = "for f in \(glob); do [ -e \"$f\" ] && echo \"$f\"; done; true"
        let out = try run(host, command: cmd, timeout: timeout)
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Find files under a remote root, optionally only those newer than a reference marker file. Never
    /// throws for a MISSING root (e.g. Claude Code hasn't run on that host yet, so `~/.claude/projects`
    /// doesn't exist) — `find` on a nonexistent path exits 1, which the trailing `; true` absorbs into a
    /// normal empty result instead of a connection-error red. Only a genuine SSH/network failure throws.
    /// Pairs each matching path with its file modification time — and, unlike the old
    /// GNU-only `find -printf '%T@ %p'`, works on BOTH Linux and a BSD/macOS remote. The `-printf` form
    /// silently did NOTHING on a macOS host (BSD find has no `-printf`; `; true` swallowed the error), so
    /// the whole remote feature was dead on macOS targets — a host showed "connected, 0 sessions" (V4).
    /// This uses a portable emitter that tries GNU `stat -c %Y` first and falls back to BSD `stat -f %m`,
    /// so no (possibly-undetected) platform field is consulted at all. Output format stays `<epoch>
    /// <path>`, so the parser below is unchanged.
    ///
    /// `newerThanMinutes` (when set) adds `-mmin -<N>`, filtering by mtime ON THE SERVER (F2) — cheaper
    /// (old history never crosses the wire) AND, because both the mtime and "now" are the remote's own
    /// clock, free of the cross-machine clock skew a client-side `now − mtime` comparison suffered.
    ///
    /// `RemoteTranscriptPoller` uses the returned mtime as the AUTHORITATIVE staleness signal instead of
    /// a timestamp parsed out of the transcript's own JSON content. A live case showed content-derived
    /// timestamps disagreeing with the file's real mtime by ~17 hours for reasons never fully pinned down
    /// (possibly the VS Code extension's own session bookkeeping writing a line whose embedded timestamp
    /// doesn't reflect a real user/assistant turn) — mtime is set by the kernel on the actual write and
    /// can't be spoofed by a JSON-parsing edge case, so it's the more trustworthy source for "is this
    /// session still alive," even though the JSON content is still what determines the finer-grained
    /// working/waiting/done shape for sessions that pass the mtime freshness check.
    static func findFilesWithMTime(_ host: RemoteHost, root: String, namePattern: String,
                                   newerThanMinutes: Int? = nil, timeout: TimeInterval = 10) throws -> [(path: String, mtime: Date)] {
        var cmd = "find \(shQuote(root)) -type f -name \(shQuote(namePattern))"
        if let n = newerThanMinutes { cmd += " -mmin -\(n)" }
        // Portable per-file mtime: GNU `stat -c %Y` (Linux) OR, failing that, BSD `stat -f %m` (macOS).
        // Batched via `-exec … {} +`. Path is emitted AFTER the epoch + a single space; a path containing
        // spaces stays intact because the parser splits on the FIRST space only.
        cmd += " -exec sh -c 'for p in \"$@\"; do echo \"$(stat -c %Y \"$p\" 2>/dev/null || stat -f %m \"$p\" 2>/dev/null) $p\"; done' _ {} + 2>/dev/null; true"
        let out = try run(host, command: cmd, timeout: timeout)
        var result: [(path: String, mtime: Date)] = []
        for line in out.split(separator: "\n") {
            guard let spaceIdx = line.firstIndex(of: " ") else { continue }
            let epochStr = line[line.startIndex..<spaceIdx]
            guard let epoch = Double(epochStr) else { continue }
            let path = String(line[line.index(after: spaceIdx)...])
            guard !path.isEmpty else { continue }
            result.append((path, Date(timeIntervalSince1970: epoch)))
        }
        return result
    }

    // MARK: - Batched poll (F6): collapse a tick's many ssh round-trips into one or two

    /// Sendable result of the metadata batch (one ssh): fresh transcript mtimes + every mode-B status
    /// blob. NO transcript tails — those are fetched separately (`batchTails`) for ONLY the files whose
    /// mtime changed since the last poll, so an idle-but-recent session isn't re-transferred every tick
    /// (F1). Data/String/Date fields keep it trivially Sendable across the off-actor SSH boundary.
    struct BatchMeta: Sendable {
        struct FileMeta: Sendable { let path: String; let mtime: Date }
        struct StatusBlob: Sendable { let path: String; let content: Data }
        var files: [FileMeta] = []
        var statuses: [StatusBlob] = []
    }

    /// Send a shell script to the remote as an OPAQUE base64 blob (`printf %s '<b64>' | base64 -d | sh`),
    /// so the script's own quoting/newlines can't be mangled by ssh argv assembly or the remote login
    /// shell — the framing is bulletproof regardless of the host's shell. `base64 -d` is portable across
    /// GNU (Linux) and BSD (macOS). The scripts themselves emit base64-framed output for the same reason
    /// (transcript/status bytes can contain any byte incl. our markers → base64 removes all collision).
    private static func runScript(_ host: RemoteHost, script: String, timeout: TimeInterval) throws -> String {
        let b64 = Data(script.utf8).base64EncodedString()
        return try run(host, command: "printf %s '\(b64)' | base64 -d | sh", timeout: timeout)
    }

    /// One ssh: fresh (`-mmin`) transcript mtimes + all `~/.claude/status/*.json` blobs, base64-framed.
    /// Replaces per-tick `findFilesWithMTime` + status `listGlob` + N×`readFile`. Throws a sentinel on a
    /// malformed/truncated response (no `E` end marker) so the caller can fall back to the legacy path.
    static func batchMeta(_ host: RemoteHost, root: String, staleMinutes: Int, timeout: TimeInterval = 10) throws -> BatchMeta {
        let script = """
        find \(shQuote(root)) -type f -name '*.jsonl' -mmin -\(staleMinutes) -exec sh -c '
        for p in "$@"; do
          m=$(stat -c %Y "$p" 2>/dev/null || stat -f %m "$p" 2>/dev/null)
          printf "F %s %s\\n" "$m" "$(printf %s "$p" | base64 | tr -d "\\n")"
        done
        ' _ {} + 2>/dev/null
        printf 'S\\n'
        for f in "$HOME"/.claude/status/*.json; do
          [ -f "$f" ] || continue
          printf '%s %s\\n' "$(printf %s "$f" | base64 | tr -d "\\n")" "$(base64 < "$f" | tr -d "\\n")"
        done 2>/dev/null
        printf 'E\\n'
        """
        let out = try runScript(host, script: script, timeout: timeout)
        guard let meta = parseBatchMeta(out) else {
            throw SSHError(message: "batchMeta: malformed response", exitCode: -2)
        }
        return meta
    }

    private static func parseBatchMeta(_ out: String) -> BatchMeta? {
        let lines = out.components(separatedBy: "\n")
        guard lines.contains("E") else { return nil }   // truncated / not a well-formed batch
        var meta = BatchMeta()
        var inStatus = false
        for line in lines {
            if line == "E" { break }
            if line == "S" { inStatus = true; continue }
            if inStatus {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2,
                      let pd = Data(base64Encoded: parts[0]), let path = String(data: pd, encoding: .utf8),
                      let content = Data(base64Encoded: parts[1]) else { continue }
                meta.statuses.append(.init(path: path, content: content))
            } else {
                guard line.hasPrefix("F ") else { continue }
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3, let epoch = Double(parts[1]),
                      let pd = Data(base64Encoded: parts[2]), let path = String(data: pd, encoding: .utf8) else { continue }
                meta.files.append(.init(path: path, mtime: Date(timeIntervalSince1970: epoch)))
            }
        }
        return meta
    }

    /// One ssh: base64 tails (512K window) of exactly the given paths — the CHANGED set the caller
    /// computed by diffing `batchMeta` mtimes against its cache (F1). Returns path→tail. Throws the same
    /// malformed sentinel so the caller can fall back to per-file `tailFile`.
    static func batchTails(_ host: RemoteHost, paths: [String], timeout: TimeInterval = 12) throws -> [String: Data] {
        guard !paths.isEmpty else { return [:] }
        let b64paths = paths.map { Data($0.utf8).base64EncodedString() }.joined(separator: " ")
        let script = """
        for b in \(b64paths); do
          q=$(printf %s "$b" | base64 -d)
          printf 'T %s\\n' "$b"
          tail -c 524288 "$q" | base64 | tr -d "\\n"; printf "\\n"
        done
        printf 'E\\n'
        """
        let out = try runScript(host, script: script, timeout: timeout)
        guard let tails = parseBatchTails(out) else {
            throw SSHError(message: "batchTails: malformed response", exitCode: -2)
        }
        return tails
    }

    private static func parseBatchTails(_ out: String) -> [String: Data]? {
        let lines = out.components(separatedBy: "\n")
        guard lines.contains("E") else { return nil }
        var tails: [String: Data] = [:]
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line == "E" { break }
            guard line.hasPrefix("T ") else { i += 1; continue }
            let b64path = String(line.dropFirst(2))
            let tailB64 = (i + 1 < lines.count) ? lines[i + 1] : ""
            i += 2
            guard let pd = Data(base64Encoded: b64path), let path = String(data: pd, encoding: .utf8) else { continue }
            tails[path] = Data(base64Encoded: tailB64) ?? Data()
        }
        return tails
    }

    /// Non-batch connectivity probe for the "Test Connection" UI action / `--remote-ping`. Deliberately
    /// OMITS `BatchMode=yes` so a brand-new host's known_hosts prompt can run interactively exactly once;
    /// every other call in this file stays BatchMode so it never blocks waiting on a TTY prompt. Returns
    /// the detected `uname -s` platform string on success.
    static func testConnection(_ host: RemoteHost, timeout: TimeInterval = 15) -> Result<String, SSHError> {
        let argv = connectionArgs(for: host, batch: false) + ["uname -s"]
        do {
            let (out, _) = try runProcess(argv, timeout: timeout)
            // Return the RAW trimmed `uname -s` (empty allowed) — the view localizes an empty value to
            // "unknown" (C3), rather than baking an English sentinel into the persisted `host.platform`.
            let platform = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .success(platform)
        } catch let e as SSHError {
            return .failure(e)
        } catch {
            return .failure(SSHError(message: error.localizedDescription, exitCode: -1))
        }
    }

    /// `command -v python3` on the remote — used before installing the hook shim (see
    /// `RemoteHooksInstaller`), since the shim is a Python 3 script (portable across macOS/Linux without
    /// shipping a compiled binary).
    static func hasPython3(_ host: RemoteHost, timeout: TimeInterval = 8) -> Bool {
        (try? run(host, command: "command -v python3 2>/dev/null", timeout: timeout))
            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
    }

    /// Like `runProcess`, but a non-zero exit is reported via the returned code instead of throwing —
    /// used by `cat`/`tail` reads where "file doesn't exist" (exit 1) is an expected, non-error outcome.
    private static func runProcessAllowingNonZero(_ argv: [String], timeout: TimeInterval) throws -> (out: Data, code: Int32) {
        do { return try runProcess(argv, timeout: timeout) }
        catch let e as SSHError where e.exitCode > 0 { return (Data(), e.exitCode) }
    }
}
