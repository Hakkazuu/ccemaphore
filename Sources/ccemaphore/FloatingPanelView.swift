import SwiftUI
import AppKit

/// Carries the measured height of the scrollable body out to `FloatingPanelView` so the `ScrollView`
/// can be sized to its content (a bare ScrollView collapses to ~0 in a fit-to-content window).
private struct PanelBodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The hover-opened panel (§7): a self-contained floating window (NOT a menu dropdown). Header (status
/// + refresh) → tab body (Чаты / Настройки) → bottom tab bar (Чаты · История · Настройки). Permission
/// requests are handled at the light (the ribbon), not here. Visual reference:
/// `docs/redesign-floating-window/Panel.dc.html`.
///
/// Per-row content is project · branch · title · ctx% · $, grouped ЖДУТ → РАБОТАЮТ → ГОТОВО, dressed in
/// `DS` tokens so light/dark both resolve correctly.
struct FloatingPanelView: View {
    @ObservedObject var engine: StateEngine
    @ObservedObject var settings: WidgetSettings
    @ObservedObject var loc = LocalizationManager.shared

    var onJump: (SessionInfo) -> Void
    var onHistory: () -> Void
    var onRefresh: () -> Void
    var onQuit: () -> Void

    /// Which screen the body shows. История is NOT a body tab — it opens the rich history window — so
    /// only Чаты and Настройки swap the body; the footer tab bar drives this.
    enum PanelTab { case chats, settings }
    @State private var tab: PanelTab = .chats
    /// Measured height of the scrollable body. A bare `ScrollView` in a fit-to-content panel has no
    /// intrinsic height and collapses to ~0 (which hid the whole session list + settings), so we
    /// measure the content and size the scroll area to it, capped — content-tall when it fits, scrolling
    /// only past the cap.
    @State private var contentHeight: CGFloat = 160
    private let maxBodyHeight: CGFloat = 460

    /// Add-form state for the "Доверенные команды" section (auto-allow list).
    @State private var newTrustedTool = "Bash"
    @State private var newTrustedPattern = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            if !engine.claudeInstalled { claudeMissingNote }
            ScrollView {
                VStack(spacing: 0) {
                    switch tab {
                    case .chats:
                        statusGroups
                        activityNote
                    case .settings:
                        settingsScreen
                    }
                }
                .padding(.bottom, 4)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: PanelBodyHeightKey.self, value: geo.size.height)
                })
            }
            .frame(height: min(contentHeight, maxBodyHeight))
            .onPreferenceChange(PanelBodyHeightKey.self) { contentHeight = $0 }
            tabBar
        }
        .frame(width: DS.Geo.panelWidth)
        .background(
            // Tint over a real behind-window blur, both clipped (below) to the rounded shape.
            RoundedRectangle(cornerRadius: DS.Geo.panelRadius, style: .continuous)
                .fill(DS.panelBG)
                .background(VisualEffectBlur(material: .hudWindow, cornerRadius: DS.Geo.panelRadius))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Geo.panelRadius, style: .continuous)
                .strokeBorder(DS.panelBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Geo.panelRadius, style: .continuous))
        // Depth is the window's native rounded shadow (`FloatingWidgetController.configure`), not a
        // SwiftUI `.shadow` — clipped by the fit-to-content window edge it rendered a hard dark rectangle.
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            StatusDot(color: DS.status(engine.color), diameter: 9, glow: 8)
            Text(summaryText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Refresh moved here (the footer is now navigation tabs); the panel closes on hover-out.
            PanelGlyphButton(glyph: "↻", size: 13) { onRefresh() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { DS.line.frame(height: 1) }
    }

    /// The 2×3 dot grid that signals the window is draggable (mirrors the mockup's grip glyph).
    private var dragGrip: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 3) {
                    Circle().fill(DS.textPrimary).frame(width: 3, height: 3)
                    Circle().fill(DS.textPrimary).frame(width: 3, height: 3)
                }
            }
        }
        .opacity(0.32)
    }

    /// "N работают · N ждут · N готово" (counts assembled exactly like the popover header), or the
    /// "нет активных сессий" fallback.
    private var summaryText: String {
        if engine.sessions.isEmpty { return L("popover.noActiveSessions") }
        var parts: [String] = []
        if engine.workingCount > 0 { parts.append(Lf("count.working", engine.workingCount)) }
        if engine.waitingCount > 0 { parts.append(Lf("count.waiting", engine.waitingCount)) }
        if engine.doneCount > 0 { parts.append(Lf("count.done", engine.doneCount)) }
        return parts.isEmpty ? L("popover.noActiveSessions") : parts.joined(separator: " · ")
    }

    // MARK: - Status groups

    @ViewBuilder
    private var statusGroups: some View {
        ForEach(groups, id: \.self) { state in
            let items = engine.sessions.filter { $0.state == state }
            GroupHeader(label: groupLabel(state), count: items.count)
            ForEach(items) { session in
                SessionPanelRow(session: session) { onJump(session) }
            }
        }
    }

    /// Status groups in display order, empty groups dropped.
    private var groups: [SessionState] {
        [.waiting, .working, .done].filter { st in engine.sessions.contains { $0.state == st } }
    }

    private func groupLabel(_ state: SessionState) -> String {
        switch state {
        case .waiting: L("group.waiting")
        case .working: L("group.working")
        case .done:    L("group.done")
        case .stale:   "—"
        }
    }

    // MARK: - Claude-not-installed note

    /// Shown while `~/.claude/projects` doesn't exist (Claude Code never installed/run — see
    /// `StateEngine.claudeInstalled`). Sits between the header and the tab body, OUTSIDE the tab
    /// switch, so it's visible on both Чаты and Настройки. Text-only, no dismiss: the engine drops
    /// it automatically the moment Claude Code first runs.
    private var claudeMissingNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(DS.ctxWarning)
            Text(L("panel.claudeMissing"))
                .font(.system(size: 11))
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { DS.line.frame(height: 1) }
    }

    // MARK: - Activity-window note

    private var activityNote: some View {
        HStack(spacing: 6) {
            Circle().fill(DS.textTertiary).frame(width: 4, height: 4)
            Text(Lf("popover.activityWindow", Int(Tuning.staleWindow / 60)))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DS.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: - Settings screen (the "Настройки" tab)

    private var settingsScreen: some View {
        VStack(spacing: 0) {
            // "Виджет на экране" — the three on-screen widget controls (opacity / size / pin).
            // No card: a mono section header (the app's native group idiom) opens it, and the controls
            // sit flat on the same 12px gutter as every other row.
            SettingsSectionHeader(label: L("widget.section"), first: true)
            WidgetQuickSettingsView(settings: settings, embedded: true)

            // General app settings — same flat rhythm under their own section header.
            SettingsSectionHeader(label: L("settings.section.app"))
            languageRow
            SettingsAppRow(
                label: L("settings.hooks.title"),
                subtitle: L("settings.hooks.subtitle"),
                state: .onOff(engine.hooksInstalled),
                action: { engine.hooksInstalled ? engine.uninstallHooks() : engine.installHooks() }
            )
            SettingsAppRow(
                label: L("settings.permission.title"),
                subtitle: engine.hooksInstalled
                    ? L("settings.permission.subtitle.on")
                    : L("settings.permission.subtitle.off"),
                state: .onOff(engine.permissionHookInstalled),
                enabled: engine.hooksInstalled,
                action: {
                    guard engine.hooksInstalled else { return }
                    engine.permissionHookInstalled ? engine.uninstallPermissionHook() : engine.installPermissionHook()
                }
            )
            SettingsAppRow(
                label: L("settings.idelog.title"),
                // Same pattern as the permission row above: a dimmed row must say WHY it's gated and
                // what enables it, not show a live-looking subtitle for a feature that can't run.
                subtitle: engine.permissionHookInstalled
                    ? L("settings.idelog.subtitle")
                    : L("settings.idelog.subtitle.needHook"),
                state: .onOff(settings.watchIDELog),
                enabled: engine.permissionHookInstalled,
                action: {
                    guard engine.permissionHookInstalled else { return }
                    settings.watchIDELog.toggle()
                    engine.updateIDELogWatch()
                }
            )

            trustedSection
        }
        .padding(.bottom, 10)
        // Quit is intentionally NOT here — it lives in the menu-bar item (see `CcemaphoreApp`).
    }

    // MARK: Trusted commands (auto-allow list)

    /// The "Доверенные команды" section: a persistent list of tool/command patterns our permission hook
    /// auto-approves (no Cursor dialog, no ribbon). Review + remove existing entries and add new ones.
    /// Only meaningful when the permission hook is installed, so it's dimmed + noted when it isn't.
    private var trustedSection: some View {
        VStack(spacing: 0) {
            SettingsSectionHeader(label: L("settings.trusted.section"))
            Text(engine.permissionHookInstalled ? L("settings.trusted.explainer") : L("settings.trusted.needHook"))
                .font(.system(size: 10))
                .foregroundStyle(DS.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            if engine.trustedCommands.isEmpty {
                Text(L("settings.trusted.empty"))
                    .font(.system(size: 10))
                    .foregroundStyle(DS.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            } else {
                ForEach(engine.trustedCommands) { entry in
                    TrustedRow(entry: entry) { engine.removeTrustedCommand(entry) }
                }
            }

            trustedAddRow
        }
        // Off ⇒ the hook never reads trusted.json, so editing it here is a no-op that would silently
        // persist and surprise-activate later. Dim AND disable, not just dim.
        .opacity(engine.permissionHookInstalled ? 1 : 0.5)
        .disabled(!engine.permissionHookInstalled)
    }

    private var trustedAddRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(["Bash", "WebFetch", "*"], id: \.self) { t in
                    Button(t == "*" ? L("settings.trusted.anyTool") : t) { newTrustedTool = t }
                }
            } label: {
                Text(newTrustedTool == "*" ? L("settings.trusted.anyTool") : newTrustedTool)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            TextField(L("settings.trusted.placeholder"), text: $newTrustedPattern)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.textPrimary)
                .frame(maxWidth: .infinity)
                .onSubmit(addTrusted)

            Button(action: addTrusted) {
                Text(L("settings.trusted.add"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(canAddTrusted ? DS.green : DS.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canAddTrusted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// Enabled when the entry would be accepted: a non-empty pattern, or a concrete tool (whole-tool
    /// trust). Mirrors `TrustedCommands.add`, which refuses the "any tool + any use" catch-all.
    private var canAddTrusted: Bool {
        !newTrustedPattern.trimmingCharacters(in: .whitespaces).isEmpty || newTrustedTool != "*"
    }

    private func addTrusted() {
        guard canAddTrusted else { return }
        engine.addTrustedCommand(tool: newTrustedTool, pattern: newTrustedPattern)
        newTrustedPattern = ""
    }

    /// Single "Язык" label + the current language (name · flag) as a trailing menu; clicking it opens
    /// the same picker. (The reused row carried its OWN "Язык" title, which doubled the label.)
    private var languageRow: some View {
        HStack(spacing: 10) {
            Text(L("settings.language.title"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.textSecondary)
            Spacer(minLength: 8)
            Menu {
                ForEach(AppLanguage.allCases) { lang in
                    Button { loc.set(lang) } label: { Text("\(lang.menuGlyph)  \(lang.displayName)") }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(loc.language == .system ? L("language.system") : loc.language.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.textTertiary)
                    FlagBadge(lang: loc.language, diameter: 18)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    /// Bottom navigation: Чаты / Настройки swap the body (highlighted when active); История opens the
    /// rich history window and Выход quits the app (both actions, never a persistent selection). Выход
    /// used to hide in the Settings screen; it now lives here as a persistently reddish column.
    private var tabBar: some View {
        HStack(spacing: 2) {
            FooterButton(glyph: "☰", label: L("tab.chats"), active: tab == .chats) { tab = .chats }
            FooterButton(glyph: "◷", label: L("panel.history"), action: onHistory)
            FooterButton(glyph: "⚙", label: L("menu.settings"), active: tab == .settings) { tab = .settings }
            FooterButton(glyph: "⏻", label: L("menu.quit"), destructive: true, action: onQuit)
        }
        .padding(7)
        .overlay(alignment: .top) { DS.line.frame(height: 1) }
    }
}

// MARK: - Header / row pieces

/// A glowing status dot (the lamp halo from §2.4 reduced to a row-scale dot).
private struct StatusDot: View {
    let color: Color
    var diameter: CGFloat = 9
    var glow: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .shadow(color: color.opacity(0.7), radius: glow / 2)
    }
}

/// The small graphite glyph button used in the header (collapse "▾").
private struct PanelGlyphButton: View {
    let glyph: String
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: size))
                .foregroundStyle(hovering ? DS.textPrimary : DS.textSecondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? DS.hoverRow : DS.towerBG)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A status group header: mono label · hairline rule · count.
private struct GroupHeader: View {
    let label: String
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(DS.textTertiary)
            DS.line.frame(height: 1)
            Text("\(count)")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(DS.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 3)
    }
}

/// A settings section header: mono uppercase label · trailing hairline. Same idiom as `GroupHeader`
/// (minus the count) so Settings reads as native to the rest of the panel — this replaces the boxed
/// card + full-width divider the settings screen used to mix.
private struct SettingsSectionHeader: View {
    let label: String
    /// The first section sits right under the panel header rule, so it needs less top air than the
    /// gaps between sections.
    var first: Bool = false

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(DS.textTertiary)
            DS.line.frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, first ? 12 : 18)
        .padding(.bottom, 8)
    }
}

/// One session row, restyled to the panel mockup: glowing dot · project + branch + title · ctx% / cost.
private struct SessionPanelRow: View {
    let session: SessionInfo
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(color: DS.status(session.state), diameter: 9, glow: 7)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(session.project)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                    if let b = session.gitBranch, !b.isEmpty {
                        Text(b)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if session.isCompacting {
                    // A working chat mid-compaction: name it explicitly here (the tower only shows the
                    // quiet chip). Amber so it reads as a working sub-state, not an alert.
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.compress.vertical")
                            .font(.system(size: 9, weight: .semibold))
                        Text(L("status.compacting"))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(DS.yellow)
                } else if let t = session.title, !t.isEmpty {
                    Text(t)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(session.displayName)

            VStack(alignment: .trailing, spacing: 1) {
                if let ctx = session.context {
                    Text(Fmt.pct(ctx.usedPercent))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DS.contextTint(ctx.usedPercent))
                }
                if let u = session.tokens {
                    Text(Fmt.cost(u.costUsd))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(DS.textTertiary)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering ? DS.hoverRow : .clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }
}

// MARK: - Language chip

/// A round flag chip for a language — the country-flag emoji cropped to a circle, or a globe for
/// `.system`. (Relocated here from the removed popover; it's the language row's trailing badge.)
struct FlagBadge: View {
    let lang: AppLanguage
    var diameter: CGFloat = 22

    var body: some View {
        Group {
            if let flag = lang.flag {
                // Draw the flag through AppKit (NSImage), NOT SwiftUI `Text`: a hosted SwiftUI `Text`
                // paints regional-indicator flag glyphs blank in this panel (that's why the badge looked
                // empty), while AppKit renders them fine — the same path the language dropdown uses.
                // Sized to sit fully inside the circle over a faint base disc, mirroring the globe badge.
                Circle().fill(Color.secondary.opacity(0.12))
                    .frame(width: diameter, height: diameter)
                    .overlay(Image(nsImage: FlagBadge.emojiImage(flag, pointSize: diameter * 0.78)))
                    .clipShape(Circle())
            } else {
                Circle().fill(Color.secondary.opacity(0.15))
                    .frame(width: diameter, height: diameter)
                    .overlay(Image(systemName: "globe")
                        .font(.system(size: diameter * 0.6)).foregroundStyle(.secondary))
            }
        }
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
        .contentShape(Circle())
    }

    /// Rasterize an emoji into a color NSImage via AppKit text drawing. Needed because SwiftUI `Text`
    /// wouldn't render the flag glyphs here; AppKit does (verified headlessly — 🇷🇺/🇬🇧 produce colored
    /// pixels). Cached per (emoji, size) so we don't re-rasterize on every SwiftUI redraw.
    @MainActor static func emojiImage(_ emoji: String, pointSize: CGFloat) -> NSImage {
        let key = "\(emoji)@\(Int(pointSize.rounded()))"
        if let cached = emojiCache[key] { return cached }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: pointSize)]
        let ns = emoji as NSString
        var box = ns.size(withAttributes: attrs)
        box.width = ceil(box.width); box.height = ceil(box.height)
        let img = NSImage(size: box)
        img.lockFocus()
        ns.draw(at: .zero, withAttributes: attrs)
        img.unlockFocus()
        emojiCache[key] = img
        return img
    }

    @MainActor private static var emojiCache: [String: NSImage] = [:]
}

// MARK: - Settings rows

/// One app setting row inside the gear block: a label on the left and either a state label or custom
/// trailing control on the right. The whole row is the tap target when an `action` is supplied.
private struct SettingsAppRow<Trailing: View>: View {
    enum State { case onOff(Bool) }
    let label: String
    /// One-line description of what the setting does — so "on vs off" is meaningful at a glance (this
    /// is the description the old popover rows had; it was lost in the panel rebuild).
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

    var body: some View {
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
                .fill(hovering && action != nil ? DS.hoverRow : .clear)
                .padding(.horizontal, 6)
        )
        .opacity(enabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture { if enabled { action?() } }
        .onHover { if action != nil { hovering = $0 } }
    }
}

extension SettingsAppRow where Trailing == AnyView {
    /// Row that renders an on/off state label on the right (+ a description under the label) and toggles
    /// via `action` on tap.
    init(label: String, subtitle: String? = nil, state: State, enabled: Bool = true, action: @escaping () -> Void) {
        let on: Bool
        if case let .onOff(v) = state { on = v } else { on = false }
        self.label = label
        self.subtitle = subtitle
        self.enabled = enabled
        self.action = action
        self.trailing = AnyView(
            Text(on ? L("state.on") : L("state.off"))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(on ? DS.green : DS.textTertiary)
        )
    }
}

/// One trusted-command row: tool chip · pattern · remove (✕). Mirrors the flat row rhythm of the
/// settings screen. The pattern is monospaced (it's a command fragment) and middle-truncated so a long
/// one still shows both ends.
private struct TrustedRow: View {
    let entry: TrustedCommands.Entry
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.tool.isEmpty ? "*" : entry.tool)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(DS.textSecondary)
                .frame(minWidth: 46, alignment: .leading)
            Text(entry.pattern.isEmpty ? L("settings.trusted.anyUse") : entry.pattern)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(entry.pattern.isEmpty ? DS.textTertiary : DS.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? DS.redText : DS.textTertiary)
            }
            .buttonStyle(.plain)
            .help(L("settings.trusted.remove"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? DS.hoverRow : .clear)
                .padding(.horizontal, 6)
        )
        .onHover { hovering = $0 }
    }
}

// MARK: - Footer

/// One footer column: glyph over label, hover-highlighted. The quit column tints red on hover.
private struct FooterButton: View {
    let glyph: String
    let label: String
    var active: Bool = false
    var destructive: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(glyph).font(.system(size: 13))
                Text(label).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(background)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        // The quit column reads as a mild warning even at rest — a muted red that brightens on hover —
        // so it never looks like just another tab, mirroring its old reddish tint in Settings.
        if destructive { return hovering ? DS.redText : DS.redText.opacity(0.72) }
        if active || hovering { return DS.textPrimary }
        return DS.textSecondary
    }

    private var background: Color {
        if destructive, hovering { return DS.denyHover }
        if active { return DS.hoverRow }
        return hovering ? DS.hoverRow : .clear
    }
}
