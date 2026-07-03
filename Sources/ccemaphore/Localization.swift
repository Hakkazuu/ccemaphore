import Foundation
import SwiftUI

/// Runtime localization with **dynamic** language switching (no relaunch).
///
/// All UI strings live in `Localizable.xcstrings` (source language: English). Instead of relying on
/// SwiftUI's automatic, launch-time bundle resolution, we resolve every string ourselves through the
/// `.lproj` bundle of the *currently selected* language. That lets the picker in Settings switch the
/// whole UI live: views observe `LocalizationManager`, so changing the language re-renders them and
/// every `L(...)` / `Lf(...)` call re-reads from the new bundle.
///
/// Why a hand-rolled layer (vs. catalog-native plurals): the hook subprocess (`--hook permission`)
/// and notifications run outside SwiftUI, and plural selection must stay deterministic
/// across all five languages. So plurals are resolved by an explicit CLDR selector against per-category
/// keys (`noun.chats.one`, `noun.chats.few`, …) rather than `%#@…@` runtime expansion.

/// A language the app ships. `.system` follows the macOS preferred languages (falling back to English).
enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case system, en, ru, es, de, fr

    var id: String { rawValue }

    /// Explicit BCP-47 code, or `nil` for "follow the system".
    var code: String? { self == .system ? nil : rawValue }

    /// Picker label. Real languages use their own autonym (so a speaker can always find their language);
    /// `.system` is the only one that needs translating.
    var displayName: String {
        switch self {
        case .system: return L("language.system")
        case .en: return "English"
        case .ru: return "Русский"
        case .es: return "Español"
        case .de: return "Deutsch"
        case .fr: return "Français"
        }
    }

    /// Round-badge flag for this language; `nil` for `.system` (rendered as a globe). A flag is a
    /// country, not a language — these are conventional picker choices and easy to swap.
    var flag: String? {
        switch self {
        case .system: return nil
        case .en: return "🇬🇧"
        case .ru: return "🇷🇺"
        case .es: return "🇪🇸"
        case .de: return "🇩🇪"
        case .fr: return "🇫🇷"
        }
    }

    /// Leading glyph for a dropdown item (a globe stands in for "system").
    var menuGlyph: String { flag ?? "🌐" }
}

/// CLDR cardinal plural category. We only ever produce integers, so `.other` doubles as the catch-all.
enum PluralCategory: String { case one, few, many, other }

enum Plural {
    /// The plural category for `n` in `code`'s language. Covers the five shipped languages; anything
    /// else uses the English-style one/other rule.
    static func category(_ n: Int, code: String) -> PluralCategory {
        let m = abs(n)
        switch code {
        case "ru":
            let mod10 = m % 10, mod100 = m % 100
            if mod10 == 1 && mod100 != 11 { return .one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return .few }
            return .many
        case "fr":
            return (m == 0 || m == 1) ? .one : .other   // French "one" covers 0 and 1
        default:                                         // en, de, es, and any fallback
            return m == 1 ? .one : .other
        }
    }
}

/// Thread-safe string resolver. Free of any actor isolation so it works identically in the SwiftUI app,
/// the blocking hook subprocess, and the notification delegate.
enum Loc {
    /// UserDefaults key holding the selected `AppLanguage.rawValue`. The hook subprocess shares this
    /// domain (same bundle id), so a status/permission summary it writes matches the GUI's language.
    static let defaultsKey = "appLanguage"

    /// Languages we actually ship an `.lproj` for — used to resolve `.system` to a concrete bundle.
    static let supported = ["en", "ru", "es", "de", "fr"]

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cachedCode: String?
    private nonisolated(unsafe) static var cachedBundle: Bundle?
    private nonisolated(unsafe) static var cachedLocale: Locale?
    /// In-memory language override that wins over UserDefaults. Used ONLY by `--l10n-check` — a
    /// single-threaded, headless CLI that never runs alongside the GUI or the hook subprocesses — so the
    /// unlocked read in `effectiveCode()` is knowingly safe. Do NOT add `lock` there: `effectiveCode()`
    /// is also called from inside `resolve()` while `lock` is already held, and NSLock isn't recursive
    /// (it would deadlock).
    private nonisolated(unsafe) static var overrideCode: String?

    static func setOverride(_ code: String?) {
        lock.lock()
        overrideCode = code
        cachedCode = nil; cachedBundle = nil; cachedLocale = nil
        lock.unlock()
    }

    static func storedLanguage() -> AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }

    static func setStoredLanguage(_ lang: AppLanguage) {
        lock.lock()
        UserDefaults.standard.set(lang.rawValue, forKey: defaultsKey)
        cachedCode = nil; cachedBundle = nil; cachedLocale = nil   // force re-resolve on next access
        lock.unlock()
    }

    /// The concrete language code in effect: an explicit selection, else the first system-preferred
    /// language we ship, else English.
    static func effectiveCode() -> String {
        if let o = overrideCode { return o }
        if let c = storedLanguage().code { return c }
        for pref in Locale.preferredLanguages {
            let base = String(pref.prefix(2)).lowercased()
            if supported.contains(base) { return base }
        }
        return "en"
    }

    private static func resolve() -> (Bundle, Locale) {
        lock.lock(); defer { lock.unlock() }
        let code = effectiveCode()
        if cachedCode == code, let b = cachedBundle, let l = cachedLocale { return (b, l) }
        let bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        let locale = Locale(identifier: code)
        cachedCode = code; cachedBundle = bundle; cachedLocale = locale
        return (bundle, locale)
    }

    static var bundle: Bundle { resolve().0 }
    static var locale: Locale { resolve().1 }

    /// Look up a plain string; returns the key itself if it's missing (so gaps are visible, never blank).
    static func string(_ key: String) -> String {
        resolve().0.localizedString(forKey: key, value: key, table: nil)
    }

    /// Look up a format string and apply `args` with the selected locale (correct number grouping etc.).
    static func format(_ key: String, _ args: [CVarArg]) -> String {
        let (b, l) = resolve()
        let fmt = b.localizedString(forKey: key, value: key, table: nil)
        return String(format: fmt, locale: l, arguments: args)
    }

    /// The plural *form* (no number) for `base`, e.g. `pluralForm("noun.chats", 2)` → "chats".
    /// Falls back through other → many → one so a partially-translated language never shows a raw key.
    static func pluralForm(_ base: String, _ n: Int) -> String {
        let b = resolve().0
        let cat = Plural.category(n, code: effectiveCode())
        for suffix in [cat.rawValue, PluralCategory.other.rawValue, PluralCategory.many.rawValue, PluralCategory.one.rawValue] {
            let key = "\(base).\(suffix)"
            let v = b.localizedString(forKey: key, value: key, table: nil)
            if v != key { return v }
        }
        return base
    }
}

// MARK: - Global helpers (terse on purpose — they appear all over the UI)

/// Localize a plain string.
func L(_ key: String) -> String { Loc.string(key) }

/// Localize a format string and substitute `args` (handles %@, %lld, %1$@, … with the active locale).
func Lf(_ key: String, _ args: CVarArg...) -> String { Loc.format(key, args) }

/// "<n> <noun>" with the noun pluralized for `n` (e.g. "3 chats", "1 чат", "5 чатов").
func Lcount(_ base: String, _ n: Int) -> String { "\(n) \(Loc.pluralForm(base, n))" }

/// Just the pluralized noun for `n`, no number (used as a caption beside a separately-shown count).
func Lplural(_ base: String, _ n: Int) -> String { Loc.pluralForm(base, n) }

// MARK: - Manager (SwiftUI-observable; owns the live language + side effects of switching)

@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    @Published private(set) var language: AppLanguage

    private init() { language = Loc.storedLanguage() }

    func set(_ lang: AppLanguage) {
        guard lang != language else { return }
        Loc.setStoredLanguage(lang)      // persist + invalidate the resolver cache first…
        language = lang                  // …then publish, so observers re-read fresh strings
        // Update the history window's AppKit title if it's open (SwiftUI content re-renders on its own).
        HistoryWindowController.shared.localeDidChange()
    }
}
