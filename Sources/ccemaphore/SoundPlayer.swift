import AppKit

/// Plays notification sounds. One shared, main-actor instance used by both the ribbon chime
/// (`FloatingWidgetController`) and the settings preview button, so at most one alert sound is ever
/// audible at a time — a fresh `play` stops the previous one instead of layering into noise.
///
/// `NSSound` is the right tool here: one-shot playback of a bundled/system/file sound with a per-instance
/// `volume`, no session/engine setup, no entitlements. Instances are cached by their `SoundRef.token` so
/// repeated chimes don't re-read the file each time; volume is (re)applied on every `play` since the same
/// cached instance may be reused by different channels at different volumes.
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    private var cache: [String: NSSound] = [:]

    /// Play `ref` at `volume` (0…1). Silence — or a sound that fails to load (missing system name, deleted
    /// custom file) — is a no-op. Stops the same instance first so rapid re-triggers don't overlap.
    func play(_ ref: SoundRef, volume: Double) {
        guard let sound = sound(for: ref) else { return }
        // Single-sound invariant: silence EVERY cached instance first (not just this ref's), so a new
        // chime never layers over a still-ringing preview or a different-ref chime — the cache is keyed
        // by token, so stopping only this instance would leave a differently-keyed one audible.
        stopAll()
        sound.volume = Float(min(1, max(0, volume)))
        sound.play()
    }

    /// Preview a sound from the settings UI. Identical to `play` (which already guarantees exclusivity);
    /// named separately for call-site clarity at the audition buttons.
    func preview(_ ref: SoundRef, volume: Double) { play(ref, volume: volume) }

    func stopAll() { for s in cache.values { s.stop() } }

    private func sound(for ref: SoundRef) -> NSSound? {
        if let cached = cache[ref.token] { return cached }
        guard let s = load(ref) else { return nil }
        cache[ref.token] = s
        return s
    }

    private func load(_ ref: SoundRef) -> NSSound? {
        switch ref {
        case .silent:
            return nil
        case .system(let name):
            return NSSound(named: NSSound.Name(name))
        case .bundled(let name):
            // The bundled chime is `.aiff`; try a small family so the token stays extension-agnostic.
            for ext in ["aiff", "caf", "wav", "m4a", "mp3"] {
                if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                    return NSSound(contentsOf: url, byReference: true)
                }
            }
            return nil
        case .custom(let id):
            guard let url = CustomSounds.fileURL(forId: id),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return NSSound(contentsOf: url, byReference: true)
        }
    }
}
