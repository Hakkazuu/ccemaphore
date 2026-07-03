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

    private static func splitLines(_ data: Data) -> [String] {
        data.split(separator: newline, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }
}
