import SwiftUI

/// User-tunable settings for the floating widget (§8 of the design spec) plus its remembered
/// position. Observed by the SwiftUI views and by `FloatingWidgetController`; persisted to
/// `UserDefaults` so choices survive relaunch.
///
/// Position is stored **per display** (keyed by a stable display id), so the light returns to where
/// it was left on each monitor instead of jumping when the screen layout changes (§9).
@MainActor
final class WidgetSettings: ObservableObject {
    static let shared = WidgetSettings()

    /// Widget scale presets (§8). The factor multiplies every geometry token in `DS.Geo`.
    /// Five steps: the former `small`/`medium`/`large` are preserved verbatim as `xs`/`m`/`l`
    /// (same scales) so upgrading users keep their exact size; `s` and `xl` are new in-fills.
    /// Legacy raw values (`small`/`medium`/`large`) are migrated in `init` — do not reuse them.
    enum WidgetSize: String, CaseIterable, Identifiable {
        case xs, s, m, l, xl
        var id: String { rawValue }
        var scale: CGFloat {
            switch self {
            case .xs: 0.75
            case .s:  0.87
            case .m:  1.0
            case .l:  1.45
            case .xl: 1.9
            }
        }
        /// Compact label for the quick poly-control (XS / S / M / L / XL).
        var letter: String {
            switch self {
            case .xs: "XS"
            case .s:  "S"
            case .m:  "M"
            case .l:  "L"
            case .xl: "XL"
            }
        }

        /// Map a persisted raw value — including the legacy `small`/`medium`/`large` names — to a case,
        /// preserving the on-screen scale across the 3→5 preset migration.
        static func stored(_ raw: String?) -> WidgetSize? {
            switch raw {
            case "small":  return .xs
            case "medium": return .m
            case "large":  return .l
            default:       return raw.flatMap(WidgetSize.init(rawValue:))
            }
        }
    }

    /// Tower presentation (§3.2): summary shows per-status counts in the lamps; single shows only the
    /// dominant lamp (+ a badge when >1).
    enum DisplayMode: String, CaseIterable, Identifiable {
        case summary, single
        var id: String { rawValue }
    }

    /// Lamp layout: the classic vertical stack, or a horizontal row.
    enum Orientation: String, CaseIterable, Identifiable {
        case vertical, horizontal
        var id: String { rawValue }
    }

    @Published var visible: Bool { didSet { d.set(visible, forKey: K.visible) } }
    /// Collapsed-widget opacity (0.25–1.0). Forced to 1.0 by the views while the ribbon/panel is open.
    @Published var opacity: Double { didSet { d.set(opacity, forKey: K.opacity) } }
    @Published var size: WidgetSize { didSet { d.set(size.rawValue, forKey: K.size) } }
    /// When pinned the light can't be dragged (§8) — guards against nudging it by accident.
    @Published var pinned: Bool { didSet { d.set(pinned, forKey: K.pinned) } }
    @Published var displayMode: DisplayMode { didSet { d.set(displayMode.rawValue, forKey: K.displayMode) } }
    /// Lamp layout: vertical stack (default) or horizontal row (§8).
    @Published var orientation: Orientation { didSet { d.set(orientation.rawValue, forKey: K.orientation) } }
    /// Watch the Cursor / VS Code Claude Code extension log to drop a permission ribbon the instant the
    /// user answers in the IDE's OWN dialog (instead of at tool completion — for a long build that's
    /// minutes of stale red after the approval; see memory/permission-stale-ribbon-incident). ON by
    /// default: it reads only each log's tail and extracts only the `toolUseId` token, never command
    /// text. Still a setting (not a constant) because the log is undocumented and version-fragile —
    /// turning it off is the escape hatch if an IDE update breaks the format. See `IDELogWatcher`.
    @Published var watchIDELog: Bool { didSet { d.set(watchIDELog, forKey: K.watchIDELog) } }

    private let d = UserDefaults.standard
    /// displayId → stored origin. This is `panel.frame.origin`, i.e. an ABSOLUTE global-coordinate
    /// point (not screen-local) — the controller never subtracts the screen's own origin before
    /// saving/restoring it. Keyed per-display purely so each monitor remembers its own spot.
    private var positions: [String: CGPoint]

    private enum K {
        static let visible = "widget.visible"
        static let opacity = "widget.opacity"
        static let size = "widget.size"
        static let pinned = "widget.pinned"
        static let displayMode = "widget.displayMode"
        static let orientation = "widget.orientation"
        static let positions = "widget.positions"
        static let lastDisplayID = "widget.lastDisplayID"
        static let watchIDELog = "widget.watchIDELog"
    }

    private init() {
        let d = UserDefaults.standard
        // Default visible=true on first run (the widget is the whole point); other keys default sanely.
        visible = d.object(forKey: K.visible) as? Bool ?? true
        let o = d.object(forKey: K.opacity) as? Double ?? 1.0
        opacity = min(1.0, max(0.25, o))
        size = WidgetSize.stored(d.string(forKey: K.size)) ?? .m
        pinned = d.bool(forKey: K.pinned)
        displayMode = DisplayMode(rawValue: d.string(forKey: K.displayMode) ?? "") ?? .summary
        orientation = Orientation(rawValue: d.string(forKey: K.orientation) ?? "") ?? .vertical
        watchIDELog = d.object(forKey: K.watchIDELog) as? Bool ?? true   // default ON (see doc above)
        positions = Self.decodePositions(d.data(forKey: K.positions))
        lastDisplayID = d.string(forKey: K.lastDisplayID)
    }

    // MARK: - Per-display position

    /// The display the widget was last placed on — so `restorePosition` can find the RIGHT saved
    /// spot at cold launch, when the panel hasn't been placed on any screen yet and `panel.screen`
    /// can't be trusted to reflect where the user actually left it (see FloatingWidgetController).
    @Published var lastDisplayID: String? { didSet { d.set(lastDisplayID, forKey: K.lastDisplayID) } }

    func position(forDisplay id: String) -> CGPoint? { positions[id] }

    func setPosition(_ p: CGPoint, forDisplay id: String) {
        positions[id] = p
        if let data = try? JSONEncoder().encode(positions.mapValues { [$0.x, $0.y] }) {
            d.set(data, forKey: K.positions)
        }
    }

    private static func decodePositions(_ data: Data?) -> [String: CGPoint] {
        guard let data, let raw = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return [:] }
        return raw.compactMapValues { arr in arr.count == 2 ? CGPoint(x: arr[0], y: arr[1]) : nil }
    }
}
