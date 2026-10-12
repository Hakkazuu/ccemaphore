import Foundation

/// A "product": one folder that holds several repositories worked on together (backend + frontend +
/// landing). Chats whose cwd lies under the root are grouped under it in the panel's "by product" mode.
/// Three origins, in precedence order when roots coincide: `manual` (the user typed it), `codex`
/// (ChatGPT.app's own sidebar projects, `CodexIndex.projects`), `auto` (a parent folder under which 2+
/// distinct repos currently have live chats).
struct ProductGroup: Identifiable, Equatable, Sendable, Codable {
    enum Source: String, Codable, Sendable { case manual, codex, auto }
    /// The root path doubles as the stable id (one group per folder).
    var id: String { root }
    var name: String
    var root: String
    var source: Source
}

/// Persistent manual groups + the resolver that merges them with Codex projects and auto-suggestions.
/// Stored as JSON at `<baseDir>/product_groups.json` (honours `CCEMAPHORE_BASE_DIR`, like the trusted
/// commands and remote hosts files).
enum ProductGroups {
    private struct Store: Codable { var version: Int; var groups: [ProductGroup] }

    static var path: String { (PermissionBroker.baseDir as NSString).appendingPathComponent("product_groups.json") }

    static func loadManual() -> [ProductGroup] {
        guard let data = FileManager.default.contents(atPath: path),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return [] }
        return store.groups.filter { $0.source == .manual }
    }

    @discardableResult
    static func saveManual(_ groups: [ProductGroup]) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = Store(version: 1, groups: groups.filter { $0.source == .manual })
        guard let data = try? JSONEncoder().encode(store) else { return false }
        do { try data.write(to: URL(fileURLWithPath: path), options: [.atomic]); return true }
        catch { Log.settings.warn("product groups save failed: \(error.localizedDescription)"); return false }
    }

    /// Add a manual group for `root` (normalized, tilde-expanded). Returns the full manual list.
    static func add(root rawRoot: String, name: String? = nil) -> [ProductGroup] {
        let root = normalize(rawRoot)
        var list = loadManual()
        guard !root.isEmpty, !list.contains(where: { $0.root == root }) else { return list }
        let n = (name?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            ?? (root as NSString).lastPathComponent
        list.append(ProductGroup(name: n, root: root, source: .manual))
        saveManual(list)
        return list
    }

    static func remove(root: String) -> [ProductGroup] {
        let list = loadManual().filter { $0.root != root }
        saveManual(list)
        return list
    }

    /// The effective group list: manual ∪ Codex projects ∪ auto-suggestions, de-duplicated by root with
    /// manual winning, then Codex, then auto. Codex projects pointing at a user's HOME or at a single-repo
    /// folder with no sibling repos still count (the user named them a project); auto-suggestions need
    /// 2+ distinct child folders with live chats, so a lone repo never spawns a group of one.
    static func resolve(manual: [ProductGroup], codex: [CodexProject], sessions: [SessionInfo]) -> [ProductGroup] {
        var byRoot: [String: ProductGroup] = [:]
        for g in manual { byRoot[g.root] = g }
        let home = NSHomeDirectory()
        for p in codex {
            for r in p.roots {
                let root = normalize(r)
                // A "project" pointing at $HOME (ChatGPT.app offers it) would swallow every chat — skip it.
                guard !root.isEmpty, root != home, byRoot[root] == nil else { continue }
                byRoot[root] = ProductGroup(name: p.name, root: root, source: .codex)
            }
        }
        // Auto: parent → set of distinct first-level child folders that have a live chat.
        var children: [String: Set<String>] = [:]
        for s in sessions where !s.isRemote {   // another machine's paths can't form a local product
            guard let cwd = s.cwd.map(normalize), !cwd.isEmpty else { continue }
            let parent = (cwd as NSString).deletingLastPathComponent
            guard parent.count > 1, parent != NSHomeDirectory() else { continue }
            children[parent, default: []].insert((cwd as NSString).lastPathComponent)
        }
        for (parent, kids) in children where kids.count >= 2 && byRoot[parent] == nil {
            byRoot[parent] = ProductGroup(name: (parent as NSString).lastPathComponent, root: parent, source: .auto)
        }
        return byRoot.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The group a cwd belongs to: the LONGEST root that is a path-prefix of (or equal to) the cwd.
    static func group(for cwd: String?, in groups: [ProductGroup]) -> ProductGroup? {
        guard let cwd = cwd.map(normalize), !cwd.isEmpty else { return nil }
        return groups
            .filter { cwd == $0.root || cwd.hasPrefix($0.root + "/") }
            .max { $0.root.count < $1.root.count }
    }

    /// Row label inside a product group: the chat's folder relative to the root ("aigirl-backend"), or
    /// nil when the chat sits at the root itself.
    static func relativeLabel(cwd: String?, root: String) -> String? {
        guard let cwd = cwd.map(normalize), cwd.hasPrefix(root + "/") else { return nil }
        let rel = String(cwd.dropFirst(root.count + 1))
        return rel.isEmpty ? nil : rel
    }

    static func normalize(_ p: String) -> String {
        var s = (p.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// `ccemaphore --groups-dump`.
    static func dump() {
        print("manual groups (\(path)):")
        for g in loadManual() { print("  \(g.name)  → \(g.root)") }
        let codex = CodexIndex.projects() ?? []
        print("codex projects: \(codex.count)")
        let all = resolve(manual: loadManual(), codex: codex, sessions: [])
        print("resolved (no live sessions → no auto): \(all.count)")
        for g in all { print("  [\(g.source.rawValue)] \(g.name)  → \(g.root)") }
    }
}
