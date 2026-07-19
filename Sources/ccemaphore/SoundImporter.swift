import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// Why a custom-sound import was rejected. Each maps to a localized, user-facing message.
enum SoundImportError: Error {
    case empty          // zero-length file, or no audible content (duration 0)
    case unreadable     // not a decodable audio file (corrupt / unsupported)
    case tooLong        // longer than the 5-second cap
    case copyFailed     // decoded fine, but we couldn't copy it into our Sounds folder

    var message: String {
        switch self {
        case .empty:      return L("notif.import.error.empty")
        case .unreadable: return L("notif.import.error.unreadable")
        case .tooLong:    return Lf("notif.import.error.tooLong", Int(SoundImporter.maxDuration))
        case .copyFailed: return L("notif.import.error.copyFailed")
        }
    }
}

/// Imports a user-chosen audio file as a custom notification sound: validates it (non-empty, decodable,
/// ≤ 5 seconds), then copies it into our own `<baseDir>/Sounds/` folder so it survives the user deleting
/// the original. Pure file work + one AppKit open panel; playback lives in `SoundPlayer`.
enum SoundImporter {
    /// Hard cap on a custom sound's length. A notification chime should be short; this also bounds how
    /// much audio we copy into the app's storage.
    static let maxDuration: Double = 5.0

    /// Present an open panel for the user to pick an audio file. Main-thread + modal; returns the chosen
    /// URL or nil if cancelled. Activates the app first so the panel comes to the front — ccemaphore runs
    /// as an accessory (no Dock icon), so without this the panel can open behind other windows.
    @MainActor
    static func presentOpenPanel() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]
        panel.prompt = L("notif.import.choose")
        panel.message = Lf("notif.import.message", Int(maxDuration))
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Validate `url` and, on success, copy it into the Sounds folder and register it in the library.
    /// Returns the freshly-created `CustomSound` (already added to `CustomSounds`).
    static func importSound(from url: URL) -> Result<CustomSound, SoundImportError> {
        // 1. Non-empty on disk.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { return .failure(.empty) }

        // 2. Decodable audio + exact duration. AVAudioFile opens only real, readable audio (Core Audio
        //    backs it), so a throw here means "corrupt / unsupported" — exactly our `.unreadable` case.
        guard let duration = audioDuration(url) else { return .failure(.unreadable) }
        guard duration > 0 else { return .failure(.empty) }
        // Small epsilon so a file that is "5.00s" by intent but 5.0004s by sample count isn't rejected.
        guard duration <= maxDuration + 0.05 else { return .failure(.tooLong) }

        // 2b. Playable by NSSound too. AVAudioFile (Core Audio) decodes formats NSSound can't play (e.g.
        //     FLAC), so validate with the SAME backend the chime uses — else a "successful" import would
        //     chime silently forever.
        guard NSSound(contentsOf: url, byReference: true) != nil else { return .failure(.unreadable) }

        // 3. Copy into our own storage under a fresh id, keeping the original extension (lowercased).
        let id = UUID().uuidString
        let ext = url.pathExtension.isEmpty ? "aiff" : url.pathExtension.lowercased()
        let filename = "\(id).\(ext)"
        let dir = CustomSounds.soundsDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(filename))
        do {
            // A stale file at dest is impossible (fresh uuid), but be defensive.
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            Log.notifications.warn("custom sound copy failed: \(error.localizedDescription)")
            return .failure(.copyFailed)
        }

        let sound = CustomSound(id: id, displayName: url.deletingPathExtension().lastPathComponent, filename: filename)
        // Register in the index; if that write fails, roll back the copied file so no orphan leaks (copy
        // and index are two separate disk ops — keep them all-or-nothing).
        guard CustomSounds.save(CustomSounds.load() + [sound]) else {
            try? FileManager.default.removeItem(at: dest)
            Log.notifications.warn("custom sound index write failed; rolled back copy")
            return .failure(.copyFailed)
        }
        Log.notifications.info("custom sound imported: \(sound.displayName) (\(String(format: "%.2f", duration))s)")
        return .success(sound)
    }

    /// Exact duration in seconds via AVAudioFile (sample count ÷ sample rate). Returns nil if the file
    /// can't be opened as audio — which doubles as the decodability check.
    private static func audioDuration(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }
}
