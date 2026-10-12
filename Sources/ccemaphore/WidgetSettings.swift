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

    /// How the Chats tab groups rows: by traffic-light status (the original), or by product folder
    /// (`ProductGroups`) with rows sorted by status inside each product.
    enum Grouping: String, CaseIterable, Identifiable {
        case status, product
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
    /// Read Claude Code's own session registry (`~/.claude/sessions/<pid>.json`, see
    /// `SessionRegistryReader`) as the primary state source. ON by default — it's Claude Code's own
    /// word on busy/idle/waiting. A setting because the schema is undocumented: turning it off returns to
    /// transcript + hook inference alone if a Claude Code update ever changes it.
    @Published var useSessionRegistry: Bool { didSet { d.set(useSessionRegistry, forKey: K.useSessionRegistry) } }
    /// Watch Codex (ChatGPT.app) threads under `~/.codex` alongside Claude Code. ON by default when Codex
    /// is installed; a user with no Codex pays nothing (the watchers aren't even started).
    @Published var codexEnabled: Bool { didSet { d.set(codexEnabled, forKey: K.codexEnabled) } }
    /// Let the blocking permission hook WAIT (ribbon with live Allow/Deny) for a chat hosted in the Claude
    /// DESKTOP app, as it does for IDE chats. OFF until the live interplay with the app's own permission
    /// card is verified — the hook process reads this via UserDefaults (same bundle id), see
    /// `PermissionBroker.desktopWaitDefaultsKey`.
    @Published var desktopPermissionWait: Bool { didSet { d.set(desktopPermissionWait, forKey: K.desktopPermissionWait) } }
    @Published var grouping: Grouping { didSet { d.set(grouping.rawValue, forKey: K.grouping) } }
    /// Session ids whose row is expanded to show sub-agents (the chevron). Remembered across launches.
    @Published private var expandedSessions: Set<String> { didSet { d.set(Array(expandedSessions), forKey: K.expandedSessions) } }

    /// Which settings sections are currently EXPANDED (by section id). Default empty = every section
    /// collapsed, so the (long) Settings tab opens compact and the user expands only what they need. The
    /// choice is remembered across launches. Storing the *expanded* set (not collapsed) means a brand-new
    /// section added in a future build starts collapsed automatically.
    @Published private var expandedSections: Set<String> { didSet { d.set(Array(expandedSections), forKey: K.expandedSections) } }

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
        static let expandedSections = "settings.expandedSections"
        static let useSessionRegistry = "claude.useSessionRegistry"
        static let codexEnabled = "codex.enabled"
        static let desktopPermissionWait = PermissionBroker.desktopWaitDefaultsKey
        static let expandedSessions = "sessions.expanded"
        static let grouping = "panel.grouping"
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
        useSessionRegistry = d.object(forKey: K.useSessionRegistry) as? Bool ?? true
        codexEnabled = d.object(forKey: K.codexEnabled) as? Bool ?? true
        desktopPermissionWait = d.bool(forKey: K.desktopPermissionWait)   // default OFF (see doc above)
        expandedSessions = Set(d.stringArray(forKey: K.expandedSessions) ?? [])
        grouping = Grouping(rawValue: d.string(forKey: K.grouping) ?? "") ?? .status
        expandedSections = Set(d.stringArray(forKey: K.expandedSections) ?? [])   // default: all collapsed
        positions = Self.decodePositions(d.data(forKey: K.positions))
        lastDisplayID = d.string(forKey: K.lastDisplayID)
    }

    // MARK: - Settings-section collapse state

    func isSectionExpanded(_ id: String) -> Bool { expandedSections.contains(id) }

    func toggleSection(_ id: String) {
        if expandedSections.contains(id) { expandedSections.remove(id) } else { expandedSections.insert(id) }
    }

    // MARK: - Expandable session rows (sub-agents)

    func isSessionExpanded(_ id: String) -> Bool { expandedSessions.contains(id) }
    /// Read-only view of the remembered set (the engine's prune keeps Codex ids while Codex is off).
    var expandedSessionIDs: Set<String> { expandedSessions }

    func toggleSessionExpanded(_ id: String) {
        if expandedSessions.contains(id) { expandedSessions.remove(id) } else { expandedSessions.insert(id) }
    }

    /// Drop remembered expansions for chats that no longer exist, so the set (and its UserDefaults array)
    /// stays bounded to the live list. Writes only when something was actually pruned.
    func pruneExpandedSessions(keeping live: Set<String>) {
        let kept = expandedSessions.intersection(live)
        if kept.count != expandedSessions.count { expandedSessions = kept }
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
