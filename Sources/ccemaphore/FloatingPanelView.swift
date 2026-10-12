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

    /// Which section's hook rows the user touched last — where a refused or failed hook op is explained.
    private enum HookScope { case claude, codex }
    @State private var hookErrorScope: HookScope = .claude

    /// Add-form state for the "Доверенные команды" section (auto-allow list).
    @State private var newTrustedTool = "Bash"
    @State private var newTrustedPattern = ""
    /// Add-form state for the "Группы продуктов" section.
    @State private var newGroupRoot = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            notes
            ScrollView {
                VStack(spacing: 0) {
                    switch tab {
                    case .chats:
                        sessionList
                        codexLimitsNote
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
            .frame(height: min(contentHeight, max(minBodyHeight, maxBodyHeight - notesHeight)))
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

    // MARK: - Settings screen (the "Настройки" tab)

    private var settingsScreen: some View {
        // Every section collapses to just its (tappable) header — the Settings tab has a lot of options,
        // so it opens compact and the user expands only what they need. State is remembered per section.
        VStack(spacing: 0) {
            CollapsibleSection(id: "widget", label: L("widget.section"), first: true) {
                WidgetQuickSettingsView(settings: settings, embedded: true)
            }
            CollapsibleSection(id: "notif", label: L("notif.section")) {
                NotificationSettingsView(notif: NotificationSettings.shared)
            }
            CollapsibleSection(id: "app", label: L("settings.section.app")) {
                appSectionBody
            }
            CollapsibleSection(id: "updates", label: L("settings.updates.section")) {
                UpdateSettingsSection(updater: .shared)
            }
            CollapsibleSection(id: "codex", label: L("settings.codex.section")) {
                codexSectionBody
            }
            CollapsibleSection(id: "trusted", label: L("settings.trusted.section")) {
                trustedSectionBody
            }
            CollapsibleSection(id: "groups", label: L("settings.groups.section")) {
                groupsSectionBody
            }
            CollapsibleSection(id: "remote", label: L("remote.menu.title")) {
                RemoteHostsView(engine: engine, embedded: true)
            }
            CollapsibleSection(id: "diagnostics", label: L("settings.section.diagnostics")) {
                diagnosticsSectionBody
            }
        }
        .padding(.bottom, 10)
        // Quit is intentionally NOT here — it lives in the menu-bar item (see `CcemaphoreApp`).
    }

    /// App settings rows (language + hook toggles). The collapsible wrapper supplies the section header.
    private var appSectionBody: some View {
        VStack(spacing: 0) {
            languageRow
            SettingsAppRow(
                label: L("settings.hooks.title"),
                subtitle: L("settings.hooks.subtitle"),
                state: .onOff(engine.hooksInstalled),
                action: {
                    hookErrorScope = .claude
                    engine.hooksInstalled ? engine.uninstallHooks() : engine.installHooks()
                }
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
                    hookErrorScope = .claude
                    engine.permissionHookInstalled ? engine.uninstallPermissionHook() : engine.installPermissionHook()
                }
            )
            hookErrorNote(.claude)
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
            SettingsAppRow(
                label: L("settings.registry.title"),
                subtitle: L("settings.registry.subtitle"),
                state: .onOff(settings.useSessionRegistry),
                action: { settings.useSessionRegistry.toggle(); engine.forceRefresh() }
            )
            SettingsAppRow(
                label: L("settings.desktopWait.title"),
                subtitle: engine.permissionHookInstalled
                    ? L("settings.desktopWait.subtitle")
                    : L("settings.idelog.subtitle.needHook"),
                state: .onOff(settings.desktopPermissionWait),
                enabled: engine.permissionHookInstalled,
                action: {
                    guard engine.permissionHookInstalled else { return }
                    settings.desktopPermissionWait.toggle()
                }
            )
        }
    }

    // MARK: Codex (ChatGPT app)

    /// The Codex section: one toggle for mode A over ~/.codex, with a caption that says whether Codex is
    /// present at all and how many of its threads are live right now. (Codex hooks land here in phase 3.)
    private var codexSectionBody: some View {
        VStack(spacing: 0) {
            SettingsAppRow(
                label: L("settings.codex.title"),
                subtitle: !engine.codexInstalled
                    ? L("settings.codex.subtitle.missing")
                    : settings.codexEnabled
                        ? Lf("settings.codex.subtitle.on", engine.sessions.filter(\.isCodex).count)
                        : L("settings.codex.subtitle.off"),
                state: .onOff(settings.codexEnabled && engine.codexInstalled),
                enabled: engine.codexInstalled,
                action: {
                    guard engine.codexInstalled else { return }
                    engine.setCodexEnabled(!settings.codexEnabled)
                }
            )
            SettingsAppRow(
                label: L("settings.codex.hooks.title"),
                subtitle: L("settings.codex.hooks.subtitle"),
                state: .onOff(engine.codexHooksInstalled),
                enabled: engine.codexInstalled,
                action: {
                    guard engine.codexInstalled else { return }
                    hookErrorScope = .codex
                    engine.codexHooksInstalled ? engine.uninstallCodexHooks() : engine.installCodexHooks()
                }
            )
            SettingsAppRow(
                label: L("settings.codex.permission.title"),
                subtitle: engine.codexHooksInstalled
                    ? L("settings.codex.permission.subtitle")
                    : L("settings.permission.subtitle.off"),
                state: .onOff(engine.codexPermissionHookInstalled),
                enabled: engine.codexHooksInstalled,
                action: {
                    guard engine.codexHooksInstalled else { return }
                    hookErrorScope = .codex
                    engine.codexPermissionHookInstalled ? engine.uninstallCodexPermissionHook() : engine.installCodexPermissionHook()
                }
            )
            hookErrorNote(.codex)
            if engine.codexHooksInstalled || engine.codexPermissionHookInstalled {
                SettingsAppRow(label: L("settings.codex.trust.title"), subtitle: codexTrustCaption) {
                    Image(systemName: engine.codexHooksTrust == .trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(engine.codexHooksTrust == .trusted ? DS.green : DS.ctxWarning)
                }
            }
        }
    }

    // MARK: Hook errors

    /// Why the last hook install / removal didn't happen — refused because ccemaphore runs from the disk image
    /// or a translocated copy (the hooks would point into a location that disappears), or settings.json /
    /// hooks.json couldn't be written. Shown under the hook rows the user touched last; gone once an op
    /// succeeds (`StateEngine.runHookOp` clears it).
    @ViewBuilder
    private func hookErrorNote(_ scope: HookScope) -> some View {
        if hookErrorScope == scope, let text = hookErrorText {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(DS.ctxWarning)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
    }

    /// Rendered on every body pass, so a language switch re-resolves it.
    private var hookErrorText: String? { engine.lastHookError?.message }

    /// Where Codex's hash-bound trust stands, as a sentence the user can act on.
    private var codexTrustCaption: String {
        switch engine.codexHooksTrust {
        case .trusted:      return L("settings.codex.trust.trusted")
        case .stale:        return L("settings.codex.trust.stale")
        case .untrusted:    return L("settings.codex.trust.untrusted")
        case .notInstalled: return L("settings.codex.trust.none")
        }
    }

    // MARK: Diagnostics (log export)

    /// The "Диагностика" section: quick access to the on-disk logs so the user can share them for
    /// debugging. "Сохранить логи…" zips `~/Library/Logs/ccemaphore` via an NSSavePanel; "Показать в
    /// Finder" reveals the folder. (This save action existed in the old menu-bar build and was lost in
    /// the floating-panel rebuild — `LogExport` was still complete, just no longer wired to any UI.)
    private var diagnosticsSectionBody: some View {
        VStack(spacing: 0) {
            SettingsAppRow(label: L("diag.registry.title"), subtitle: L("diag.registry.subtitle")) {
                Text("\(engine.registryLiveCount)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(engine.registryLiveCount > 0 ? DS.greenText : DS.textTertiary)
            }
            SettingsAppRow(
                label: L("settings.saveLogs"),
                subtitle: L("settings.saveLogs.subtitle"),
                glyph: "↗",
                action: { LogExport.presentSavePanel() }
            )
            SettingsAppRow(
                label: L("settings.revealLogs"),
                subtitle: L("settings.revealLogs.subtitle"),
                glyph: "↗",
                action: { LogExport.revealInFinder() }
            )
        }
    }

    // MARK: Product groups

    /// Grouping mode (status / product) + the effective group list (manual ✕-removable; Codex / auto
    /// read-only) + an add-root field.
    private var groupsSectionBody: some View {
        VStack(spacing: 0) {
            Text(L("settings.groups.explainer"))
                .font(.system(size: 10))
                .foregroundStyle(DS.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            HStack(spacing: 6) {
                segmentPill(L("settings.groups.mode.status"), active: settings.grouping == .status) { settings.grouping = .status }
                segmentPill(L("settings.groups.mode.product"), active: settings.grouping == .product) { settings.grouping = .product }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            if engine.productGroups.isEmpty {
                Text(L("settings.groups.empty"))
                    .font(.system(size: 10))
                    .foregroundStyle(DS.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            } else {
                ForEach(engine.productGroups) { g in
                    ProductGroupRow(group: g, onRemove: g.source == .manual ? { engine.removeProductGroup(root: g.root) } : nil)
                }
            }
            HStack(spacing: 8) {
                TextField(L("settings.groups.placeholder"), text: $newGroupRoot)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DS.textPrimary)
                    .frame(maxWidth: .infinity)
                    .onSubmit(addGroup)
                Button(action: addGroup) {
                    Text(L("settings.trusted.add"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(canAddGroup ? DS.greenText : DS.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(!canAddGroup)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    private var canAddGroup: Bool {
        let p = ProductGroups.normalize(newGroupRoot)
        var isDir: ObjCBool = false
        return p.hasPrefix("/") && FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
    }

    private func addGroup() {
        guard canAddGroup else { return }
        engine.addProductGroup(root: newGroupRoot)
        newGroupRoot = ""
    }

    // MARK: Trusted commands (auto-allow list)

    /// The "Доверенные команды" section: a persistent list of tool/command patterns our permission hook
    /// auto-approves (no Cursor dialog, no ribbon). Review + remove existing entries and add new ones.
    /// Only meaningful when the permission hook is installed, so it's dimmed + noted when it isn't.
    private var trustedSectionBody: some View {
        VStack(spacing: 0) {
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
                    .foregroundStyle(canAddTrusted ? DS.greenText : DS.textTertiary)
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
struct SettingsSectionHeader: View {
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
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)   // stay on one line; the hairline yields width
            DS.line.frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, first ? 12 : 18)
        .padding(.bottom, 8)
    }
}

/// A settings section that collapses to just its header. The header row (chevron · mono label · hairline)
/// is fully tappable; the expanded/collapsed state is per-section, persisted in `WidgetSettings`, and
/// defaults to collapsed so the long Settings tab opens compact. The label is single-line and the hairline
/// takes the remaining width, so a long title (or a longer translation) never wraps to two lines.
private struct CollapsibleSection<Content: View>: View {
    let id: String
    let label: String
    var first: Bool = false
    /// Built lazily (only when expanded) so a collapsed section never constructs its subtree — e.g. the
    /// notifications view's `CustomSounds.load()` doesn't run while that section is collapsed.
    let content: () -> Content
    @ObservedObject private var settings = WidgetSettings.shared
    @State private var hovering = false

    init(id: String, label: String, first: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.label = label
        self.first = first
        self.content = content
    }

    var body: some View {
        let expanded = settings.isSectionExpanded(id)
        VStack(spacing: 0) {
            Button { settings.toggleSection(id) } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DS.textTertiary)
                        .frame(width: 9)
                    Text(label)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .tracking(0.9)
                        .foregroundStyle(DS.textTertiary)
                        .textCase(.uppercase)   // uniform CAPS across sections (source strings mix cases)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    DS.line.frame(height: 1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? DS.hoverRow : .clear)
                        .padding(.horizontal, 6)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .padding(.top, first ? 4 : 10)   // inter-section gap, outside the tappable/highlighted row

            if expanded { content() }
        }
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
                .foregroundStyle(on ? DS.greenText : DS.textTertiary)
        )
    }

    /// Row that performs a one-shot action on tap (e.g. "Save logs…"), showing a trailing glyph rather
    /// than an on/off state — the whole row is the tap target.
    init(label: String, subtitle: String? = nil, glyph: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.label = label
        self.subtitle = subtitle
        self.enabled = enabled
        self.action = action
        self.trailing = AnyView(
            Text(glyph)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.textSecondary)
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

/// One product-group row: name · root (mono, middle-truncated) · source pill · ✕ (manual only).
private struct ProductGroupRow: View {
    let group: ProductGroup
    let onRemove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                Text((group.root as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(sourceLabel)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(DS.textTertiary)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(DS.neutralBtn, in: Capsule())
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(hovering ? DS.redText : DS.textTertiary)
                }
                .buttonStyle(.plain)
                .help(L("settings.groups.remove"))
            }
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

    private var sourceLabel: String {
        switch group.source {
        case .manual: return L("settings.groups.source.manual")
        case .codex:  return "Codex"
        case .auto:   return L("settings.groups.source.auto")
        }
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
