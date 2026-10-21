import SwiftUI

/// Settings › SSH: the configured remote hosts (connection dot, enable toggle, test / install hooks / remove)
/// and a button that opens the add form (`RemoteHostAddForm`, the `addRemoteHost` sub-screen). This file owns
/// only the page's own layout, not the settings chrome around it (`SettingsScreen`).
///
/// Remote monitoring covers Claude Code only (remote transcripts under `~/.claude/projects`, hooks in the
/// remote `~/.claude/settings.json`); the explainer says so, since a Codex user would otherwise expect it.
///
/// A top-level view per CLAUDE.md's localization rule 4: it observes `LocalizationManager` directly.
struct RemoteHostsView: View {
    @ObservedObject var engine: StateEngine
    let onAdd: () -> Void
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsCaption(text: L("remote.explainer"))
                .padding(.top, 8)
            if engine.remoteHosts.isEmpty {
                SettingsCaption(text: L("remote.list.empty"))
            } else {
                ForEach(engine.remoteHosts) { host in
                    RemoteHostRow(
                        host: host,
                        status: engine.remoteHostStatuses[host.id],
                        testResult: engine.remoteTestResults[host.id],
                        installResult: engine.remoteHooksInstallResults[host.id],
                        onToggle: { engine.setRemoteHostEnabled(host.id, enabled: !host.enabled) },
                        onTest: { engine.testRemoteConnection(host) },
                        onInstallHooks: { engine.installRemoteHooks(host) },
                        onRemove: { engine.removeRemoteHost(host.id) }
                    )
                }
            }
            SettingsAddButton(title: L("remote.host.add"), action: onAdd)
        }
    }
}

/// SSH › Add Remote Host: the new host's fields. Every text field gets its own caption ABOVE it plus a visible
/// boxed background (not just a bare placeholder on transparent ground) — an earlier version relied on
/// placeholder text alone and users couldn't tell the fields were editable at all. Adding returns to the list.
struct RemoteHostAddForm: View {
    @ObservedObject var engine: StateEngine
    let onAdded: () -> Void
    @ObservedObject private var loc = LocalizationManager.shared

    @State private var label = ""
    @State private var hostname = ""
    @State private var user = ""
    @State private var port = ""
    @State private var identityFile = ""
    @State private var useSSHConfigOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                labeledField(L("remote.host.label"), text: $label, width: 96)
                labeledField(L("remote.host.hostname"), text: $hostname, mono: true)
            }
            HStack(spacing: 8) {
                labeledField(L("remote.host.user"), text: $user, mono: true)
                labeledField(L("remote.host.port"), text: $port, width: 64, mono: true)
            }
            labeledField(L("remote.host.identityFile"), text: $identityFile, mono: true)

            HStack {
                Toggle(L("remote.host.useSSHConfig"), isOn: $useSSHConfigOnly)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                Spacer()
                Button(action: add) {
                    Text(L("settings.trusted.add"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(canAdd ? DS.onGreen : DS.textTertiary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(canAdd ? DS.green : DS.neutralBtn)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
                .animation(DS.settingsFade, value: canAdd)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    /// A small caption ABOVE a boxed, bordered `TextField` — never a bare placeholder on transparent ground,
    /// so it reads unambiguously as "type here" rather than static label text.
    private func labeledField(_ caption: String, text: Binding<String>, width: CGFloat? = nil, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(DS.textTertiary)
                .lineLimit(1)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: mono ? .monospaced : .default))
                .foregroundStyle(DS.textPrimary)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.codeBG)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.line, lineWidth: 1)
                )
                .accessibilityLabel(caption)
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
    }

    private var canAdd: Bool {
        let host = trimmed(hostname)
        // A hostname starting with `-` would be parsed by ssh as an option (already defused by `--` in
        // RemoteExec.connectionArgs, but block it at entry too); whitespace inside is never a valid host.
        // A port, when given, must be a real one — not silently dropped to ssh's default. Invalid input just
        // keeps "Add" disabled, matching how empty fields already do — no new string.
        return !trimmed(label).isEmpty
            && !host.isEmpty
            && !host.hasPrefix("-")
            && !host.contains(where: \.isWhitespace)
            && (trimmed(port).isEmpty || parsedPort != nil)
    }

    /// The port as typed, when it is one (1…65535); nil for an empty field or anything else.
    private var parsedPort: Int? {
        Int(trimmed(port)).flatMap { (1...65535).contains($0) ? $0 : nil }
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    private func add() {
        guard canAdd else { return }
        engine.addRemoteHost(RemoteHost(
            label: trimmed(label),
            hostname: trimmed(hostname),
            sshUser: trimmed(user).isEmpty ? nil : trimmed(user),
            port: parsedPort,
            identityFile: trimmed(identityFile).isEmpty ? nil : trimmed(identityFile),
            useSSHConfigOnly: useSSHConfigOnly
        ))
        onAdded()
    }
}

private struct RemoteHostRow: View {
    let host: RemoteHost
    let status: RemoteTranscriptPoller.HostStatus?
    let testResult: Result<String, RemoteExec.SSHError>?
    let installResult: StateEngine.RemoteHookInstallResult?
    let onToggle: () -> Void
    let onTest: () -> Void
    let onInstallHooks: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(host.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                Text(host.hostname)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
                Spacer()
                Toggle("", isOn: Binding(get: { host.enabled }, set: { _ in onToggle() }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(DS.green)
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(hovering ? DS.redText : DS.textTertiary)
                }
                .buttonStyle(.plain)
                .help(L("remote.host.remove"))
            }
            HStack(spacing: 8) {
                pillButton(L("remote.connection.test"), action: onTest)
                pillButton(L("remote.hooks.install"), action: onInstallHooks)
                if let testResult {
                    switch testResult {
                    case .success(let platform):
                        Text(L("remote.connection.success") + " (\(platform.isEmpty ? L("remote.platform.unknown") : platform))")
                            .font(.system(size: 9))
                            .foregroundStyle(DS.greenText)
                    case .failure(let e):
                        Text(Lf("remote.connection.failed", e.message))
                            .font(.system(size: 9))
                            .foregroundStyle(DS.redText)
                            .lineLimit(1)
                    }
                } else if let installResult {
                    switch installResult {
                    case .installed:
                        Text(L("remote.hooks.installed"))
                            .font(.system(size: 9))
                            .foregroundStyle(DS.greenText)
                    case .failed(let msg):
                        Text(Lf("remote.hooks.install.failed", host.label, msg))
                            .font(.system(size: 9))
                            .foregroundStyle(DS.redText)
                            .lineLimit(1)
                    }
                }
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

    /// A real filled pill button (not plain text) so a clickable action always LOOKS clickable. This is a
    /// DISTINCT visual from `WidgetQuickSettings`'s `segmentPill` (smaller font 9, radius 6, no active
    /// state), so it deliberately does NOT share that helper.
    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DS.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.neutralBtn)
                )
        }
        .buttonStyle(.plain)
    }

    private var dotColor: Color {
        guard let status else { return DS.textTertiary }
        if status.connected { return DS.green }
        if status.lastError != nil { return DS.redText }
        return DS.textTertiary
    }
}
