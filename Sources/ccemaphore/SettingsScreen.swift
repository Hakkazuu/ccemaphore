import SwiftUI

/// The panel's Settings tab: a strip of five tabs pinned at the top and, under it, the selected tab's page —
/// or one of its sub-screens (`SettingsRoute`). The host gives it a FIXED height, so switching tabs never
/// resizes the window (a resize re-pins the anchored panel, see `FloatingWidgetController`); every page
/// scrolls inside that height instead.
///
/// Navigation is the value type `SettingsNavigation` (unit-tested); this view only renders it. Each move
/// runs one transaction: the strip's thumb springs to the new tab, the incoming page slides a few points in
/// from the side the move went and fades in, the outgoing one fades out. Reduce Motion keeps the fades only.
struct SettingsScreen: View {
    @ObservedObject var engine: StateEngine
    @ObservedObject var settings: WidgetSettings
    @ObservedObject private var loc = LocalizationManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Starts on the remembered tab, at its root. The panel is built once and only hidden on hover-out, so
    /// this state (an open sub-screen, a half-typed form) outlives a brief hover-out; it resets when the footer
    /// leaves Settings for Chats.
    @State private var nav: SettingsNavigation

    init(engine: StateEngine, settings: WidgetSettings) {
        self.engine = engine
        self.settings = settings
        _nav = State(initialValue: SettingsNavigation(tab: settings.settingsTab))
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabStrip(selection: nav.tab) { tab in navigate { $0.select(tab) } }
            ZStack(alignment: .top) {
                page
                    .id(nav.pageID)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .onChange(of: nav.tab) { settings.settingsTab = $0 }
    }

    // MARK: Navigation

    private func navigate(_ move: (inout SettingsNavigation) -> Void) {
        var next = nav
        move(&next)
        guard next != nav else { return }
        withAnimation(reduceMotion ? DS.settingsFade : DS.settingsPage) { nav = next }
    }

    /// Read when the incoming page is inserted, i.e. with the new `direction` already set. Only the insertion
    /// is directional: SwiftUI removes a page with the transition it had when it was last rendered — the
    /// previous move's direction — so the outgoing page just fades, quicker than the incoming one arrives.
    private var pageTransition: AnyTransition {
        let shift: CGFloat = reduceMotion ? 0 : 18
        let dx: CGFloat = nav.direction == .backward ? -shift : shift
        return .asymmetric(insertion: .offset(x: dx).combined(with: .opacity),
                           removal: .opacity.animation(DS.settingsFade))
    }

    // MARK: Pages

    @ViewBuilder
    private var page: some View {
        if let route = nav.route {
            VStack(spacing: 0) {
                SettingsSubpageBar(title: L(route.titleKey), parent: L(route.tab.labelKey)) {
                    navigate { $0.pop() }
                }
                SettingsPageScroll { routePage(route) }
            }
        } else {
            SettingsPageScroll { tabPage(nav.tab) }
        }
    }

    @ViewBuilder
    private func tabPage(_ tab: SettingsTab) -> some View {
        switch tab {
        case .appearance:
            AppearanceSettingsPage(engine: engine, settings: settings) { navigate { $0.push(.productGroups) } }
        case .notifications:
            NotificationSettingsView(notif: .shared)
        case .agents:
            AgentsSettingsPage(engine: engine, settings: settings) {
                navigate { $0.push(.trustedCommands) }
            }
        case .ssh:
            RemoteHostsView(engine: engine) { navigate { $0.push(.addRemoteHost) } }
        case .general:
            GeneralSettingsPage(engine: engine)
        }
    }

    @ViewBuilder
    private func routePage(_ route: SettingsRoute) -> some View {
        switch route {
        case .productGroups:   ProductGroupsPage(engine: engine)
        case .trustedCommands: TrustedCommandsPage(engine: engine)
        case .addRemoteHost:   RemoteHostAddForm(engine: engine) { navigate { $0.pop() } }
        }
    }
}

/// One page's scrolling body. A fresh one per page (the page's `.id`), so every tab opens scrolled to the top.
private struct SettingsPageScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 0) { content }
                .padding(.top, 2)
                .padding(.bottom, 12)
        }
    }
}

// MARK: - Tab strip

/// The five tabs as one segmented track: an icon over a short label each, the selected one on a raised thumb
/// that slides (a matched-geometry spring) to whichever tab is picked. Deliberately unlike the footer
/// (flat columns with a highlighted cell) so the two navigation levels never read as the same control.
private struct SettingsTabStrip: View {
    let selection: SettingsTab
    let onSelect: (SettingsTab) -> Void
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsTabButton(tab: tab, label: L(tab.labelKey), active: tab == selection, thumb: thumb) {
                    onSelect(tab)
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(DS.neutralBtn))
        .animation(reduceMotion ? nil : DS.tabThumb, value: selection)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { DS.line.frame(height: 1) }
    }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab
    /// Resolved by the strip (not here), so a language switch changes this view's inputs and re-renders it.
    let label: String
    let active: Bool
    let thumb: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: active ? tab.symbol.active : tab.symbol.rest)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(height: 15)
                    .scaleEffect(active ? 1 : 0.94)
                Text(label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)   // the longest translation still fits a fifth of the panel
            }
            .foregroundStyle(active || hovering ? DS.textPrimary : DS.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.segmentThumb)
                        .shadow(color: DS.segmentThumbShadow, radius: 1.5, y: 0.5)
                        .matchedGeometryEffect(id: "thumb", in: thumb)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.hoverRow)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Sub-screen bar

/// The top of a sub-screen: a small "‹ <tab>" back link over the sub-screen's title. Clicking the tab in the
/// strip goes back too (`SettingsNavigation.select`).
private struct SettingsSubpageBar: View {
    let title: String
    let parent: String
    let onBack: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                    Text(parent)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(hovering ? DS.textPrimary : DS.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? DS.neutralBtnHover : DS.neutralBtn)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(Lf("settings.back.a11y", parent))

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

// MARK: - Settings kit (rows shared by every page)

/// A settings section header: mono uppercase label · trailing hairline. Same idiom as the chat list's group
/// headers (minus the count) so Settings reads as native to the rest of the panel.
struct SettingsSectionHeader: View {
    let label: String
    /// The first section of a page sits right under the strip, so it needs less top air than the gaps
    /// between sections.
    var first: Bool = false

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(DS.textTertiary)
                .textCase(.uppercase)   // uniform CAPS across sections (source strings mix cases)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)   // stay on one line; the hairline yields width
            DS.line.frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, first ? 10 : 18)
        .padding(.bottom, 8)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A short explanatory paragraph under a header or at the top of a page.
struct SettingsCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(DS.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
    }
}

/// One app setting row: a label (+ a one-line description) on the left and either a state label or a custom
/// trailing control on the right. With an `action` the whole row is a real `Button` — so VoiceOver meets one
/// element (label and description read together) that it can press and that it announces as dimmed while
/// disabled; a disabled row neither highlights nor reacts.
struct SettingsAppRow<Trailing: View>: View {
    enum State { case onOff(Bool) }
    let label: String
    /// One-line description of what the setting does — so "on vs off" is meaningful at a glance.
    var subtitle: String? = nil
    let trailing: Trailing
    var enabled: Bool = true
    let action: (() -> Void)?
    @SwiftUI.State private var hovering = false

    /// Row with a custom trailing view (e.g. the language picker), no tap action.
    init(label: String, subtitle: String? = nil, enabled: Bool = true, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.subtitle = subtitle
        self.trailing = trailing()
        self.enabled = enabled
        self.action = nil
    }

    /// Row with a custom trailing view AND a tap action (e.g. a sub-screen row's count + chevron).
    init(label: String, subtitle: String? = nil, enabled: Bool = true, action: @escaping () -> Void,
         @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.subtitle = subtitle
        self.trailing = trailing()
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        if let action {
            Button(action: action) { row }
                .buttonStyle(SettingsRowButtonStyle())
                .disabled(!enabled)
                .onHover { hovering = $0 }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.textSecondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(DS.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                // Gated on `enabled` here, not in `onHover`: a row that turns disabled under a resting
                // pointer (its hook removed elsewhere) must drop the fill at once.
                .fill(hovering && enabled ? DS.hoverRow : .clear)
                .padding(.horizontal, 6)
        )
        .opacity(enabled ? 1 : 0.45)
        .contentShape(Rectangle())
    }
}

/// A row button that draws its label as is — no system dimming on top of the row's own disabled opacity
/// (`.plain` dims a disabled label again, which left a gated row barely legible) — and a brief press fade.
private struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension SettingsAppRow where Trailing == AnyView {
    /// Row that renders an on/off state label on the right (+ a description under the label) and toggles
    /// via `action` on tap.
    init(label: String, subtitle: String? = nil, state: State, enabled: Bool = true, action: @escaping () -> Void) {
        let on: Bool
        if case let .onOff(v) = state { on = v } else { on = false }
        self.init(label: label, subtitle: subtitle, enabled: enabled, action: action) {
            AnyView(
                Text(on ? L("state.on") : L("state.off"))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(on ? DS.greenText : DS.textTertiary)
            )
        }
    }

    /// Row that performs a one-shot action on tap (e.g. "Save logs…"), showing a trailing glyph rather
    /// than an on/off state — the whole row is the tap target.
    init(label: String, subtitle: String? = nil, glyph: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.init(label: label, subtitle: subtitle, enabled: enabled, action: action) {
            AnyView(
                Text(glyph)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.textSecondary)
            )
        }
    }
}

/// A row that opens a sub-screen: label (+ description) · an optional count · a chevron.
struct SettingsDrillRow: View {
    let label: String
    var subtitle: String? = nil
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        SettingsAppRow(label: label, subtitle: subtitle, action: action) {
            HStack(spacing: 6) {
                if let value {
                    Text(value)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(DS.textTertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.textTertiary)
            }
            .padding(.top, 1)
        }
    }
}

/// A free-text entry row with an "Add" action: an optional leading control (a tool picker) · the field ·
/// Add, which lights up green only while the entry would be accepted.
struct SettingsAddField<Leading: View>: View {
    let placeholder: String
    @Binding var text: String
    let canAdd: Bool
    let onAdd: () -> Void
    @ViewBuilder let leading: Leading

    var body: some View {
        HStack(spacing: 8) {
            leading
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The placeholder drawn by hand: a plain TextField paints its own in the field's text colour,
                // which read as an already-typed value.
                .background(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(placeholder)
                .onSubmit { if canAdd { onAdd() } }
            Button(action: onAdd) {
                Text(L("settings.trusted.add"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(canAdd ? DS.greenText : DS.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.codeBG))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.line, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

extension SettingsAddField where Leading == EmptyView {
    init(placeholder: String, text: Binding<String>, canAdd: Bool, onAdd: @escaping () -> Void) {
        self.init(placeholder: placeholder, text: text, canAdd: canAdd, onAdd: onAdd) { EmptyView() }
    }
}

/// A full-width dashed "+ <title>" button — opens a creation form (the SSH tab's "Add Remote Host").
struct SettingsAddButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(hovering ? DS.textPrimary : DS.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? DS.hoverRow : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(hovering ? DS.panelBorder : DS.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}
