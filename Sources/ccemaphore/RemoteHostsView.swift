import SwiftUI

/// The "Remote Hosts" settings section: list configured SSH hosts (connection dot, enable toggle, test/
/// remove) plus a compact add form. Embedded into `FloatingPanelView.settingsScreen` the same way
/// `WidgetQuickSettingsView`/the trusted-commands section are — this file owns only the section's own
/// layout, not the panel chrome around it.
///
/// Every text field gets its own caption label ABOVE it plus a visible boxed background (not just a
/// bare placeholder on transparent ground) — an earlier version relied on placeholder text alone and
/// users couldn't tell the fields were editable at all. Same for the row actions ("Test Connection" /
/// "Install hooks"): they're real filled pill buttons now, not plain text that reads as a caption.
///
/// A brand-new top-level view per CLAUDE.md's localization rule 4: it observes `LocalizationManager`
/// directly (its own `@State` doesn't change on a language switch, so SwiftUI would otherwise skip
/// re-invoking `body` and leave the `L(...)` labels stale).
struct RemoteHostsView: View {
    @ObservedObject var engine: StateEngine
    @ObservedObject private var loc = LocalizationManager.shared

    @State private var newLabel = ""
    @State private var newHostname = ""
    @State private var newUser = ""
    @State private var newPort = ""
    @State private var newIdentityFile = ""
    @State private var newUseSSHConfigOnly = false

    var body: some View {
        VStack(spacing: 0) {
            SettingsSectionHeader(label: L("remote.menu.title"))
            Text(L("remote.explainer"))
                .font(.system(size: 10))
                .foregroundStyle(DS.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            if engine.remoteHosts.isEmpty {
                Text(L("remote.list.empty"))
                    .font(.system(size: 10))
                    .foregroundStyle(DS.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
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

            addForm
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(DS.line).frame(height: 1).padding(.bottom, 2)

            HStack(spacing: 8) {
                labeledField(L("remote.host.label"), text: $newLabel, width: 84)
                labeledField(L("remote.host.hostname"), text: $newHostname, mono: true)
            }
            HStack(spacing: 8) {
                labeledField(L("remote.host.user"), text: $newUser, width: 84, mono: true)
                labeledField(L("remote.host.port"), text: $newPort, width: 48, mono: true)
            }
            labeledField(L("remote.host.identityFile"), text: $newIdentityFile, mono: true)

            HStack {
                Toggle(L("remote.host.useSSHConfig"), isOn: $newUseSSHConfigOnly)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                Spacer()
                Button(action: addHost) {
                    Text(L("remote.host.add"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(canAdd ? DS.primaryText : DS.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(canAdd ? DS.green : DS.neutralBtn)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A small mono caption ABOVE a boxed, bordered `TextField` — never a bare placeholder on
    /// transparent ground, so it reads unambiguously as "type here" rather than static label text.
    private func labeledField(_ caption: String, text: Binding<String>, width: CGFloat? = nil, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(DS.textTertiary)
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
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
    }

    private var canAdd: Bool {
        let host = newHostname.trimmingCharacters(in: .whitespaces)
        // A hostname starting with `-` would be parsed by ssh as an option (already defused by `--` in
        // RemoteExec.connectionArgs, but block it at entry too); whitespace inside is never a valid host.
        // Invalid input just keeps "Add" disabled, matching how empty fields already do — no new string.
        return !newLabel.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.isEmpty
            && !host.hasPrefix("-")
            && !host.contains(where: \.isWhitespace)
    }

    private func addHost() {
        guard canAdd else { return }
        let host = RemoteHost(
            label: newLabel.trimmingCharacters(in: .whitespaces),
            hostname: newHostname.trimmingCharacters(in: .whitespaces),
            sshUser: newUser.isEmpty ? nil : newUser,
            port: Int(newPort),
            identityFile: newIdentityFile.isEmpty ? nil : newIdentityFile,
            useSSHConfigOnly: newUseSSHConfigOnly
        )
        engine.addRemoteHost(host)
        newLabel = ""; newHostname = ""; newUser = ""; newPort = ""; newIdentityFile = ""
        newUseSSHConfigOnly = false
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
                            .foregroundStyle(DS.green)
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
                            .foregroundStyle(DS.green)
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
