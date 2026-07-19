import Foundation

/// A reference to a notification sound. One of four concrete things: our own bundled chime, a macOS
/// system sound (played by name — free, already on every Mac, zero bundling/licensing), a user-imported
/// custom sound (by id → a file under `<baseDir>/Sounds/`), or explicit silence.
///
/// Persisted as a compact, round-trippable string `token` so it lives cleanly in `UserDefaults` next to
/// the rest of the notification settings. There is deliberately NO `.inherit` case: inheritance from the
/// "general" defaults is modeled one level up, per notification type, by `NotificationSettings` (the
/// "Настроить отдельно" toggle), so a *resolved* `SoundRef` is always a concrete sound or silence.
enum SoundRef: Equatable, Hashable, Sendable {
    case silent
    case bundled(String)   // Bundle.main resource base name (our shipped chime), extension resolved at load
    case system(String)    // NSSound(named:) — a /System/Library/Sounds name (Glass, Ping, …)
    case custom(String)    // CustomSound.id → a file in <baseDir>/Sounds/

    /// Compact token for UserDefaults. `kind:value`, or the bare word `silent`.
    var token: String {
        switch self {
        case .silent:          return "silent"
        case .bundled(let n):  return "bundled:\(n)"
        case .system(let n):   return "system:\(n)"
        case .custom(let id):  return "custom:\(id)"
        }
    }

    /// Parse a persisted token. Returns nil for an empty/garbled string so callers can fall back to a
    /// sane default rather than crashing on a hand-edited or future-version defaults value.
    init?(token: String) {
        if token == "silent" { self = .silent; return }
        guard let colon = token.firstIndex(of: ":") else { return nil }
        let kind = String(token[..<colon])
        let value = String(token[token.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        switch kind {
        case "bundled": self = .bundled(value)
        case "system":  self = .system(value)
        case "custom":  self = .custom(value)
        default:        return nil
        }
    }
}

/// One selectable built-in sound in a settings menu: its `SoundRef` plus a display name. Preset names are
/// proper nouns (`Glass`, `Ping`, …, and our own `ccemaphore`), so they are NOT localized.
struct SoundPreset: Identifiable, Sendable {
    let ref: SoundRef
    let name: String
    var id: String { ref.token }
}

/// The built-in sound catalog: our shipped chime plus a curated set of macOS system sounds. Kept separate
/// from playback (`SoundPlayer`) and from persistence (`NotificationSettings` / `CustomSounds`) so it's a
/// pure, testable list.
enum SoundCatalog {
    /// The app's shipped chime — the sound ccemaphore has always used for its ribbon alert. The `.aiff`
    /// resource is `ccemaphore_notification.aiff` in `Resources/`; the extension is resolved at load time
    /// (`SoundPlayer.load`) so the token stays extension-agnostic.
    static let bundledDefault = SoundRef.bundled("ccemaphore_notification")

    /// The default "general" sound on first run: the existing chime, so upgrading users hear no change
    /// until they choose otherwise.
    static var generalDefault: SoundRef { bundledDefault }

    /// Presets shown in every sound menu — our chime first, then a handful of macOS system sounds. These
    /// resolve via `NSSound(named:)` with no bundled asset, so adding/removing one is a one-line change.
    static let presets: [SoundPreset] = [
        SoundPreset(ref: bundledDefault,      name: "ccemaphore"),
        SoundPreset(ref: .system("Glass"),     name: "Glass"),
        SoundPreset(ref: .system("Ping"),      name: "Ping"),
        SoundPreset(ref: .system("Hero"),      name: "Hero"),
        SoundPreset(ref: .system("Submarine"), name: "Submarine"),
        SoundPreset(ref: .system("Funk"),      name: "Funk"),
        SoundPreset(ref: .system("Pop"),       name: "Pop"),
        SoundPreset(ref: .system("Tink"),      name: "Tink"),
    ]

    /// Human label for a resolved `ref`: a preset name, an imported sound's own display name (looked up in
    /// `customs`), the localized "Без звука", or — if a `custom:` id no longer resolves (its file was
    /// deleted) — a localized "removed" placeholder so a dangling reference is legible rather than raw.
    static func displayName(for ref: SoundRef, customs: [CustomSound]) -> String {
        switch ref {
        case .silent:
            return L("notif.sound.silent")
        case .custom(let id):
            return customs.first { $0.id == id }?.displayName ?? L("notif.sound.missing")
        case .bundled, .system:
            // A preset that no longer exists (version drift / hand-edited defaults) shows the localized
            // "removed" placeholder rather than leaking its raw `kind:value` token as UI text.
            return presets.first { $0.ref == ref }?.name ?? L("notif.sound.missing")
        }
    }
}

/// A user-imported custom sound. `filename` is the copy we own under `<baseDir>/Sounds/` (`<uuid>.<ext>`);
/// `displayName` is the original file's name, shown in the menu. We keep our own copy precisely so the
/// user can delete the original (e.g. out of ~/Downloads) without breaking the notification.
struct CustomSound: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var displayName: String
    var filename: String
}

/// Persistent library of imported custom sounds. Stored as JSON at `<baseDir>/sounds.json` with the audio
/// files alongside in `<baseDir>/Sounds/` — mirroring the `TrustedCommands` / `RemoteHosts` pattern
/// (atomic write, `CCEMAPHORE_BASE_DIR`-aware) so it survives app reinstalls and lives with the rest of
/// ccemaphore's on-disk state, not buried in an opaque UserDefaults blob.
enum CustomSounds {
    private struct Store: Codable { var version: Int; var sounds: [CustomSound] }

    /// Directory that holds the copied audio files.
    static var soundsDir: String { (PermissionBroker.baseDir as NSString).appendingPathComponent("Sounds") }
    /// The library index.
    static var path: String { (PermissionBroker.baseDir as NSString).appendingPathComponent("sounds.json") }

    static func fileURL(for sound: CustomSound) -> URL {
        URL(fileURLWithPath: (soundsDir as NSString).appendingPathComponent(sound.filename))
    }
    /// Resolve a stored sound's on-disk URL by id (nil if the id isn't in the library).
    static func fileURL(forId id: String) -> URL? {
        load().first { $0.id == id }.map(fileURL(for:))
    }

    static func load() -> [CustomSound] {
        guard let data = FileManager.default.contents(atPath: path),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return [] }
        return store.sounds
    }

    @discardableResult
    static func save(_ sounds: [CustomSound]) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Store(version: 1, sounds: sounds)) else { return false }
        do { try data.write(to: URL(fileURLWithPath: path), options: [.atomic]); return true }
        catch { Log.notifications.warn("sounds.json write failed: \(error.localizedDescription)"); return false }
    }

    /// Remove a sound from the library AND delete its file. Any settings still pointing at it are repaired
    /// separately by `NotificationSettings.customSoundRemoved`.
    @discardableResult
    static func remove(id: String) -> [CustomSound] {
        var sounds = load()
        if let s = sounds.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: fileURL(for: s))
        }
        sounds.removeAll { $0.id == id }
        save(sounds)
        return sounds
    }
}
