import Foundation
import Darwin

/// Liveness/readiness beacon the GUI publishes so the blocking `--hook permission` handler can tell —
/// cheaply, and from a *separate process* — whether the menu-bar app is actually running and able to
/// answer a permission request. Without it the hook can't distinguish "app is up, light on screen,
/// about to show the permission ribbon" from "app is closed, nobody will ever answer", so it blocks
/// for the full timeout.
///
/// Contract: a single JSON file at `<baseDir>/presence.json` (baseDir honors `CCEMAPHORE_BASE_DIR`, so
/// tests can redirect it). Written ONLY by the running GUI; read ONLY by the hook. It sits at the root
/// of baseDir — NOT inside `pending/` — so republishing it never trips the GUI's FSEvents watchers.
///
/// Liveness is decided by the kernel, not by a timestamp: `kill(pid,0)` catches a crashed/closed app
/// instantly (no staleness window), and `proc_pidpath` confirms the pid is still OUR binary — closing
/// the one hole in pid files, where the OS reuses a dead pid for an unrelated process.
enum AppPresence {
    static var path: String {
        (PermissionBroker.baseDir as NSString).appendingPathComponent("presence.json")
    }

    /// What the hook needs to decide how — and whether — to wait. `widgetVisible` reports whether the
    /// floating light is on screen right now: that's where the permission ribbon appears, so it's the
    /// surface the user answers at. Visible → give a real wait window; hidden → nothing to act on.
    enum Readiness {
        case notRunning                  // no GUI, or it crashed / is mid-startup
        case ready(widgetVisible: Bool)
    }

    /// The mutable part the GUI republishes; everything else (pid/startedAt/version) is process-stable.
    struct WrittenState: Equatable {
        let ready: Bool
        let widgetVisible: Bool
    }

    private struct Snapshot: Codable {
        let pid: Int32
        let startedAt: String
        let ready: Bool
        let version: String
        /// Optional so a beacon written by an older build still decodes; missing → hidden (the
        /// conservative, no-wait reading).
        let widgetVisible: Bool?
    }

    // MARK: - GUI side (writer)

    private static let pid = getpid()
    private static let startedAt = Date()

    /// Republish the beacon. Cheap atomic write of a tiny file; callers throttle to real changes.
    static func write(_ state: WrittenState) {
        let snap = Snapshot(pid: pid, startedAt: startedAt.formatted(.iso8601),
                            ready: state.ready, version: appVersion, widgetVisible: state.widgetVisible)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        }
    }

    /// Clean-exit removal. Correctness does NOT depend on this — a crash/force-quit skips it, but the
    /// hook's `kill(pid,0)` check then reports `notRunning` anyway. This just makes the common case tidy.
    static func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Hook side (reader)

    static func readiness() -> Readiness {
        guard let data = FileManager.default.contents(atPath: path),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return .notRunning
        }
        guard isAlive(snap.pid) else {
            try? FileManager.default.removeItem(atPath: path)   // GC a beacon a crashed app left behind
            return .notRunning
        }
        guard snap.ready else { return .notRunning }            // GUI mid-startup / shutting down
        return .ready(widgetVisible: snap.widgetVisible ?? false)
    }

    /// True iff `pid` is a live process that is still OUR executable (so a reused pid can't fool us).
    private static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 { return errno == EPERM }   // ESRCH → gone; EPERM → alive (other owner)
        return isOurBinary(pid)
    }

    private static func isOurBinary(_ pid: Int32) -> Bool {
        var buf = [CChar](repeating: 0, count: 4096)     // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return true }  // can't tell → assume ours
        let running = URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
        let ours = URL(fileURLWithPath: HooksInstaller.executablePath).resolvingSymlinksInPath().path
        return running == ours
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// The broker's wait window for a readiness — shared by the hook and `--presence-dump` so the two
    /// can't drift. Widget hidden / app not running → 0: there's no on-screen surface (the ribbon at the
    /// light) for the user to act on, so hand straight to Claude's own prompt.
    static func waitWindow(_ r: Readiness) -> TimeInterval {
        switch r {
        case .notRunning:
            return 0
        case .ready(let widgetVisible):
            return widgetVisible ? Tuning.permissionPollTimeout : 0
        }
    }

    // MARK: - Diagnostics (`ccemaphore --presence-dump`)

    static func dump() {
        if let data = FileManager.default.contents(atPath: path), !data.isEmpty {
            print(String(data: data, encoding: .utf8) ?? "<unreadable>")
        } else {
            print("presence: <none> (\(path))")
        }
        let r = readiness()
        let verdict: String
        switch r {
        case .notRunning:
            verdict = "notRunning → hook answers .ask immediately (no wait)"
        case .ready(let widgetVisible):
            verdict = "ready (widget=\(widgetVisible ? "visible" : "hidden")) "
                + "→ hook waits up to \(Int(waitWindow(r)))s"
        }
        print("readiness: \(verdict)")
    }
}
