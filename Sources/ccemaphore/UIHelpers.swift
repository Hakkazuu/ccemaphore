import SwiftUI

/// Single shared ISO-8601 parser — fractional seconds first, then plain, matching what the hook handler
/// writes. `Date.ISO8601FormatStyle` is a Sendable value type, safe to share/parse concurrently with no
/// lock. Consolidates several hand-rolled copies of this exact frac-then-plain ladder (R5). NOTE: the
/// `ISO8601DateFormatter`-based parsers (`SessionStore`, `Log`, `Diagnostic`) are deliberately NOT folded
/// in — that reference type carries different `formatOptions` semantics, and conflating the two is the
/// very hazard this consolidation is careful to avoid.
enum ISOTime {
    static let frac = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static let plain = Date.ISO8601FormatStyle()
    static func parse(_ s: String) -> Date? { (try? frac.parse(s)) ?? (try? plain.parse(s)) }
}

/// A settings segment button (size S/M/L, display mode, orientation) — the shared style extracted from
/// three byte-identical copies in `WidgetQuickSettings` (R6). `mono` uses a monospaced glyph (the size
/// segment's S/M/L letters); default proportional for word labels. Pixel-identical to the originals.
@ViewBuilder
func segmentPill(_ label: String, active: Bool, mono: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: mono ? .monospaced : .default))
            .foregroundStyle(active ? DS.textPrimary : DS.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(active ? DS.neutralBtnHover : DS.neutralBtn, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}

extension SessionState {
    var color: Color {
        switch self {
        case .working: Color(red: 0.95, green: 0.74, blue: 0.10)  // amber, readable on light/dark
        case .waiting: .red
        case .done: .green
        case .stale: .gray
        }
    }
    var label: String {
        switch self {
        case .working: L("state.working")
        case .waiting: L("state.waiting")
        case .done: L("state.done")
        case .stale: "—"
        }
    }
}

extension AggregateColor {
    var color: Color {
        switch self {
        case .yellow: Color(red: 0.95, green: 0.74, blue: 0.10)
        case .red: .red
        case .green: .green
        case .gray: .gray
        }
    }
}

/// Compact display formatting.
enum Fmt {
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    static func cost(_ d: Double) -> String { String(format: "$%.2f", d) }

    static func pct(_ d: Double) -> String { "\(Int(d.rounded()))%" }

    // MARK: - History view formatting

    /// "Today" / "Yesterday" / "26 Jun" for a "yyyy-MM-dd" string, in the active language.
    static func dayLabel(_ iso: String) -> String {
        guard let d = isoDayParser.date(from: iso) else { return iso }
        if Calendar.current.isDateInToday(d) { return L("date.today") }
        if Calendar.current.isDateInYesterday(d) { return L("date.yesterday") }
        return df("d MMM").string(from: d)
    }

    /// Short weekday ("Fri") — surfaced so day-of-week gaps (e.g. weekends) read at a glance.
    static func weekday(_ iso: String) -> String {
        guard let d = isoDayParser.date(from: iso) else { return "" }
        return df("EEEEEE").string(from: d)
    }

    /// "Friday, 26 June" for the detail header.
    static func dayFull(_ iso: String) -> String {
        guard let d = isoDayParser.date(from: iso) else { return iso }
        let s = df("EEEE, d MMMM").string(from: d)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static func clock(_ date: Date) -> String { clockFmt.string(from: date) }

    /// "claude-opus-4-8" → "Opus 4.8"; "claude-haiku-4-5-20251001" → "Haiku 4.5" (drops the date build).
    static func model(_ id: String) -> String {
        var s = id.hasPrefix("claude-") ? String(id.dropFirst("claude-".count)) : id
        s = s.replacingOccurrences(of: "-[0-9]{8}$", with: "", options: .regularExpression)  // drop date suffix
        let parts = s.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return s.capitalized }
        return "\(parts[0].capitalized) \(parts[1].replacingOccurrences(of: "-", with: "."))"
    }

    /// One compact label for a session's models: "Opus 4.8", or "Opus 4.8 +1" when several were used.
    static func models(_ ids: [String]) -> String {
        var seen = Set<String>()
        let names = ids.map(model).filter { seen.insert($0).inserted }
        guard let first = names.first else { return "" }
        return names.count > 1 ? "\(first) +\(names.count - 1)" : first
    }

    /// Compact "time until reset": "in 4h 19m" within a day, else a weekday + clock ("Fri 18:00").
    static func resetIn(_ date: Date) -> String {
        let s = date.timeIntervalSinceNow
        if s <= 0 { return L("reset.done") }
        if s < 86_400 {
            let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
            return h > 0 ? Lf("reset.inHM", h, m) : Lf("reset.inM", m)
        }
        return df("EE HH:mm").string(from: date)
    }

    /// Traffic-light tint for a 0–100 usage percentage (limits and context bars share it).
    static func usageColor(_ pct: Double) -> Color {
        switch pct {
        case ..<60: .green
        case ..<85: Color(red: 0.95, green: 0.74, blue: 0.10)
        default: .red
        }
    }

    static var todayString: String { dayFormatter.string(from: Date()) }

    // MARK: - Locale-independent parsers/formatters

    /// Parses our "yyyy-MM-dd" day keys. Fixed POSIX locale so parsing never depends on the UI language.
    private static let isoDayParser: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let clockFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = .current; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f
    }()

    // MARK: - Locale-aware formatter cache (rebuilt when the selected language changes)
    //
    // INVARIANT: `Fmt` is main-actor-only. `df(_:)` caches under `fmtLock` but hands back the SHARED
    // DateFormatter, which callers then format with OUTSIDE the lock — safe only because every caller is
    // a SwiftUI view body or the single-threaded diagnostic CLI (never off-main). If Fmt is ever needed
    // off the main actor, return a per-call copy rather than widening the lock across `.string(from:)`.

    private static let fmtLock = NSLock()
    private nonisolated(unsafe) static var dfCache: [String: DateFormatter] = [:]

    /// A `DateFormatter` for `format` in the active locale (localized month/weekday names), cached per
    /// language so switching the picker reformats dates without leaking a stale formatter.
    private static func df(_ format: String) -> DateFormatter {
        let code = Loc.effectiveCode()
        let key = "\(code)|\(format)"
        fmtLock.lock(); defer { fmtLock.unlock() }
        if let f = dfCache[key] { return f }
        let f = DateFormatter()
        f.locale = Loc.locale
        f.timeZone = .current
        f.dateFormat = format
        dfCache[key] = f
        return f
    }
}

/// Stable per-project accent color so each project reads as the same hue across launches (a plain
/// `hashValue` is per-run-randomized, so we roll a deterministic FNV-style hash instead).
enum Palette {
    static func color(for key: String) -> Color {
        var h: UInt64 = 0xcbf29ce484222325
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let hue = Double(h % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.80)
    }
}
