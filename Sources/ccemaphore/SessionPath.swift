import Foundation

/// What a `*.jsonl` path under ~/.claude/projects represents.
enum TranscriptKind: Sendable {
    /// Top-level chat transcript: <slug>/<uuid>.jsonl
    case session(id: String, slug: String)
    /// Sub-agent transcript: <slug>/<parentId>/subagents/.../agent-*.jsonl — folded into its parent (D7).
    /// `workflowId` is non-nil for workflow fan-out agents (…/subagents/workflows/wf_<id>/agent-*.jsonl),
    /// so the store can tie them to a workflow and retire them when that workflow's record lands.
    case subagent(parentId: String, slug: String, workflowId: String?)
    /// Workflow run completion record: <slug>/<sessionId>/workflows/wf_<id>.json — written once, when the
    /// run finishes (status completed|failed). The precise "this workflow ended" edge.
    case workflowRecord(sessionId: String, workflowId: String)
    /// journal.jsonl, memory files, non-transcripts — ignored entirely.
    case ignored
}

enum SessionPath {
    /// ~/.claude/projects — a dot-folder, not a TCC-protected location, so no access prompt (§3.6).
    static let projectsRoot: String =
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")

    /// Map a concrete file path to its transcript kind. Pure/structural, no IO. `root` defaults to the
    /// local projects dir; pass an expanded remote root (see `RemoteTranscriptPoller`) to reuse the exact
    /// same structural rules for `$HOME`-expanded remote paths instead of a parallel copy.
    static func classify(_ path: String, root: String = projectsRoot) -> TranscriptKind {
        // `.jsonl` for transcripts; `.json` only so the workflow completion record can be recognised.
        guard path.hasSuffix(".jsonl") || path.hasSuffix(".json") else { return .ignored }
        let prefix = root + "/"
        guard path.hasPrefix(prefix) else { return .ignored }

        let rel = String(path.dropFirst(prefix.count))
        let comps = rel.split(separator: "/").map(String.init)
        guard comps.count >= 2 else { return .ignored }

        let slug = comps[0]
        let base = comps[comps.count - 1]
        if base == "journal.jsonl" { return .ignored }

        // Top-level session transcript: exactly <slug>/<uuid>.jsonl
        if comps.count == 2 {
            guard base.hasSuffix(".jsonl") else { return .ignored }
            let id = String(base.dropLast(".jsonl".count))
            return isUUID(id) ? .session(id: id, slug: slug) : .ignored
        }

        let parentId = comps[1]
        guard isUUID(parentId) else { return .ignored }

        // Sub-agent transcript: <slug>/<parentId>/subagents/.../agent-*.jsonl. Workflow fan-out agents
        // nest under …/subagents/workflows/wf_<id>/, so carry that wf id when the path contains it.
        if comps.contains("subagents"), base.hasPrefix("agent-"), base.hasSuffix(".jsonl") {
            let workflowId = comps.firstIndex(of: "workflows").flatMap { i in
                i + 1 < comps.count ? comps[i + 1] : nil
            }
            return .subagent(parentId: parentId, slug: slug, workflowId: workflowId)
        }

        // Workflow completion record: <slug>/<parentId>/workflows/wf_<id>.json (written once, at finish).
        if comps.count == 4, comps[2] == "workflows", base.hasPrefix("wf_"), base.hasSuffix(".json") {
            return .workflowRecord(sessionId: parentId, workflowId: String(base.dropLast(".json".count)))
        }

        return .ignored
    }

    static func isUUID(_ s: String) -> Bool {
        UUID(uuidString: s) != nil
    }

    /// Fallback project label from the slug when no cwd is available.
    /// (Lossy: slug replaces every non-alnum with '-', so the last segment is a best effort.)
    static func projectName(slug: String) -> String {
        slug.split(separator: "-").last.map(String.init) ?? slug
    }

    /// The `*.jsonl` paths under the projects root written within `window` (a full scan: launch, a dropped
    /// FSEvents batch, Refresh). Older ones can't be live — `SessionStore` drops a record past `staleWindow`
    /// (content timestamps never exceed the file's mtime) — and reading every tail of a long history cost
    /// ~20 s and a 1.4 GB peak. A recent sub-agent's parent comes along even when quiet: it names the chat.
    static func enumerateTranscripts(root: String = projectsRoot, modifiedWithin window: TimeInterval = Tuning.staleWindow,
                                     now: Date = Date()) -> [String] {
        guard let en = FileManager.default.enumerator(atPath: root) else { return [] }
        let cutoff = now.addingTimeInterval(-window)
        var out: Set<String> = []
        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            let path = (root as NSString).appendingPathComponent(rel)
            guard let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  mtime >= cutoff else { continue }
            out.insert(path)
            if case .subagent(let parentId, let slug, _) = classify(path, root: root) {
                let parent = "\(root)/\(slug)/\(parentId).jsonl"
                if FileManager.default.fileExists(atPath: parent) { out.insert(parent) }
            }
        }
        return Array(out)
    }
}
