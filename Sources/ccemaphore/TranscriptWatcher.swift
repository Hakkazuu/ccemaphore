import Foundation
import CoreServices

/// Watches a directory TREE via FSEvents and reports the set of changed file paths per batch.
///
/// FSEvents (not DispatchSource) because it watches a whole subtree from a single root and picks up
/// newly-created nested session/sub-agent directories automatically. The C callback can't capture
/// state, so `self` is threaded through `FSEventStreamContext.info`; all stream work is confined to
/// one dispatch queue, which is why `@unchecked Sendable` is sound here.
///
/// Ownership: the stream RETAINS `self` (via the context retain/release callbacks) for its lifetime,
/// so the callback can never fire into freed memory. `self` is released only when `stop()` releases
/// the stream — so a watcher that is never stopped simply lives as long as its stream (the intended
/// behaviour for our long-lived singletons), with no use-after-free either way.
final class TranscriptWatcher: @unchecked Sendable {
    private let path: String
    private let onChange: @Sendable ([String]) -> Void
    /// Called when FSEvents signals coalesced/dropped events (the per-file path list is incomplete).
    private let onFullRescan: (@Sendable () -> Void)?
    private let queue = DispatchQueue(label: "ccemaphore.fsevents")
    private var stream: FSEventStreamRef?

    init(path: String,
         onChange: @escaping @Sendable ([String]) -> Void,
         onFullRescan: (@Sendable () -> Void)? = nil) {
        self.path = path
        self.onChange = onChange
        self.onFullRescan = onFullRescan
    }

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, let stream = self.stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)   // drops the stream's retain on self
            self.stream = nil
        }
    }

    private func startOnQueue() {
        guard stream == nil else { return }

        // info is passed unretained; the retain/release callbacks below make FSEvents take its own
        // strong reference, keeping `self` alive for the stream's whole lifetime.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { ptr in
                guard let ptr else { return nil }
                return UnsafeRawPointer(Unmanaged<TranscriptWatcher>.fromOpaque(ptr).retain().toOpaque())
            },
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<TranscriptWatcher>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info, numEvents > 0 else { return }
            let watcher = Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
            // With kFSEventStreamCreateFlagUseCFTypes, eventPaths is a CFArray of CFString.
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let paths = (cfArray as NSArray).compactMap { $0 as? String }

            // When events are coalesced or the kernel/user buffer overflows, FSEvents reports a
            // parent-directory path with a "must rescan" flag instead of the individual files. Those
            // paths classify as ignored and the real changes would be lost — so trigger a full rescan.
            let rescanMask = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs |
                kFSEventStreamEventFlagUserDropped |
                kFSEventStreamEventFlagKernelDropped |
                kFSEventStreamEventFlagRootChanged
            )
            var needsRescan = false
            for i in 0..<numEvents where eventFlags[i] & rescanMask != 0 { needsRescan = true; break }

            if !paths.isEmpty { watcher.onChange(paths) }
            if needsRescan { watcher.onFullRescan?() }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |   // per-file paths, so we know which tail to read
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,                                   // latency: coalesce bursts of writes
            flags
        ) else {
            // Stream creation failed → this watcher can never fire. Surface it: a silent nil here used
            // to make mode A (the whole always-on premise) die invisibly, undiagnosable from the log.
            Log.watcher.error("FSEventStreamCreate failed for \(path) — watcher will never fire")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            // Start failed → tear the half-built stream down and stay nil, so we don't pretend to watch.
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)   // balances the retain FSEventStreamCreate took on self
            Log.watcher.error("FSEventStreamStart failed for \(path) — watcher will never fire")
            return
        }
        self.stream = stream
        Log.watcher.info("watching \(path)")
    }
}
