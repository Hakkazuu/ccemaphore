import Foundation
import Darwin

/// Wraps `ccusage --json` to provide token/cost numbers per session and per day. `ccusage` already
/// handles deduplication and pricing (§3.4 of the spec), so we never sum tokens ourselves.
///
/// Verified contract (see memory ccusage-json-contract):
///  - `daily --json`   → { daily: [{ period:"YYYY-MM-DD", totalTokens, totalCost, ... }], totals }
///  - `session --json` → { session: [{ period:"<uuid>", totalTokens, totalCost, metadata.lastActivity }], totals }
///  - join key: a live session's id == the session entry's `period` (NOT a field named sessionId).
actor UsageProvider {
    private(set) var bySession: [String: TokenUsage] = [:]
    private(set) var days: [DayStat] = []
    /// Resolved runner path last logged — so `refresh()` records the picked bunx/npx only when it
    /// changes, not on every 45 s cycle.
    private var lastRunnerPath: String?

    /// UUID → (mtime, resolved metadata). Lets each 45s refresh skip re-reading transcripts whose
    /// file hasn't changed; only the handful of active sessions are re-read per cycle.
    private struct MetaCacheEntry: Sendable { let mtime: Date; let meta: TranscriptMeta }
    private var metaCache: [String: MetaCacheEntry] = [:]

    func refresh() async {
        guard let exe = Self.findRunner() else {
            Log.usage.warn("ccusage skipped: neither bunx nor npx found in PATH or known locations")
            return
        }
        if exe.path != lastRunnerPath {   // log the resolved runner once, not every 45 s cycle
            lastRunnerPath = exe.path
            Log.usage.info("ccusage runner: \(exe.path)")
        }
        // Plain `ccusage` (not `ccusage@latest`): bunx/npx reuses the cached copy instead of doing a
        // registry round-trip on every 45s refresh — faster, and it works offline once installed.
        async let dailyData = Self.run(exe, ["ccusage", "daily", "--json"])
        async let sessionData = Self.run(exe, ["ccusage", "session", "--json"])

        // 1) Sessions → per-session usage (the live-session join) + the raw chat list.
        var sessionEntries: [SessionEntry] = []
        if let data = await sessionData {
            if let resp = try? JSONDecoder().decode(SessionResponse.self, from: data) {
                sessionEntries = resp.session
                bySession = Dictionary(sessionEntries.map { ($0.period, $0.usage) }, uniquingKeysWith: { a, _ in a })
            } else {
                Log.usage.warn("ccusage session: unparseable output (\(data.count)B)")
            }
        }   // (nil data: run() already logged spawn/timeout/exit reason)

        // 2) Recover project + title per session from its transcript (off-actor, mtime-cached).
        let ids = sessionEntries.map(\.period)
        let cacheSnapshot = metaCache
        let resolved = await Task.detached(priority: .utility) {
            Self.resolveMeta(sessionIds: ids, cache: cacheSnapshot)
        }.value
        metaCache = resolved.cache
        let metas = resolved.metas

        // 3) Group chats by the local day of their last activity.
        var dayChats: [String: [ChatStat]] = [:]
        for e in sessionEntries {
            guard let iso = e.metadata?.lastActivity, let day = Self.localDay(iso) else { continue }
            let meta = metas[e.period] ?? TranscriptMeta(project: "—", title: nil)
            // Workflow sub-agent runs (ccusage reports them under a `wf_*` id) carry no title of their own.
            let title = meta.title ?? (e.period.hasPrefix("wf_") ? L("chat.workflowAgent") : nil)
            let chat = ChatStat(sessionId: e.period, project: meta.project, title: title,
                                tokens: e.totalTokens ?? 0, cost: e.totalCost ?? 0,
                                models: e.modelsUsed ?? [], lastActivity: Self.localDate(iso) ?? .distantPast)
            dayChats[day, default: []].append(chat)
        }

        // 4) Days from `ccusage daily` (authoritative per-day totals); attach the chat breakdown.
        //    A day present only via chats (no daily row) is synthesized from its chats so nothing hides.
        var byDate: [String: DayStat] = [:]
        var gotDaily = false
        if let data = await dailyData {
            if let resp = try? JSONDecoder().decode(DailyResponse.self, from: data) {
                gotDaily = true
                for e in resp.daily {
                    byDate[e.period] = DayStat(date: e.period, chatCount: 0,
                                               totalTokens: e.totalTokens ?? 0, costUsd: e.totalCost ?? 0, chats: [])
                }
            } else {
                Log.usage.warn("ccusage daily: unparseable output (\(data.count)B)")
            }
        }
        for (day, chats) in dayChats {
            let sorted = chats.sorted { $0.tokens > $1.tokens }
            if var d = byDate[day] {
                d.chats = sorted; d.chatCount = sorted.count; byDate[day] = d
            } else {
                byDate[day] = DayStat(date: day, chatCount: sorted.count,
                                      totalTokens: sorted.reduce(0) { $0 + $1.tokens },
                                      costUsd: sorted.reduce(0) { $0 + $1.cost }, chats: sorted)
            }
        }
        days = byDate.values.sorted { $0.date > $1.date }

        if gotDaily || !days.isEmpty {
            Log.usage.info("ccusage refresh ok: sessions=\(bySession.count) days=\(days.count)")
        } else if bySession.isEmpty {
            Log.usage.warn("ccusage produced no parseable output (is ccusage installed for \(exe.lastPathComponent)?)")
        }
    }

    /// Resolve project/title for each session id, reusing cache entries whose file mtime is unchanged.
    /// Pure + `static` so it runs off the actor (one directory walk + a bounded tail-read per changed file).
    private static func resolveMeta(sessionIds: [String], cache: [String: MetaCacheEntry])
        -> (cache: [String: MetaCacheEntry], metas: [String: TranscriptMeta]) {
        let index = TranscriptMetaReader.sessionIndex()
        var newCache: [String: MetaCacheEntry] = [:]   // rebuilt → drops ids no longer reported (bounds growth)
        var metas: [String: TranscriptMeta] = [:]
        for id in sessionIds {
            if let info = index[id] {
                if let c = cache[id], c.mtime == info.mtime {
                    newCache[id] = c; metas[id] = c.meta
                } else {
                    let meta = TranscriptMetaReader.read(path: info.path)
                    newCache[id] = MetaCacheEntry(mtime: info.mtime, meta: meta)
                    metas[id] = meta
                }
            } else if let c = cache[id] {
                newCache[id] = c; metas[id] = c.meta    // transcript gone — keep last known label
            }
        }
        return (newCache, metas)
    }

    // MARK: - Process

    /// Run `<runner> <args...>` and return stdout. nonisolated + off-actor so a slow ccusage call
    /// (it may download on first run) never blocks the actor. A two-stage watchdog (SIGTERM → SIGKILL of
    /// the runner's process GROUP) terminates a hung runner after `timeout`, so even a node/bun
    /// grandchild still holding the stdout pipe is torn down and the read reliably reaches EOF — instead
    /// of leaving the continuation unresumed and this worker thread leaked forever.
    private static func run(_ exe: URL, _ args: [String], timeout: TimeInterval = 30) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = exe
                proc.arguments = args
                // GUI apps inherit a minimal PATH; augment it so the runner can find node/bun.
                var env = ProcessInfo.processInfo.environment
                let home = NSHomeDirectory()
                let extra = ["\(home)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
                env["PATH"] = (extra + [env["PATH"] ?? ""]).joined(separator: ":")
                proc.environment = env
                let out = Pipe()
                proc.standardOutput = out
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                } catch {
                    Log.usage.warn("ccusage spawn failed (\(exe.lastPathComponent) \(args.first ?? "")): \(error.localizedDescription)")
                    cont.resume(returning: nil)
                    return
                }
                let pid = proc.processIdentifier
                // Put the runner in its OWN process group so the watchdog can signal the whole tree.
                // bunx/npx spawn a node/bun grandchild that inherits the stdout pipe's write end; a plain
                // SIGTERM to only the direct child can leave that grandchild holding the pipe, so
                // readDataToEndOfFile would never reach EOF and this worker would leak. Best-effort — a
                // lost setpgid race just falls back to signalling the direct child below.
                setpgid(pid, pid)

                // Two-stage watchdog: SIGTERM the group, then escalate to an un-ignorable SIGKILL, so the
                // write end is guaranteed to close and the read below always unblocks.
                let sigkill = DispatchWorkItem {
                    guard proc.isRunning else { return }
                    if kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }   // un-ignorable last resort
                }
                let killer = DispatchWorkItem {
                    guard proc.isRunning else { return }
                    Log.usage.warn("ccusage \(args.first ?? "") timed out after \(Int(timeout))s — terminating")
                    if kill(-pid, SIGTERM) != 0 { proc.terminate() }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: sigkill)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
                // readDataToEndOfFile returns at EOF — on normal exit, or once the watchdog's signals
                // close every write end of the pipe. terminationStatus != 0 then discards the partial data.
                let data = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                killer.cancel()
                let status = proc.terminationStatus
                if status != 0 {
                    Log.usage.debug("ccusage \(args.first ?? "") exit=\(status) reason=\(proc.terminationReason == .uncaughtSignal ? "signal" : "exit")")
                }
                cont.resume(returning: status == 0 ? data : nil)
            }
        }
    }

    /// Locate `bunx` (preferred) or `npx` by absolute path — never rely on the inherited GUI PATH.
    private static func findRunner() -> URL? {
        let home = NSHomeDirectory()
        var candidates = [
            "\(home)/.bun/bin/bunx",
            "/opt/homebrew/bin/bunx",
            "/usr/local/bin/bunx",
            "\(home)/.bun/bin/npx",
            "/opt/homebrew/bin/npx",
            "/usr/local/bin/npx",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            for e in entries.sorted().reversed() { candidates.append("\(nvm)/\(e)/bin/npx") }
        }
        let fm = FileManager.default
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private static func localDay(_ iso: String) -> String? {
        guard let date = localDate(iso) else { return nil }
        return dayFormatter.string(from: date)
    }

    static func localDate(_ iso: String) -> Date? {
        (try? isoFrac.parse(iso)) ?? (try? isoPlain.parse(iso))
    }

    // Sendable value-type parsers — no `nonisolated(unsafe)`, safe to share without a lock.
    private static let isoFrac = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f
    }()
}

// MARK: - ccusage JSON (keys are already camelCase → default decoder, no snake-case conversion)

private struct DailyResponse: Decodable { let daily: [DailyEntry] }
private struct DailyEntry: Decodable {
    let period: String
    let totalTokens: Int?
    let totalCost: Double?
}

private struct SessionResponse: Decodable { let session: [SessionEntry] }
private struct SessionEntry: Decodable {
    let period: String      // session UUID — the join key
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationTokens: Int?
    let cacheReadTokens: Int?
    let totalTokens: Int?
    let totalCost: Double?
    let modelsUsed: [String]?
    let metadata: Meta?

    struct Meta: Decodable { let lastActivity: String? }

    var usage: TokenUsage {
        TokenUsage(inputTokens: inputTokens ?? 0, outputTokens: outputTokens ?? 0,
                   cacheCreationTokens: cacheCreationTokens ?? 0, cacheReadTokens: cacheReadTokens ?? 0,
                   totalTokens: totalTokens ?? 0, costUsd: totalCost ?? 0)
    }
}

// MARK: - Transcript metadata (project + title by session UUID)

/// Project + human title for a chat, recovered from its transcript. `ccusage session` carries
/// neither, so we read them the same way the live traffic-light does (see SessionStore.classifySession).
struct TranscriptMeta: Sendable, Equatable {
    var project: String
    var title: String?
}

enum TranscriptMetaReader {
    struct FileInfo: Sendable { let path: String; let mtime: Date }

    /// One directory pass mapping every top-level `<slug>/<uuid>.jsonl` to its path + mtime.
    /// Sub-agent / nested transcripts are skipped (SessionPath.classify only yields `.session`).
    static func sessionIndex(root: String = SessionPath.projectsRoot) -> [String: FileInfo] {
        let url = URL(fileURLWithPath: root)
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [:] }
        var out: [String: FileInfo] = [:]
        for case let f as URL in en where f.pathExtension == "jsonl" {
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            switch SessionPath.classify(f.path) {
            case .session(let id, _):
                out[id] = FileInfo(path: f.path, mtime: mtime)
            case .subagent:
                // ccusage reports a workflow run under its `wf_*` directory id; key by that so its
                // tokens still resolve a real project (from cwd) instead of falling through to "—".
                if let wf = f.pathComponents.last(where: { $0.hasPrefix("wf_") }) {
                    out[wf] = FileInfo(path: f.path, mtime: mtime)
                }
            case .ignored, .workflowRecord:   // only .jsonl reach here; the record is .json
                break
            }
        }
        return out
    }

    /// Read `project` (from `cwd`) and `title` (`aiTitle`, else a truncated `lastPrompt`) from the
    /// transcript tail — bounded and line-aware via TailReader, so even multi-MB files stay cheap.
    static func read(path: String) -> TranscriptMeta {
        let lines = TailReader.tailLines(path: path).compactMap(LogLine.decode)
        var project: String?
        var title: String?
        for line in lines {
            if let cwd = line.cwd, !cwd.isEmpty { project = (cwd as NSString).lastPathComponent }
            if let t = line.aiTitle, !t.isEmpty { title = t }
            else if let p = line.lastPrompt, !p.isEmpty, title == nil {
                title = p.count > 80 ? String(p.prefix(80)) + "…" : p
            }
        }
        let slug: String = {
            switch SessionPath.classify(path) {
            case .session(_, let s), .subagent(_, let s, _): return s
            case .ignored, .workflowRecord: return ""
            }
        }()
        return TranscriptMeta(project: project ?? SessionPath.projectName(slug: slug), title: title)
    }
}
