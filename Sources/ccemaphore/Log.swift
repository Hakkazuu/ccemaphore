import Foundation
import os
import AppKit
import UniformTypeIdentifiers

/// File + console logging that is safe across ALL of ccemaphore's processes.
///
/// ccemaphore is multi-process: the long-lived menu-bar GUI, the short-lived `--hook <event>`
/// handlers Claude Code spawns, the blocking `--hook permission` broker, and the diagnostic CLI all
/// run the SAME binary in separate processes. The thing we most want to record — "a hook arrived and
/// here's how we reacted" — happens in those short-lived hook processes, not the GUI. So several
/// processes must append to one log file concurrently.
///
/// That rules out the usual Swift logging libraries (CocoaLumberjack, Puppy, SwiftyBeaver): they
/// assume a single process owns the file (cached descriptor, in-process rotation) and corrupt or race
/// when two processes write. The robust multi-process appender is `open(O_APPEND)` + one `write()`
/// per line (POSIX makes each append atomic on a local FS, so lines never interleave). That's ~20
/// lines of our own code, and libraries only get in its way — hence a small custom logger.
///
/// Each call also mirrors to `os.Logger` (unified logging) so the Xcode console and Console.app show
/// it live. The file lives at `~/Library/Logs/ccemaphore/` (a standard macOS logs location, visible
/// in Console.app ▸ Log Reports and in Finder). App Sandbox is off, so access is unrestricted.
///
/// **Privacy:** only metadata is logged (session-id prefix, event, state, paths) — never chat content
/// — consistent with the app's read-only, never-transmit stance. Files stay on disk, nothing leaves.
enum Log {
    /// Subsystems we care about — these double as the `os.Logger` category and the `[tag]` in the file.
    enum Category: String, Sendable, CaseIterable {
        case app, hooks, permissions, settings, notifications, watcher, usage, focus
    }

    enum Level: String, Sendable {
        case debug = "D", info = "I", warn = "W", error = "E"
        var rank: Int { switch self { case .debug: 0; case .info: 1; case .warn: 2; case .error: 3 } }
        var osType: OSLogType {
            switch self {
            case .debug: .debug
            case .info:  .info
            case .warn:  .default
            case .error: .error
            }
        }
    }

    // One channel per subsystem. `Log.hooks.info("…")` is the call site everywhere.
    static let app           = Channel(.app)
    static let hooks         = Channel(.hooks)
    static let permissions   = Channel(.permissions)
    static let settings      = Channel(.settings)
    static let notifications = Channel(.notifications)
    static let watcher       = Channel(.watcher)
    static let usage         = Channel(.usage)
    static let focus         = Channel(.focus)

    /// A category-bound facade. Messages are `@autoclosure` so a suppressed level (e.g. `debug` in a
    /// Release build) never even builds its string.
    struct Channel: Sendable {
        let category: Category
        private let logger: os.Logger

        init(_ category: Category) {
            self.category = category
            self.logger = os.Logger(subsystem: LogCore.subsystem, category: category.rawValue)
        }

        func debug(_ message: @autoclosure () -> String) { write(.debug, message) }
        func info(_ message: @autoclosure () -> String)  { write(.info, message) }
        func warn(_ message: @autoclosure () -> String)  { write(.warn, message) }
        func error(_ message: @autoclosure () -> String) { write(.error, message) }

        private func write(_ level: Level, _ message: () -> String) {
            guard level.rank >= LogCore.minLevel.rank else { return }
            let text = message()
            logger.log(level: level.osType, "\(text, privacy: .public)")   // → Xcode / Console.app
            LogCore.append(level: level, category: category, message: text) // → file
        }
    }

    // MARK: - Lifecycle

    /// Called once from the GUI (`AppDelegate`). Runs the retention sweep and schedules an hourly one.
    /// Hook subprocesses never call this — they only append (the GUI owns cleanup).
    @MainActor
    static func bootstrapApp() {
        app.info("launch app v\(LogCore.appVersion) pid=\(getpid()) dir=\(LogCore.directory.path)")
        LogCore.sweep()
        let timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in LogCore.sweep() }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Diagnostic CLI

    /// `ccemaphore --logs-path` — print the log directory (for `open`/inspection).
    static func cliPath() { print(LogCore.directory.path) }

    /// `ccemaphore --logs-tail` — print the tail of today's log (headless debugging, no GUI).
    static func cliTail(_ lines: Int = 200) {
        guard let text = try? String(contentsOf: LogCore.currentFileURL(), encoding: .utf8) else {
            print("(no log for today at \(LogCore.currentFileURL().path))"); return
        }
        for l in text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines) { print(l) }
    }
}

/// File-side implementation: paths, the atomic appender, daily + size rotation, and retention. All
/// file mutations are serialized by `lock` *within* a process; cross-process safety comes from
/// `O_APPEND` (atomic appends) and atomic `rename` for rotation.
enum LogCore {
    static let subsystem = "com.hakkazuu.ccemaphore"

    // Defaults chosen for debugging headroom without unbounded disk use.
    static let maxFileBytes  = 5 * 1024 * 1024    // a single day's file rolls to a `.1` segment past this
    static let maxTotalBytes = 50 * 1024 * 1024   // hard ceiling across all kept files
    static let retentionDays = 7

    #if DEBUG
    static let minLevel = Log.Level.debug
    #else
    static let minLevel = Log.Level.info
    #endif

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    /// `~/Library/Logs/ccemaphore` (overridable via `CCEMAPHORE_LOG_DIR` for tests). Identical across
    /// every process so the GUI and the hook subprocesses share one set of files.
    static let directory: URL = {
        if let p = ProcessInfo.processInfo.environment["CCEMAPHORE_LOG_DIR"], !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return lib.appendingPathComponent("Logs/ccemaphore", isDirectory: true)
    }()

    private static let lock = NSLock()

    // DateFormatters aren't Sendable; we only ever touch them under `lock`, hence nonisolated(unsafe).
    private nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Today's log file: `ccemaphore-YYYY-MM-DD.log`. Day boundary is local time (the user's "day").
    static func currentFileURL() -> URL {
        lock.lock(); let d = day.string(from: Date()); lock.unlock()
        return directory.appendingPathComponent("ccemaphore-\(d).log")
    }

    static func append(level: Log.Level, category: Log.Category, message: String) {
        lock.lock(); defer { lock.unlock() }
        let ts = iso.string(from: Date())
        let line = "\(ts)  \(level.rawValue)  [\(category.rawValue)]  pid=\(getpid())  \(message)\n"
        let url = directory.appendingPathComponent("ccemaphore-\(day.string(from: Date())).log")
        ensureDirectory()
        if fileSize(url) >= maxFileBytes { rotate(url) }    // intra-day size cap → roll to `.1`
        write(Data(line.utf8), to: url)
    }

    // MARK: - Retention (GUI-only: on launch + hourly)

    /// Enforce both limits: drop files past `retentionDays`, then delete oldest until total ≤ ceiling.
    static func sweep() {
        lock.lock(); defer { lock.unlock() }
        ensureDirectory()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else { return }
        let logs = items.filter { $0.lastPathComponent.hasPrefix("ccemaphore-") && $0.pathExtension == "log" }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)

        var kept: [(url: URL, mtime: Date, size: Int)] = []
        for url in logs {
            let v = try? url.resourceValues(forKeys: Set(keys))
            let mtime = v?.contentModificationDate ?? .distantPast
            let size = v?.fileSize ?? 0
            if mtime < cutoff { try? fm.removeItem(at: url); continue }
            kept.append((url, mtime, size))
        }

        var total = kept.reduce(0) { $0 + $1.size }
        guard total > maxTotalBytes else { return }
        for entry in kept.sorted(by: { $0.mtime < $1.mtime }) {       // oldest first
            if total <= maxTotalBytes { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    // MARK: - Primitives (callers already hold `lock`)

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func fileSize(_ url: URL) -> Int {
        var st = stat()
        return stat(url.path, &st) == 0 ? Int(st.st_size) : 0
    }

    /// One `write()` under `O_APPEND` — atomic vs. concurrent appends from other ccemaphore processes,
    /// so interleaved lines never tear. Open-per-write (vs. a cached fd) keeps us correct across the
    /// daily rollover and size rotation below, where a held descriptor would keep writing a stale inode.
    private static func write(_ data: Data, to url: URL) {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress, raw.count > 0 { _ = Darwin.write(fd, base, raw.count) }
        }
    }

    /// Size-cap rotation: rename today's file to a single `.1` segment (overwriting any prior one),
    /// then the next append recreates a fresh today file. Bounds a heavy day to ~2× `maxFileBytes`;
    /// the global ceiling is still enforced by `sweep()`. `rename` is atomic, so a concurrent hook
    /// either sees the old or the new name — never a torn file. A lost race (source already moved)
    /// just no-ops.
    private static func rotate(_ url: URL) {
        let rolled = directory.appendingPathComponent(
            url.deletingPathExtension().lastPathComponent + ".1.log")
        let fm = FileManager.default
        try? fm.removeItem(at: rolled)
        try? fm.moveItem(at: url, to: rolled)
    }
}

/// "Save logs…" — zips the log directory and lets the user place it anywhere. App Sandbox is off, so
/// a plain `NSSavePanel` + copy works without security-scoped bookmarks.
enum LogExport {
    @MainActor
    static func presentSavePanel() {
        let panel = NSSavePanel()
        panel.title = L("logs.save.title")
        panel.nameFieldStringValue = "ccemaphore-logs-\(LogExport.stamp()).zip"
        panel.allowedContentTypes = [.zip]
        panel.isExtensionHidden = false
        NSApp.activate(ignoringOtherApps: true)   // accessory app: bring the panel forward
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            let ok = LogExport.zipLogs(to: dest)
            Log.app.info("export logs → \(dest.path) ok=\(ok)")
        }
    }

    /// "Show logs in Finder" — reveal the log directory so the user can grab today's `.log` file
    /// directly (or just confirm where logs live). Creates the folder first so reveal never no-ops on a
    /// fresh install that hasn't written a line yet.
    @MainActor
    static func revealInFinder() {
        try? FileManager.default.createDirectory(at: LogCore.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: LogCore.directory.path)
        Log.app.info("reveal logs dir \(LogCore.directory.path)")
    }

    /// Zip the directory via `NSFileCoordinator(.forUploading)` — coordinating a directory read with
    /// that option produces a temporary `.zip`, so we avoid spawning `/usr/bin/zip`. Copy it to `dest`.
    @discardableResult
    static func zipLogs(to dest: URL) -> Bool {
        LogCore.sweep()   // tidy before handing the bundle off
        try? FileManager.default.createDirectory(at: LogCore.directory, withIntermediateDirectories: true)
        var coordError: NSError?
        var copied = false
        NSFileCoordinator().coordinate(readingItemAt: LogCore.directory, options: [.forUploading],
                                       error: &coordError) { zipped in
            try? FileManager.default.removeItem(at: dest)
            copied = (try? FileManager.default.copyItem(at: zipped, to: dest)) != nil
        }
        return copied && coordError == nil
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}
