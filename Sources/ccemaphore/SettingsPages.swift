import SwiftUI
import AppKit
import ServiceManagement

// The Settings pages hosted by `SettingsScreen`: one root page per tab (Notifications and SSH have their own
// files — `NotificationSettingsView`, `RemoteHostsView`) and the sub-screens the roots push. Each is its own
// top-level view, so each observes `LocalizationManager` (CLAUDE.md l10n rule 4).

// MARK: - Appearance

/// Settings › Appearance: the light itself (the same controls as the right-click quick popover) and how the
/// chat list is grouped, with the product-group list one level down.
struct AppearanceSettingsPage: View {
    @ObservedObject var engine: StateEngine
    @ObservedObject var settings: WidgetSettings
    let onOpenGroups: () -> Void
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsSectionHeader(label: L("widget.section"), first: true)
            WidgetQuickSettingsView(settings: settings, embedded: true)

            SettingsSectionHeader(label: L("settings.chats.section"))
            groupingRow
            SettingsDrillRow(label: L("settings.groups.section"),
                             subtitle: L("settings.groups.subtitle"),
                             value: "\(engine.productGroups.count)",
                             action: onOpenGroups)
        }
    }

    /// Label column + pills, on the same metrics as the widget rows above it so the page reads as one grid.
    private var groupingRow: some View {
        HStack(spacing: 10) {
            Text(L("settings.groups.mode.title"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.textSecondary)
                .frame(width: 84, alignment: .leading)
            HStack(spacing: 5) {
                ForEach(WidgetSettings.Grouping.allCases) { g in
                    segmentPill(groupingLabel(g), active: settings.grouping == g) { settings.grouping = g }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private func groupingLabel(_ g: WidgetSettings.Grouping) -> String {
        switch g {
        case .status:  L("settings.groups.mode.status")
        case .product: L("settings.groups.mode.product")
        }
    }
}

/// Appearance › Product groups: the effective group list (manual ✕-removable; Codex / auto read-only) and an
/// add-root field that accepts only an existing absolute folder.
struct ProductGroupsPage: View {
    @ObservedObject var engine: StateEngine
    @ObservedObject private var loc = LocalizationManager.shared
    @State private var newRoot = ""

    var body: some View {
        VStack(spacing: 0) {
            SettingsCaption(text: L("settings.groups.explainer"))
            if engine.productGroups.isEmpty {
                SettingsCaption(text: L("settings.groups.empty"))
            } else {
                ForEach(engine.productGroups) { g in
                    ProductGroupRow(group: g, onRemove: g.source == .manual ? { engine.removeProductGroup(root: g.root) } : nil)
                }
            }
            SettingsAddField(placeholder: L("settings.groups.placeholder"), text: $newRoot, canAdd: canAdd, onAdd: add)
        }
    }

    private var canAdd: Bool {
        let p = ProductGroups.normalize(newRoot)
        var isDir: ObjCBool = false
        return p.hasPrefix("/") && FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
    }

    private func add() {
        guard canAdd else { return }
        engine.addProductGroup(root: newRoot)
        newRoot = ""
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
                RemoveButton(hovering: hovering, help: L("settings.groups.remove"), action: onRemove)
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

// MARK: - Agents

/// Settings › Agents: where status comes from — Claude Code, then Codex.
struct AgentsSettingsPage: View {
    @ObservedObject var engine: StateEngine
    @ObservedObject var settings: WidgetSettings
    let onOpenTrusted: () -> Void
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsSectionHeader(label: L("settings.section.claude"), first: true)
            ClaudeSettingsSection(engine: engine, settings: settings, onOpenTrusted: onOpenTrusted)
            SettingsSectionHeader(label: L("settings.codex.section"))
            CodexSettingsSection(engine: engine, settings: settings)
        }
    }
}

/// Agents › Trusted commands: a persistent list of tool/command patterns our permission hook auto-approves
/// (no IDE dialog, no ribbon). Review + remove entries, add new ones. Only meaningful while the permission
/// hook is installed, so it's dimmed AND disabled (with the reason on top) when it isn't.
struct TrustedCommandsPage: View {
    @ObservedObject var engine: StateEngine
    @ObservedObject private var loc = LocalizationManager.shared
    @State private var newTool = "Bash"
    @State private var newPattern = ""

    var body: some View {
        VStack(spacing: 0) {
            SettingsCaption(text: engine.permissionHookInstalled ? L("settings.trusted.explainer") : L("settings.trusted.off"))
            Group {
                if engine.trustedCommands.isEmpty {
                    SettingsCaption(text: L("settings.trusted.empty"))
                } else {
                    ForEach(engine.trustedCommands) { entry in
                        TrustedRow(entry: entry) { engine.removeTrustedCommand(entry) }
                    }
                }
                SettingsAddField(placeholder: L("settings.trusted.placeholder"), text: $newPattern,
                                 canAdd: canAdd, onAdd: add) { toolMenu }
            }
            // Off ⇒ the hook never reads trusted.json, so editing it here is a no-op that would silently
            // persist and surprise-activate later. Dim AND disable, not just dim.
            .opacity(engine.permissionHookInstalled ? 1 : 0.5)
            .disabled(!engine.permissionHookInstalled)
        }
    }

    private var toolMenu: some View {
        Menu {
            ForEach(["Bash", "WebFetch", "*"], id: \.self) { t in
                Button(toolLabel(t)) { newTool = t }
            }
        } label: {
            Text(toolLabel(newTool))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(DS.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func toolLabel(_ t: String) -> String { t == "*" ? L("settings.trusted.anyTool") : t }

    /// Enabled when the entry would be accepted: a non-empty pattern, or a concrete tool (whole-tool
    /// trust). Mirrors `TrustedCommands.add`, which refuses the "any tool + any use" catch-all.
    private var canAdd: Bool {
        !newPattern.trimmingCharacters(in: .whitespaces).isEmpty || newTool != "*"
    }

    private func add() {
        guard canAdd else { return }
        engine.addTrustedCommand(tool: newTool, pattern: newPattern)
        newPattern = ""
    }
}

/// One trusted-command row: tool chip · pattern · remove (✕). The pattern is monospaced (it's a command
/// fragment) and middle-truncated so a long one still shows both ends.
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
            RemoveButton(hovering: hovering, help: L("settings.trusted.remove"), action: onRemove)
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

/// The ✕ at the end of a removable list row; reddens while its row is hovered.
private struct RemoveButton: View {
    let hovering: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(hovering ? DS.redText : DS.textTertiary)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - General

/// Settings › General: the app itself — language, open at login, updates, diagnostics (logs).
struct GeneralSettingsPage: View {
    @ObservedObject var engine: StateEngine
    @ObservedObject private var loc = LocalizationManager.shared
    /// macOS's own record, not a stored preference — the user can switch it off in System Settings.
    @State private var loginStatus = SMAppService.mainApp.status

    var body: some View {
        VStack(spacing: 0) {
            languageRow
                .padding(.top, 4)
            loginItemRow

            SettingsSectionHeader(label: L("settings.updates.section"))
            UpdateSettingsSection(updater: .shared)

            SettingsSectionHeader(label: L("settings.section.diagnostics"))
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

    private var loginItemRow: some View {
        let blocker = Self.loginItemBlocker
        return SettingsAppRow(
            label: L("settings.launchAtLogin.title"),
            subtitle: L(blocker ?? (loginStatus == .requiresApproval
                                    ? "settings.launchAtLogin.approval" : "settings.launchAtLogin.subtitle")),
            state: .onOff(loginStatus == .enabled),
            enabled: blocker == nil,
            action: toggleLoginItem
        )
        // The panel is reused across hide / show, so `onAppear` alone misses a change made in System
        // Settings meanwhile; a window showing or hiding is rare and cheap to re-read on.
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    /// Why this copy may not become the login item (a localization key), or nil. `register()` records the
    /// CALLING copy: a Debug / ad-hoc build would then start at login in place of the release (the
    /// signature-keyed grants in CLAUDE.md), and a DMG / translocated one dangles once ejected or moved.
    private static let loginItemBlocker: String? = {
        #if DEBUG
        return "settings.launchAtLogin.devBuild"
        #else
        if !UpdateSupport.isDeveloperIDSigned() { return "settings.launchAtLogin.devBuild" }
        if UpdateSupport.isTransientLocation() { return "settings.launchAtLogin.needsMove" }
        return nil
        #endif
    }()

    private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                // macOS may hold the item for the user's OK — take them straight to where they give it.
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            Log.settings.warn("login item change failed (status \(service.status.rawValue)): \(error)")
        }
        loginStatus = service.status
        Log.settings.info("login item status=\(loginStatus.rawValue)")
    }

    /// Single "Language" label + the current language (name · flag) as a trailing menu; clicking it opens
    /// the picker.
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
}

/// A round flag chip for a language — the country-flag emoji cropped to a circle, or a globe for
/// `.system`. The language row's trailing badge.
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
