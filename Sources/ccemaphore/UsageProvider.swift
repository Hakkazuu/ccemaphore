import Foundation
import Darwin

/// Wraps `ccusage --json` to provide token/cost numbers per session and per day. `ccusage` already
/// handles deduplication and pricing (§3.4 of the spec), so we never sum tokens ourselves.
///
/// Verified contract (see memory ccusage-json-contract). ccusage ≥ 20 reports EVERY agent it detects —
/// Claude Code and Codex — in one unified output:
///  - `daily --json [--by-agent]` → { daily: [{ period:"YYYY-MM-DD", totalTokens, totalCost,
///    metadata.agents:["claude","codex"], agents:[{ agent, totalTokens, totalCost }] (--by-agent only) }], totals }
///  - `session --json` → { session: [{ agent:"claude"|"codex", period, totalTokens, totalCost,
///    metadata.lastActivity }], totals }. `period` is the Claude session UUID, or for Codex the rollout
///    path stem (`2026/10/08/rollout-<ts>-<thread_id>`) — NOT a field named sessionId.
///  - join keys: a live Claude session's id == `period`; a live Codex thread's id ==
///    `SessionInfo.codexID` of the uuid that ends `period`.
/// Older ccusage (no `agent` field, no `--by-agent`) degrades to Claude-only numbers without a split.
actor UsageProvider {
    private(set) var bySession: [String: TokenUsage] = [:]
    private(set) var days: [DayStat] = []
    /// Resolved runner path last logged — so `refresh()` records the picked bunx/npx only when it
    /// changes, not on every 45 s cycle.
    private var lastRunnerPath: String?
    /// Whether this ccusage accepts `daily --by-agent` (the per-day Claude/Codex split): nil = still
    /// probing, true = works, false = rejected (an older ccusage exits non-zero on the unknown flag).
    /// A single failure proves nothing — two bunx runs started in the same instant have been seen to
    /// both exit 1 (cache-lock race) — so it takes `byAgentStrikesToLock` consecutive failures with a
    /// working plain report to lock, and a locked flag is re-probed every `byAgentReprobeEvery`
    /// refreshes (≈ 30 min) so an upgraded ccusage is picked up without a relaunch.
    private var byAgentSupported: Bool?
    private var byAgentStrikes = 0
    private var refreshesSinceByAgentLock = 0
    private static let byAgentStrikesToLock = 3
    private static let byAgentReprobeEvery = 40

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
        // `--by-agent` adds the per-day Claude/Codex split; an older ccusage rejects it, so fall back
        // to the plain report and, after repeated rejections, stop asking for a while (see `byAgentSupported`).
        var tryByAgent = byAgentSupported != false
        if !tryByAgent {
            refreshesSinceByAgentLock += 1
            if refreshesSinceByAgentLock >= Self.byAgentReprobeEvery {
                refreshesSinceByAgentLock = 0
                tryByAgent = true
            }
        }
        let plainDaily = ["ccusage", "daily", "--json"]
        async let dailyFirst = Self.run(exe, tryByAgent ? plainDaily + ["--by-agent"] : plainDaily)
        async let sessionData = Self.run(exe, ["ccusage", "session", "--json"])

        var dailyData = await dailyFirst
        if tryByAgent {
            if dailyData != nil {
                byAgentSupported = true
                byAgentStrikes = 0
            } else if await sessionData != nil {
                // The runner itself works (the session report came back), so the FLAG is what failed —
                // fall back to the plain report. With both calls dead (no ccusage at all) skip the third
                // spawn: it would fail the same way, every 45 s.
                dailyData = await Self.run(exe, plainDaily)
                // Count a strike only when the plain report worked in the same round — then the flag,
                // not the runner, is what failed. A flag that has worked before never locks (transient).
                if dailyData != nil, byAgentSupported != true {
                    byAgentStrikes += 1
                    if byAgentStrikes >= Self.byAgentStrikesToLock {
                        byAgentSupported = false
                        byAgentStrikes = 0
                        refreshesSinceByAgentLock = 0
                        Log.usage.info("ccusage daily --by-agent rejected \(Self.byAgentStrikesToLock)× — per-agent history split off, re-probing later")
                    }
                }
            }
        }

        // 1) Sessions → per-session usage (the live-session join) + the raw chat list. Each entry is
        //    keyed the way the live session list keys it: Claude by UUID, Codex by `codex:<thread_id>`.
        //    Agents ccemaphore doesn't track (ccusage also knows Gemini, OpenCode, …) are left out of the
        //    chat list — their tokens still count in the day totals.
        var keyed: [KeyedSession] = []
        if let data = await sessionData {
            if let resp = try? JSONDecoder().decode(SessionResponse.self, from: data) {
                keyed = resp.session.compactMap(KeyedSession.init)
                bySession = Dictionary(keyed.map { ($0.key, $0.entry.usage) }, uniquingKeysWith: { a, _ in a })
            } else {
                Log.usage.warn("ccusage session: unparseable output (\(data.count)B)")
            }
        }   // (nil data: run() already logged spawn/timeout/exit reason)

        // 2) Recover project + title per chat, off-actor: Claude from its transcript (mtime-cached),
        //    Codex from the thread catalog (one SQLite query for all ids).
        let claudeIds = keyed.filter { $0.agent == .claude }.map(\.key)
        let codexIds = Set(keyed.compactMap(\.codexThreadId))
        let cacheSnapshot = metaCache
        let claudeTask = Task.detached(priority: .utility) {
            Self.resolveMeta(sessionIds: claudeIds, cache: cacheSnapshot)
        }
        let codexTask = Task.detached(priority: .utility) {
            Self.codexMeta(threadIds: codexIds)
        }
        let resolved = await claudeTask.value
        let codexMetas = await codexTask.value
        metaCache = resolved.cache
        let metas = resolved.metas

        // 3) Group chats by the local day of their last activity.
        var dayChats: [String: [ChatStat]] = [:]
        for k in keyed {
            let e = k.entry
            guard let iso = e.metadata?.lastActivity, let day = Self.localDay(iso) else { continue }
            let meta: TranscriptMeta
            let title: String?
            switch k.agent {
            case .claude:
                meta = metas[k.key] ?? TranscriptMeta(project: "—", title: nil)
                // Workflow sub-agent runs (ccusage reports them under a `wf_*` id) carry no title of their own.
                title = meta.title ?? (k.key.hasPrefix("wf_") ? L("chat.workflowAgent") : nil)
            case .codex:
                meta = k.codexThreadId.flatMap { codexMetas[$0] } ?? TranscriptMeta(project: "—", title: nil)
                title = meta.title
            }
            let chat = ChatStat(sessionId: k.key, project: meta.project, title: title,
                                tokens: e.totalTokens ?? 0, cost: e.totalCost ?? 0,
                                models: e.modelsUsed ?? [], lastActivity: Self.localDate(iso) ?? .distantPast,
                                agent: k.agent)
            dayChats[day, default: []].append(chat)
        }

        // 4) Days from `ccusage daily` (authoritative per-day totals + the agent split); attach the chat
        //    breakdown. A day present only via chats (no daily row) is synthesized from its chats so
        //    nothing hides.
        var byDate: [String: DayStat] = [:]
        var gotDaily = false
        if let data = dailyData {
            if let resp = try? JSONDecoder().decode(DailyResponse.self, from: data) {
                gotDaily = true
                for e in resp.daily {
                    byDate[e.period] = DayStat(date: e.period, chatCount: 0,
                                               totalTokens: e.totalTokens ?? 0, costUsd: e.totalCost ?? 0,
                                               chats: [], byAgent: e.agentSplit)
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
                var d = DayStat(date: day, chatCount: sorted.count,
                                totalTokens: sorted.reduce(0) { $0 + $1.tokens },
                                costUsd: sorted.reduce(0) { $0 + $1.cost }, chats: sorted)
                for c in sorted {
                    d.byAgent[c.agent, default: TokenShare()] = d.byAgent[c.agent, default: TokenShare()]
                        + TokenShare(tokens: c.tokens, cost: c.cost)
                }
                byDate[day] = d
            }
        }
        days = byDate.values.sorted { $0.date > $1.date }

        if gotDaily || !days.isEmpty {
            Log.usage.info("ccusage refresh ok: sessions=\(bySession.count) (codex \(codexIds.count)) days=\(days.count) split=\(byAgentSupported == true)")
        } else if bySession.isEmpty {
            Log.usage.warn("ccusage produced no parseable output (is ccusage installed for \(exe.lastPathComponent)?)")
        }
    }

    /// Project + title for Codex threads, from Codex's own thread catalog (`state_5.sqlite`): the AI /
    /// user-given name, else the auto title, and the thread's cwd. An unreadable catalog (nil rows —
    /// the ChatGPT app holds the write lock mid-checkpoint) yields no labels this round, like a vanished
    /// Claude transcript; the next refresh fills them in.
    private static func codexMeta(threadIds: Set<String>) -> [String: TranscriptMeta] {
        guard !threadIds.isEmpty, let rows = CodexIndex.threads(ids: threadIds) else { return [:] }
        var out: [String: TranscriptMeta] = [:]
        for r in rows {
            let name = r.name.flatMap { $0.isEmpty ? nil : $0 } ?? (r.title.isEmpty ? nil : r.title)
            let title = name.map { $0.count > 80 ? String($0.prefix(80)) + "…" : $0 }
            let project = r.cwd.isEmpty ? "—" : (r.cwd as NSString).lastPathComponent
            out[r.id.lowercased()] = TranscriptMeta(project: project, title: title)
        }
        return out
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

    static func localDate(_ iso: String) -> Date? { ISOTime.parse(iso) }
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
    let metadata: Meta?
    /// Per-agent rows — present only with `--by-agent` (ccusage ≥ 20).
    let agents: [AgentRow]?

    struct Meta: Decodable { let agents: [String]? }
    struct AgentRow: Decodable {
        let agent: String
        let totalTokens: Int?
        let totalCost: Double?
    }

    /// The day's Claude / Codex split. Explicit with `--by-agent`. Without it, a day ccusage attributes
    /// to exactly one agent we know (or an older ccusage that lists none — Claude-only) is wholly that
    /// agent's; a mixed day stays unsplit (combined totals only, no per-agent bars).
    var agentSplit: [AgentKind: TokenShare] {
        if let agents {
            var out: [AgentKind: TokenShare] = [:]
            for row in agents {
                guard let kind = AgentKind(ccusage: row.agent) else { continue }
                out[kind, default: TokenShare()] = out[kind, default: TokenShare()]
                    + TokenShare(tokens: row.totalTokens ?? 0, cost: row.totalCost ?? 0)
            }
            return out
        }
        let listed = metadata?.agents ?? ["claude"]
        guard listed.count == 1, let only = listed.first, let kind = AgentKind(ccusage: only) else { return [:] }
        return [kind: TokenShare(tokens: totalTokens ?? 0, cost: totalCost ?? 0)]
    }
}

private struct SessionResponse: Decodable { let session: [SessionEntry] }
private struct SessionEntry: Decodable {
    /// Claude: the session UUID. Codex: the rollout path stem (`YYYY/MM/DD/rollout-<ts>-<thread_id>`,
    /// or just `rollout-…` for a file at the sessions root). The join key is derived in `KeyedSession`.
    let period: String
    /// `"claude"` / `"codex"` / another agent ccusage knows; absent in older ccusage (Claude only).
    let agent: String?
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

/// A ccusage session entry resolved to the agent ccemaphore tracks and the id the live session list
/// uses for it — so `bySession` joins and `ChatStat` rows are keyed identically to `SessionInfo.id`.
/// nil for agents we don't track, and for a Codex entry whose `period` carries no thread uuid.
private struct KeyedSession {
    let entry: SessionEntry
    let agent: AgentKind
    let key: String
    let codexThreadId: String?

    init?(_ entry: SessionEntry) {
        guard let agent = AgentKind(ccusage: entry.agent ?? "claude") else { return nil }
        self.entry = entry
        self.agent = agent
        switch agent {
        case .claude:
            key = entry.period
            codexThreadId = nil
        case .codex:
            let name = (entry.period as NSString).lastPathComponent
            guard let tid = CodexPaths.threadId(fromRolloutName: name.hasSuffix(".jsonl") ? name : name + ".jsonl")
            else { return nil }
            key = SessionInfo.codexID(threadId: tid)
            codexThreadId = tid
        }
    }
}

private extension AgentKind {
    /// ccusage's agent name → the agents ccemaphore tracks. nil for the rest (Gemini, OpenCode, …).
    init?(ccusage name: String) {
        switch name {
        case "claude": self = .claude
        case "codex": self = .codex
        default: return nil
        }
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
