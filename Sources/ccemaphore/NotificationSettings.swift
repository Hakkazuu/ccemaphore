import SwiftUI

/// The notification "type" a chat event belongs to — the granularity at which the user configures
/// visibility, sound, and volume. Maps onto the ribbon kinds:
///  - `.done`       ← green completion notices (`CompletionNotice`)
///  - `.permission` ← live broker decisions (`PendingRequest`) + handed-off native permission prompts
///  - `.question`   ← AskUserQuestion prompts (`AttentionItem.Kind.question`)
enum NotifType: String, CaseIterable, Identifiable, Sendable {
    case done, permission, question
    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .done:       return L("notif.type.done")
        case .permission: return L("notif.type.permission")
        case .question:   return L("notif.type.question")
        }
    }
}

/// User settings for notifications & sound. Three parameters — **show**, **sound**, **volume** — each with
/// a general default that applies to every type, plus an optional per-type override ("Настроить отдельно")
/// that replaces the general value with the type's own.
///
/// Modeled as flat `@Published` properties (like `WidgetSettings`) rather than a nested dictionary so
/// SwiftUI can bind to them directly with `$notif.…` — the framework's own projected-value bindings, which
/// stay correct under Swift 6 strict concurrency (a hand-rolled `Binding` closure that called these
/// main-actor methods would not). The view selects the right synthesized binding per type via a small
/// switch.
///
/// Persisted to `UserDefaults`. Consumed only by the GUI (the ribbon show-gate, the chime, the settings
/// preview) — never by the blocking hook subprocess — so `UserDefaults` is sufficient.
@MainActor
final class NotificationSettings: ObservableObject {
    static let shared = NotificationSettings()

    // MARK: - General defaults (inherited by every type that doesn't override)

    @Published var generalShow: Bool { didSet { d.set(generalShow, forKey: K.generalShow) } }
    @Published var generalSoundToken: String { didSet { d.set(generalSoundToken, forKey: K.generalSound) } }
    @Published var generalVolume: Double { didSet { d.set(generalVolume, forKey: K.generalVolume) } }

    // MARK: - Per-type overrides
    //
    // Each type carries the full trio plus an `override` flag. The trio matters only while `override` is
    // on; otherwise the type inherits the `general*` values. An empty sound token means "inherit the
    // general sound". Stored per-type values persist across toggling the override off and on, so a user's
    // customization is never wiped — EXCEPT that the first time an override opens on a still-untouched
    // type, its volume is seeded from the general volume (see `seedIfPristine`) so the revealed slider
    // matches the inherited sound instead of jumping to 100%.

    @Published var doneOverride: Bool { didSet { d.set(doneOverride, forKey: K.doneOverride); if doneOverride && !oldValue { seedIfPristine(.done) } } }
    @Published var doneShow: Bool { didSet { d.set(doneShow, forKey: K.doneShow) } }
    @Published var doneSoundToken: String { didSet { d.set(doneSoundToken, forKey: K.doneSound) } }
    @Published var doneVolume: Double { didSet { d.set(doneVolume, forKey: K.doneVolume) } }

    @Published var permissionOverride: Bool { didSet { d.set(permissionOverride, forKey: K.permissionOverride); if permissionOverride && !oldValue { seedIfPristine(.permission) } } }
    @Published var permissionShow: Bool { didSet { d.set(permissionShow, forKey: K.permissionShow) } }
    @Published var permissionSoundToken: String { didSet { d.set(permissionSoundToken, forKey: K.permissionSound) } }
    @Published var permissionVolume: Double { didSet { d.set(permissionVolume, forKey: K.permissionVolume) } }

    @Published var questionOverride: Bool { didSet { d.set(questionOverride, forKey: K.questionOverride); if questionOverride && !oldValue { seedIfPristine(.question) } } }
    @Published var questionShow: Bool { didSet { d.set(questionShow, forKey: K.questionShow) } }
    @Published var questionSoundToken: String { didSet { d.set(questionSoundToken, forKey: K.questionSound) } }
    @Published var questionVolume: Double { didSet { d.set(questionVolume, forKey: K.questionVolume) } }

    private let d = UserDefaults.standard

    private enum K {
        static let generalShow   = "notif.general.show"
        static let generalSound  = "notif.general.sound"
        static let generalVolume = "notif.general.volume"
        static let doneOverride  = "notif.done.override"
        static let doneShow      = "notif.done.show"
        static let doneSound     = "notif.done.sound"
        static let doneVolume    = "notif.done.volume"
        static let permissionOverride = "notif.permission.override"
        static let permissionShow     = "notif.permission.show"
        static let permissionSound    = "notif.permission.sound"
        static let permissionVolume   = "notif.permission.volume"
        static let questionOverride = "notif.question.override"
        static let questionShow     = "notif.question.show"
        static let questionSound    = "notif.question.sound"
        static let questionVolume   = "notif.question.volume"
    }

    private init() {
        let d = UserDefaults.standard
        let defaultSound = SoundCatalog.generalDefault.token
        // Everything ON with the app's existing chime — upgrading users see/hear no change until they
        // choose otherwise. Per-type sound defaults to "" → resolves to the general sound (see `sound(for:)`).
        generalShow = d.object(forKey: K.generalShow) as? Bool ?? true
        generalSoundToken = d.string(forKey: K.generalSound) ?? defaultSound
        generalVolume = Self.clampVolume(d.object(forKey: K.generalVolume) as? Double ?? 1.0)

        doneOverride = d.bool(forKey: K.doneOverride)
        doneShow = d.object(forKey: K.doneShow) as? Bool ?? true
        doneSoundToken = d.string(forKey: K.doneSound) ?? ""
        doneVolume = Self.clampVolume(d.object(forKey: K.doneVolume) as? Double ?? 1.0)

        permissionOverride = d.bool(forKey: K.permissionOverride)
        permissionShow = d.object(forKey: K.permissionShow) as? Bool ?? true
        permissionSoundToken = d.string(forKey: K.permissionSound) ?? ""
        permissionVolume = Self.clampVolume(d.object(forKey: K.permissionVolume) as? Double ?? 1.0)

        questionOverride = d.bool(forKey: K.questionOverride)
        questionShow = d.object(forKey: K.questionShow) as? Bool ?? true
        questionSoundToken = d.string(forKey: K.questionSound) ?? ""
        questionVolume = Self.clampVolume(d.object(forKey: K.questionVolume) as? Double ?? 1.0)
    }

    private static func clampVolume(_ v: Double) -> Double { min(1, max(0, v)) }

    // MARK: - Per-type accessors (switch over the flat properties)

    func isOverridden(_ t: NotifType) -> Bool {
        switch t {
        case .done:       return doneOverride
        case .permission: return permissionOverride
        case .question:   return questionOverride
        }
    }

    private func typeShow(_ t: NotifType) -> Bool {
        switch t { case .done: return doneShow; case .permission: return permissionShow; case .question: return questionShow }
    }
    private func typeVolume(_ t: NotifType) -> Double {
        switch t { case .done: return doneVolume; case .permission: return permissionVolume; case .question: return questionVolume }
    }
    private func typeSoundToken(_ t: NotifType) -> String {
        switch t { case .done: return doneSoundToken; case .permission: return permissionSoundToken; case .question: return questionSoundToken }
    }

    /// The first time an override opens on a still-fully-default type, copy the general VOLUME into it so
    /// the revealed slider matches the (inherited) general sound instead of snapping to 100%. Guarded on
    /// ALL three controls being pristine, so once the user edits anything, toggling the override off/on
    /// never re-seeds and never wipes their values. Sound stays "" (inherit) and show stays at its default.
    private func seedIfPristine(_ t: NotifType) {
        guard typeSoundToken(t).isEmpty, typeVolume(t) == 1.0, typeShow(t) else { return }
        switch t {
        case .done:       doneVolume = generalVolume
        case .permission: permissionVolume = generalVolume
        case .question:   questionVolume = generalVolume
        }
    }

    // MARK: - Resolved sounds

    var generalSound: SoundRef { SoundRef(token: generalSoundToken) ?? SoundCatalog.generalDefault }

    /// The type's OWN chosen sound (what its override menu shows), falling back to the general sound when
    /// unset ("" token).
    func sound(for t: NotifType) -> SoundRef { SoundRef(token: typeSoundToken(t)) ?? generalSound }

    // MARK: - Effective (override-aware) resolution — used by the chime and the show-gate

    func effectiveShow(_ t: NotifType) -> Bool { isOverridden(t) ? typeShow(t) : generalShow }
    func effectiveVolume(_ t: NotifType) -> Double { Self.clampVolume(isOverridden(t) ? typeVolume(t) : generalVolume) }
    /// The sound the chime actually plays. Shares one fallback with the UI's `sound(for:)` — an overridden
    /// type with an empty token falls back to `generalSound` (the general channel's chosen sound), NOT the
    /// hard-coded bundled default — so the chime can never disagree with the sound shown in the override menu.
    func effectiveSound(_ t: NotifType) -> SoundRef { isOverridden(t) ? sound(for: t) : generalSound }

    // MARK: - Sound assignment (from the menus)

    func setGeneralSound(_ ref: SoundRef) { generalSoundToken = ref.token }
    func setSound(_ ref: SoundRef, for t: NotifType) {
        switch t {
        case .done:       doneSoundToken = ref.token
        case .permission: permissionSoundToken = ref.token
        case .question:   questionSoundToken = ref.token
        }
    }

    // MARK: - Custom-sound removal housekeeping

    /// After a custom sound file is deleted, repoint any channel (general or a type override) that still
    /// referenced it back to the general default, so it doesn't dangle into silence.
    func customSoundRemoved(_ id: String) {
        let dangling = SoundRef.custom(id).token
        // The general channel has nothing above it to inherit from, so it falls back to the bundled
        // default. A per-type channel returns to "" (inherit the general sound) rather than pinning to the
        // current concrete general token — preserving the inherit relationship so it still follows a later
        // general-sound change.
        if generalSoundToken == dangling { generalSoundToken = SoundCatalog.generalDefault.token }
        if doneSoundToken == dangling { doneSoundToken = "" }
        if permissionSoundToken == dangling { permissionSoundToken = "" }
        if questionSoundToken == dangling { questionSoundToken = "" }
    }
}
