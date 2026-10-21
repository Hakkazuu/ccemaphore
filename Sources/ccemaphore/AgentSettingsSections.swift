import SwiftUI

/// Settings › Agents › "Claude Code": everything that is about Claude Code alone (its hooks, the interactive
/// permission ribbon and its trusted commands, the IDE-log watch, Claude Code's own session registry, the
/// Claude desktop wait).
struct ClaudeSettingsSection: View {
    @ObservedObject var engine: StateEngine
    @ObservedObject var settings: WidgetSettings
    /// Opens the trusted-commands sub-screen (`SettingsRoute.trustedCommands`).
    let onOpenTrusted: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsAppRow(
                label: L("settings.hooks.title"),
                subtitle: L("settings.hooks.subtitle"),
                state: .onOff(engine.hooksInstalled),
                action: {
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
                    engine.permissionHookInstalled ? engine.uninstallPermissionHook() : engine.installPermissionHook()
                }
            )
            HookErrorNote(agent: .claude, engine: engine)
            // Right under the permission row it extends: the list only works while that hook is in.
            SettingsDrillRow(
                label: L("settings.trusted.section"),
                subtitle: engine.permissionHookInstalled
                    ? L("settings.trusted.subtitle")
                    : L("settings.trusted.needHook"),
                value: "\(engine.trustedCommands.count)",
                action: onOpenTrusted
            )
            SettingsAppRow(
                label: L("settings.idelog.title"),
                // A dimmed row says WHY it's gated and what enables it, not a live-looking subtitle for a
                // feature that can't run.
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
                // While it's read, how many live Claude Code processes report through it right now.
                subtitle: settings.useSessionRegistry
                    ? L("settings.registry.subtitle") + "\n" + Lf("settings.registry.live", engine.registryLiveCount)
                    : L("settings.registry.subtitle"),
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
}

/// Settings › Agents › "Codex": watching ~/.codex (mode A), the single hooks toggle (mode B: approval → red,
/// compaction chip), and — once installed — where Codex's trust in those hooks stands, with the one
/// action that moves it forward.
struct CodexSettingsSection: View {
    @ObservedObject var engine: StateEngine
    @ObservedObject var settings: WidgetSettings

    var body: some View {
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
                state: .onOff(engine.codexHooks.isInstalled),
                enabled: engine.codexInstalled,
                action: {
                    guard engine.codexInstalled else { return }
                    engine.codexHooks.isInstalled ? engine.uninstallCodexHooks() : engine.installCodexHooks()
                }
            )
            HookErrorNote(agent: .codex, engine: engine)
            if engine.codexHooks.isInstalled {
                let summary = engine.codexHooks.summary
                SettingsAppRow(label: L("settings.codex.trust.title"), subtitle: caption(summary)) {
                    statusIcon(summary)
                }
                actionRow(summary)
            }
        }
    }

    /// Where the hooks stand, as a sentence the user can act on. Rendered on every body pass, so a
    /// language switch (and the "N minutes ago") re-resolve.
    private func caption(_ summary: CodexHooksStatus.Summary) -> String {
        switch summary {
        case .notInstalled:
            return ""
        case .outdated:
            return L("settings.codex.trust.outdated")
        case .featureOff:
            return L("settings.codex.trust.featureOff")
        case .needsApproval(_, modifiedOnly: true):
            return L("settings.codex.trust.modified")
        case .needsApproval(let count, modifiedOnly: false):
            return Lf("settings.codex.trust.pending", Lcount("noun.hooks", count))
        case .disabled(let count):
            return Lf("settings.codex.trust.disabled", Lcount("noun.hooks", count))
        case .trusted:
            return engine.codexHooksLastSignal.map { Lf("settings.codex.trust.working", Fmt.relative($0)) }
                ?? L("settings.codex.trust.silent")
        }
    }

    @ViewBuilder
    private func statusIcon(_ summary: CodexHooksStatus.Summary) -> some View {
        switch summary {
        case .trusted:
            // Approved but never heard from yet: not a problem to fix, but not proven either.
            let proven = engine.codexHooksLastSignal != nil
            Image(systemName: proven ? "checkmark.seal.fill" : "checkmark.seal")
                .font(.system(size: 12))
                .foregroundStyle(proven ? DS.green : DS.textTertiary)
                .accessibilityHidden(true)
        default:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DS.ctxWarning)
                .accessibilityHidden(true)
        }
    }

    /// The one thing that moves the state forward: rewrite an older layout, or go approve in ChatGPT.
    @ViewBuilder
    private func actionRow(_ summary: CodexHooksStatus.Summary) -> some View {
        switch summary {
        case .outdated:
            SettingsAppRow(label: L("settings.codex.action.update"),
                           subtitle: L("settings.codex.action.update.subtitle"), glyph: "↻") {
                engine.installCodexHooks()
            }
        case .needsApproval, .disabled:
            SettingsAppRow(label: L("settings.codex.action.openApp"), glyph: "↗") {
                DeepLinker.openCodexApp()
            }
        case .notInstalled, .featureOff, .trusted:
            EmptyView()
        }
    }
}

/// Why the last hook install / removal didn't happen — refused because ccemaphore runs from the disk image
/// or a translocated copy (the hooks would point into a location that disappears), or settings.json /
/// hooks.json couldn't be written. Shown under the rows of the agent whose hooks it was about; gone once an
/// op on that agent's hooks succeeds (`StateEngine.runHookOp` clears it).
struct HookErrorNote: View {
    let agent: AgentKind
    @ObservedObject var engine: StateEngine

    var body: some View {
        if let error = engine.lastHookError, error.agent == agent {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(DS.ctxWarning)
                    .accessibilityHidden(true)
                Text(error.message)
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
}
