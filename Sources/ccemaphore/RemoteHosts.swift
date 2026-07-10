import Foundation

/// A remote machine (reachable over SSH) running VS Code + the Claude Code extension, whose sessions
/// ccemaphore polls and whose permission prompts it can answer without opening that machine's window.
struct RemoteHost: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var label: String
    var hostname: String
    var sshUser: String?
    var port: Int?
    var identityFile: String?
    /// If true, only `hostname` (treated as a `~/.ssh/config` `Host` alias) is used to connect —
    /// `sshUser`/`port`/`identityFile` are ignored (left to the user's ssh_config).
    var useSSHConfigOnly: Bool = false
    var enabled: Bool = true
    /// Override for the remote `~/.claude/projects` root, if it isn't at the default location.
    var remoteProjectsRoot: String? = nil
    /// "Darwin" / "Linux", detected via `uname -s` the first time a connection succeeds (see
    /// `RemoteExec.testConnection`). Nil until a successful connection has been made at least once.
    var platform: String? = nil

    init(
        id: String = UUID().uuidString, label: String, hostname: String, sshUser: String? = nil,
        port: Int? = nil, identityFile: String? = nil, useSSHConfigOnly: Bool = false,
        enabled: Bool = true, remoteProjectsRoot: String? = nil, platform: String? = nil
    ) {
        self.id = id
        self.label = label
        self.hostname = hostname
        self.sshUser = sshUser
        self.port = port
        self.identityFile = identityFile
        self.useSSHConfigOnly = useSSHConfigOnly
        self.enabled = enabled
        self.remoteProjectsRoot = remoteProjectsRoot
        self.platform = platform
    }
}

/// Persistent list of configured remote hosts. Stored as JSON at `<baseDir>/remote_hosts.json`
/// (honors `CCEMAPHORE_BASE_DIR`, same as `TrustedCommands`'s `trusted.json`) so both the GUI and
/// headless `--remote-*` diagnostic invocations read the same source of truth.
enum RemoteHosts {
    private struct Store: Codable { var version: Int; var hosts: [RemoteHost] }

    static var path: String {
        (PermissionBroker.baseDir as NSString).appendingPathComponent("remote_hosts.json")
    }

    static func load() -> [RemoteHost] {
        guard let data = FileManager.default.contents(atPath: path),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return [] }
        return store.hosts
    }

    @discardableResult
    static func save(_ hosts: [RemoteHost]) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Store(version: 1, hosts: hosts)) else { return false }
        do { try data.write(to: URL(fileURLWithPath: path), options: [.atomic]); return true }
        catch { Log.permissions.warn("remote_hosts.json write failed: \(error.localizedDescription)"); return false }
    }

    @discardableResult
    static func add(_ host: RemoteHost) -> [RemoteHost] {
        var hosts = load()
        hosts.append(host)
        save(hosts)
        return hosts
    }

    @discardableResult
    static func update(_ host: RemoteHost) -> [RemoteHost] {
        var hosts = load()
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return hosts }
        hosts[idx] = host
        save(hosts)
        return hosts
    }

    @discardableResult
    static func remove(id: String) -> [RemoteHost] {
        var hosts = load()
        hosts.removeAll { $0.id == id }
        save(hosts)
        return hosts
    }

    /// Resolve a host by id, (case-insensitive) label, or hostname/IP — used by the `--remote-*`
    /// diagnostic flags and by the UI, which take a friendlier command-line argument than a raw UUID.
    /// Hostname match is included because the label and hostname are very often the same string (a user
    /// who just typed the IP into both fields), so "no such remote host: 10.0.6.209" was a common,
    /// confusing miss when only id/label were tried.
    static func resolve(_ idOrLabelOrHostname: String) -> RemoteHost? {
        let hosts = load()
        if let byId = hosts.first(where: { $0.id == idOrLabelOrHostname }) { return byId }
        if let byLabel = hosts.first(where: { $0.label.caseInsensitiveCompare(idOrLabelOrHostname) == .orderedSame }) {
            return byLabel
        }
        return hosts.first { $0.hostname.caseInsensitiveCompare(idOrLabelOrHostname) == .orderedSame }
    }

    static func dump() {
        let hosts = load()
        print("remote_hosts.json (\(path))")
        guard !hosts.isEmpty else { print("  (no remote hosts configured)"); return }
        for h in hosts {
            let target = h.useSSHConfigOnly ? h.hostname : "\(h.sshUser.map { "\($0)@" } ?? "")\(h.hostname)\(h.port.map { ":\($0)" } ?? "")"
            print("  \(h.enabled ? "●" : "○") \(h.label)  \(target)  [\(h.id)]\(h.platform.map { " (\($0))" } ?? "")")
        }
    }
}
