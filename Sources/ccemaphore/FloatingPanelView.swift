import SwiftUI
import AppKit

/// Carries the measured height of the scrollable body out to `FloatingPanelView` so the `ScrollView`
/// can be sized to its content (a bare ScrollView collapses to ~0 in a fit-to-content window).
private struct PanelBodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Carries the measured height of the note rows between the header and the body (Claude missing, the update
/// row), so the body's cap can make room for them.
private struct PanelNotesHeightKey: PreferenceKey {
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
    /// Measured height of the note rows above the body. They count against `maxBodyHeight`, so the whole panel
    /// keeps the height the cap was chosen for: an update row with its release notes open is ~250 pt, and on
    /// top of a full body it pushed the tab bar off a short screen. The body keeps at least `minBodyHeight`.
    @State private var notesHeight: CGFloat = 0
    private let minBodyHeight: CGFloat = 160

    /// The tallest the body may be: the cap minus the note rows, never below `minBodyHeight`.
    private var bodyCap: CGFloat { max(minBodyHeight, maxBodyHeight - notesHeight) }

    var body: some View {
        VStack(spacing: 0) {
            header
            notes
            switch tab {
            case .chats:
                chatsBody
            case .settings:
                // Fixed at the cap, so switching settings tabs never resizes (and re-pins) the window; each
                // settings page scrolls inside it.
                SettingsScreen(engine: engine, settings: settings)
                    .frame(height: bodyCap)
            }
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

    /// The chat list, content-tall while it fits and scrolling past the cap.
    private var chatsBody: some View {
        ScrollView {
            VStack(spacing: 0) {
                sessionList
                codexLimitsNote
                activityNote
            }
            .padding(.bottom, 4)
            .background(GeometryReader { geo in
                Color.clear.preference(key: PanelBodyHeightKey.self, value: geo.size.height)
            })
        }
        .frame(height: min(contentHeight, bodyCap))
        .onPreferenceChange(PanelBodyHeightKey.self) { contentHeight = $0 }
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

    // MARK: - Session list (by status, or by product)

    @ViewBuilder
    private var sessionList: some View {
        switch settings.grouping {
        case .status:  statusGroups
        case .product: productGroupsList
        }
    }

    private struct ProductSection: Identifiable {
        let id: String        // group root, or "__other"
        let label: String
        let items: [SessionInfo]
        /// Worst state inside (waiting < working < done) — sections with something red float up.
        var urgency: Int { items.map { $0.state == .waiting ? 0 : $0.state == .working ? 1 : 2 }.min() ?? 3 }
    }

    /// Product mode: one section per group that has live chats (ungrouped chats under "Other"), sections
    /// ordered red-first then by name, rows sorted by status inside each.
    private var productSections: [ProductSection] {
        var byRoot: [String: [SessionInfo]] = [:]
        var other: [SessionInfo] = []
        for s in engine.sessions {
            if let r = s.productRoot { byRoot[r, default: []].append(s) } else { other.append(s) }
        }
        var out = engine.productGroups.compactMap { g -> ProductSection? in
            guard let items = byRoot[g.root] else { return nil }
            return ProductSection(id: g.root, label: g.name, items: sortedForDisplay(items))
        }
        out.sort { a, b in a.urgency != b.urgency ? a.urgency < b.urgency
                   : a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending }
        if !other.isEmpty { out.append(ProductSection(id: "__other", label: L("group.other"), items: sortedForDisplay(other))) }
        return out
    }

    @ViewBuilder
    private var productGroupsList: some View {
        ForEach(productSections) { section in
            GroupHeader(label: section.label, count: section.items.count)
            ForEach(section.items) { session in
                SessionPanelRow(session: session) { onJump(session) }
            }
        }
    }

    /// Codex's own account limits (from the newest `token_count` any live Codex thread reported): the
    /// 5-hour and weekly windows with used % and reset time. Windows whose reset already passed are stale
    /// figures and are skipped; nothing shown when no live Codex thread carries limits.
    @ViewBuilder
    private var codexLimitsNote: some View {
        if let text = codexLimitsText {
            HStack(spacing: 6) {
                AgentBadge(agent: .codex)
                Text(L("limits.codex.title"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DS.textTertiary)
                Text(text)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
    }

    private var codexLimitsText: String? {
        guard let rl = engine.sessions.compactMap(\.rateLimits).max(by: { $0.observedAt < $1.observedAt }) else { return nil }
        let now = Date()
        let parts: [String] = [rl.primary, rl.secondary].compactMap { w in
            guard let w else { return nil }
            if let r = w.resetsAt, r < now { return nil }
            var p = "\(w.windowMinutes.map { Fmt.windowLabel(minutes: $0) } ?? "?") \(Fmt.pct(w.usedPercent))"
            if let r = w.resetsAt { p += " · " + Fmt.resetIn(r) }
            return p
        }
        return parts.isEmpty ? nil : parts.joined(separator: "   ")
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

    // MARK: - Note rows (Claude missing, updates)

    /// The note rows between the header and the body: Claude Code missing, then the update row (every
    /// `UpdatePhase` but idle). Outside the tab switch, so they show on Чаты and Настройки alike. The update row
    /// observes `AppUpdater` itself and renders nothing while idle — so a download's progress ticks re-render
    /// just that row, not this whole panel. Measured, so the body's cap makes room for them (`notesHeight`).
    private var notes: some View {
        VStack(spacing: 0) {
            if !engine.claudeInstalled { claudeMissingNote }
            UpdateNoteRow(updater: .shared, engine: engine)
        }
        .background(GeometryReader { geo in
            Color.clear.preference(key: PanelNotesHeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(PanelNotesHeightKey.self) { notesHeight = $0 }
    }

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

/// One session row, restyled to the panel mockup: glowing dot · project + branch + badges · title /
/// waiting reason · ctx% / cost. A chat with sub-agents grows a chevron that expands its children
/// (`ChildAgentRow`s) underneath; the expansion is remembered per session id.
private struct SessionPanelRow: View {
    let session: SessionInfo
    let onTap: () -> Void
    @ObservedObject private var settings = WidgetSettings.shared
    @State private var hovering = false

    private var expanded: Bool { !session.children.isEmpty && settings.isSessionExpanded(session.id) }

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            if expanded {
                ForEach(session.children) { child in
                    ChildAgentRow(child: child, onTap: onTap)
                }
            }
        }
    }

    private var mainRow: some View {
        HStack(spacing: 10) {
            StatusDot(color: DS.status(session.state), diameter: 9, glow: 7)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(projectLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let b = session.gitBranch, !b.isEmpty {
                        Text(b)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    AgentBadge(agent: session.originAgent)
                    HostGlyph(host: session.host)
                    if session.isBackground {
                        Text(L("row.background"))
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(DS.textTertiary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(DS.neutralBtn, in: Capsule())
                    }
                }
                secondLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(session.displayName)

            if !session.children.isEmpty { childrenToggle }

            VStack(alignment: .trailing, spacing: 1) {
                if let ctx = session.context {
                    Text(Fmt.pct(ctx.usedPercent))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DS.contextTint(ctx.usedPercent))
                }
                if let u = session.tokens {
                    // Codex threads carry tokens but no price list → show the token count, not "$0.00".
                    Text(u.costUsd > 0 ? Fmt.cost(u.costUsd) : Fmt.tokens(u.totalTokens))
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

    /// The bold lead text. Inside a product group the product name is the section header, so the row shows
    /// the sub-repo ("aigirl-backend", or the plain folder at the root); in status mode a grouped chat
    /// reads "product › sub-repo" so sibling repos of one product stay distinguishable.
    private var projectLabel: String {
        guard let root = session.productRoot else { return session.project }
        let rel = ProductGroups.relativeLabel(cwd: session.cwd, root: root)
        switch settings.grouping {
        case .product: return rel ?? session.project
        case .status:
            // An auto-suggested group must not relabel the default list — only groups the user owns
            // (manual) or named themselves in the ChatGPT app (Codex project) earn the `product › repo` form.
            guard !session.productGroupIsAuto else { return session.project }
            return rel.map { "\((root as NSString).lastPathComponent) › \($0)" } ?? session.project
        }
    }

    /// Compacting (amber) › waiting reason (red) › the chat title. One line, the most urgent fact wins.
    @ViewBuilder
    private var secondLine: some View {
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
        } else if session.state == .waiting, let w = session.waitingKind {
            Text(w == .input ? L("row.waiting.input") : L("row.waiting.permission"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.redText)
                .lineLimit(1)
        } else if let t = session.title, !t.isEmpty {
            Text(t)
                .font(.system(size: 11))
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// "▸ 3" / "▾ 3" — how many sub-agents, and a toggle to reveal them. A `Button` so it wins the click
    /// over the row's tap gesture.
    private var childrenToggle: some View {
        Button { settings.toggleSessionExpanded(session.id) } label: {
            HStack(spacing: 3) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                Text("\(session.children.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(session.children.contains { $0.state == .working } ? DS.yellow : DS.textTertiary)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(DS.neutralBtn, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? L("row.children.hide") : L("row.children.show"))
        .accessibilityLabel(Lcount("noun.subagents", session.children.count))
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
