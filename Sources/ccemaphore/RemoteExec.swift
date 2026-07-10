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
    private static let scpBin = "/usr/bin/scp"

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
        if let port = host.port, !host.useSSHConfigOnly { a += ["-p", String(port)] }
        if !host.useSSHConfigOnly, let idf = host.identityFile, !idf.isEmpty { a += ["-i", idf] }
        let target: String
        if host.useSSHConfigOnly || host.sshUser == nil || host.sshUser!.isEmpty {
            target = host.hostname
        } else {
            target = "\(host.sshUser!)@\(host.hostname)"
        }
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

        try p.run()
        if let stdin { inPipe.fileHandleForWriting.write(stdin) }
        if stdin != nil { try? inPipe.fileHandleForWriting.close() }

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

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning {
            p.terminate()
            _ = group.wait(timeout: .now() + 1)   // let the drains unwind now that terminate() closed the pipes
            throw SSHError(message: "ssh timed out", exitCode: -1)
        }
        group.wait()   // process has exited; both readDataToEndOfFile calls see EOF promptly
        let code = p.terminationStatus
        let out = outData
        if code != 0 {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ssh exited \(code)"
            throw SSHError(message: msg.isEmpty ? "ssh exited \(code)" : msg, exitCode: code)
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

    /// `ssh host cat <path>` — full remote file read. Returns nil if the remote file doesn't exist.
    static func readFile(_ host: RemoteHost, path: String, timeout: TimeInterval = 8) throws -> Data? {
        let argv = connectionArgs(for: host, batch: true) + ["cat \(shQuote(path)) 2>/dev/null"]
        let (out, code) = try runProcessAllowingNonZero(argv, timeout: timeout)
        if code != 0 && out.isEmpty { return nil }
        return out
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
    /// shim script). `mode` defaults to 0755.
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
    static func findFiles(_ host: RemoteHost, root: String, namePattern: String, newerThan marker: String? = nil, timeout: TimeInterval = 10) throws -> [String] {
        var cmd = "find \(shQuote(root)) -type f -name \(shQuote(namePattern))"
        if let marker { cmd += " -newer \(shQuote(marker))" }
        cmd += " 2>/dev/null; true"
        let out = try run(host, command: cmd, timeout: timeout)
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Same as `findFiles`, but pairs each path with its file modification time (`find -printf '%T@ %p'`
    /// — GNU find, i.e. Linux; not available on a BSD/macOS remote's `find`, which has no `-printf`).
    ///
    /// `RemoteTranscriptPoller` uses the returned mtime as the AUTHORITATIVE staleness signal instead of
    /// a timestamp parsed out of the transcript's own JSON content. A live case showed content-derived
    /// timestamps disagreeing with the file's real mtime by ~17 hours for reasons never fully pinned down
    /// (possibly the VS Code extension's own session bookkeeping writing a line whose embedded timestamp
    /// doesn't reflect a real user/assistant turn) — mtime is set by the kernel on the actual write and
    /// can't be spoofed by a JSON-parsing edge case, so it's the more trustworthy source for "is this
    /// session still alive," even though the JSON content is still what determines the finer-grained
    /// working/waiting/done shape for sessions that pass the mtime freshness check.
    static func findFilesWithMTime(_ host: RemoteHost, root: String, namePattern: String, timeout: TimeInterval = 10) throws -> [(path: String, mtime: Date)] {
        let cmd = "find \(shQuote(root)) -type f -name \(shQuote(namePattern)) -printf '%T@ %p\\n' 2>/dev/null; true"
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

    /// Non-batch connectivity probe for the "Test Connection" UI action / `--remote-ping`. Deliberately
    /// OMITS `BatchMode=yes` so a brand-new host's known_hosts prompt can run interactively exactly once;
    /// every other call in this file stays BatchMode so it never blocks waiting on a TTY prompt. Returns
    /// the detected `uname -s` platform string on success.
    static func testConnection(_ host: RemoteHost, timeout: TimeInterval = 15) -> Result<String, SSHError> {
        let argv = connectionArgs(for: host, batch: false) + ["uname -s"]
        do {
            let (out, _) = try runProcess(argv, timeout: timeout)
            let platform = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .success(platform.isEmpty ? "unknown" : platform)
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
