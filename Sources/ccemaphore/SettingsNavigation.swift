import Foundation

/// The Settings screen's top-level tabs, in strip order (left → right). The raw value is persisted
/// (`WidgetSettings.settingsTab`), so a case's raw value must never be renamed — only added.
enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    /// The light (opacity, size, mode, orientation, pin) and the chat list (grouping, product groups).
    case appearance
    /// Ribbons and sounds: the general defaults, per-type overrides, imported sounds.
    case notifications
    /// Where status comes from: Claude Code (hooks, permission ribbon, trusted commands) and Codex.
    case agents
    /// Remote hosts over SSH (Claude Code only).
    case ssh
    /// The app itself: language, updates, diagnostics, licenses.
    case general

    var id: String { rawValue }

    /// The short strip label's localization key.
    var labelKey: String { "settings.tab.\(rawValue)" }

    /// SF Symbols for the strip: the outline at rest, the filled variant while selected (the same name when
    /// a symbol has no filled form). Every name exists since macOS 12 — the deployment target is 13.
    var symbol: (rest: String, active: String) {
        switch self {
        case .appearance:    ("paintpalette", "paintpalette.fill")
        case .notifications: ("bell", "bell.fill")
        case .agents:        ("cpu", "cpu.fill")
        case .ssh:           ("network", "network")
        case .general:       ("slider.horizontal.3", "slider.horizontal.3")
        }
    }

    /// Position in the strip — which way a switch slides.
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// A persisted raw value back to a tab; anything unknown (a removed tab, a fresh install) opens the first.
    static func stored(_ raw: String?) -> SettingsTab {
        raw.flatMap(SettingsTab.init(rawValue:)) ?? .appearance
    }
}

/// A sub-screen pushed over a tab's root — the long, list-shaped settings that would otherwise make a tab
/// grow without bound. Each belongs to exactly one tab.
enum SettingsRoute: String, CaseIterable, Identifiable, Sendable {
    case productGroups
    case trustedCommands
    case addRemoteHost

    var id: String { rawValue }

    var tab: SettingsTab {
        switch self {
        case .productGroups:   .appearance
        case .trustedCommands: .agents
        case .addRemoteHost:   .ssh
        }
    }

    /// The sub-screen title's localization key.
    var titleKey: String {
        switch self {
        case .productGroups:   "settings.groups.section"
        case .trustedCommands: "settings.trusted.section"
        case .addRemoteHost:   "remote.host.add"
        }
    }
}

/// Where the Settings screen is — a tab, optionally one sub-screen deep — and which way the last move went,
/// so the incoming page slides in from the matching side. A value type with no UI, so every rule is
/// covered by `--self-test` ("Settings navigation").
struct SettingsNavigation: Equatable, Sendable {
    enum Direction: Equatable, Sendable { case none, forward, backward }

    private(set) var tab: SettingsTab
    private(set) var route: SettingsRoute?
    private(set) var direction: Direction = .none

    init(tab: SettingsTab) { self.tab = tab }

    /// Identity of the page on screen: a change swaps the page (and runs the transition).
    var pageID: String { route.map { "\(tab.rawValue)/\($0.rawValue)" } ?? tab.rawValue }

    /// The strip was clicked. Another tab opens at its root, sliding the way the strip runs; the current tab
    /// again pops its sub-screen (the familiar "tap the tab to go back to the top"), or does nothing at the root.
    mutating func select(_ newTab: SettingsTab) {
        if newTab == tab {
            pop()
            return
        }
        direction = newTab.order > tab.order ? .forward : .backward
        tab = newTab
        route = nil
    }

    /// Open a sub-screen of the current tab. A route of another tab is refused — a row can only push its own.
    mutating func push(_ newRoute: SettingsRoute) {
        guard newRoute.tab == tab, newRoute != route else { return }
        direction = .forward
        route = newRoute
    }

    /// Back to the tab's root; nothing to do there already.
    mutating func pop() {
        guard route != nil else { return }
        direction = .backward
        route = nil
    }
}
