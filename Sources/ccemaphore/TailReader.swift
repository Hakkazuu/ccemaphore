import Foundation

/// Reads the tail of a (possibly huge, append-only) JSONL transcript without loading the whole file.
///
/// The corpus contains multi-MB JSON lines (embedded tool_result attachments). A naive
/// `tail -c N | jq` lands mid-line and the parse aborts, dropping a live session to gray — the
/// dominant bug the adversarial pass found. So this reader is strictly LINE-AWARE: it seeks back a
/// window, discards the first (partial) line, and returns only complete lines. If the window lands
/// entirely inside one giant line (no newline at all), it falls back to reading the whole file so
/// the last real record is never lost.
///
/// Two accepted trade-offs: if the window happens to start exactly on a line boundary, one complete
/// (oldest) line is dropped — immaterial, since only the *last* lines drive the heuristic; and the
/// giant-line fallback may load a multi-MB file, which is rare and runs off the main actor. Confining
/// the partial-line drop to the seek boundary is also what keeps a multi-byte UTF-8 char that's split
/// across the window edge out of the decoded output (it lives in the discarded first line).
enum TailReader {
    static let defaultWindow: UInt64 = 512 * 1024
    private static let newline = UInt8(ascii: "\n")

    /// Returns the complete lines contained in the last `window` bytes of the file (in file order).
    static func tailLines(path: String, window: UInt64 = defaultWindow) -> [String] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        do {
            let size = try h.seekToEnd()
            if size == 0 { return [] }

            let start: UInt64 = size > window ? size - window : 0
            try h.seek(toOffset: start)
            guard var data = try h.readToEnd(), !data.isEmpty else { return [] }

            if start != 0 {
                if let nl = data.firstIndex(of: newline) {
                    // Drop the partial first line so parsing starts on a record boundary.
                    data = Data(data[data.index(after: nl)...])
                } else {
                    // Window sits inside one giant line — re-read the whole file to recover records.
                    try h.seek(toOffset: 0)
                    data = (try h.readToEnd()) ?? Data()
                }
            }
            return splitLines(data)
        } catch {
            return []
        }
    }

    /// A resumable read of a file that is still being appended to (a Codex rollout, see
    /// `CodexSessionStore.poll`): the complete lines from `offset` to EOF, `resumeAt` — the offset just past
    /// the LAST newline, so a line the writer is still in the middle of is left for the next call instead of
    /// being parsed half-written — and the file size seen. `offset == nil` starts `window` bytes before EOF
    /// and drops the partial first line, with the same giant-line whole-file fallback as `tailLines`.
    /// nil ⇒ unreadable, or the file is now SHORTER than `offset` (replaced/truncated — start over).
    static func readResumable(path: String, from offset: UInt64?,
                              window: UInt64 = defaultWindow) -> (lines: [String], resumeAt: UInt64, size: UInt64)? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        do {
            let size = try h.seekToEnd()
            var start: UInt64
            if let offset {
                guard offset <= size else { return nil }
                start = offset
            } else {
                start = size > window ? size - window : 0
            }
            if start == size { return ([], start, size) }
            try h.seek(toOffset: start)
            var data = (try h.readToEnd()) ?? Data()
            var first = 0   // index of the first complete line in `data`
            if offset == nil, start != 0 {
                // The window must hold at least one COMPLETE line after the partial one it starts in;
                // otherwise it sits inside one giant line (possibly the last one, newline-terminated) and
                // only the whole file has a record to give.
                if let nl = data.firstIndex(of: newline), let last = data.lastIndex(of: newline), last > nl {
                    first = nl + 1
                } else {
                    try h.seek(toOffset: 0)
                    data = (try h.readToEnd()) ?? Data()
                    start = 0
                }
            }
            guard let last = data.lastIndex(of: newline), last >= first else {
                return ([], start + UInt64(first), size)
            }
            return (splitLines(data.subdata(in: first..<(last + 1))), start + UInt64(last + 1), size)
        } catch {
            return nil
        }
    }

    /// The byte-window → complete-lines transform, for a caller that already holds a tail-window `Data`
    /// (e.g. `RemoteTranscriptPoller`, whose bytes arrive over SSH from `tail -c`, not a local
    /// `FileHandle`). Same two safety rules as `tailLines`: when the window was seeked into the middle of
    /// the file (`seekedIntoMiddle`), drop the partial FIRST line so a multi-byte UTF-8 char split across
    /// the window edge can't poison the decode; and decode each line LOSSILY so an invalid byte never
    /// nils the whole tail. The giant-line whole-file recovery (window entirely inside one line, no
    /// newline) needs the file handle, so a windowed caller gets an empty result for that rare case —
    /// behaviourally the same as the previous strict decode, which also produced no records there.
    static func completeLines(inWindow data: Data, seekedIntoMiddle: Bool) -> [String] {
        var data = data
        if seekedIntoMiddle {
            guard let nl = data.firstIndex(of: newline) else { return [] }
            data = Data(data[data.index(after: nl)...])
        }
        return splitLines(data)
    }

    private static func splitLines(_ data: Data) -> [String] {
        data.split(separator: newline, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }
}
