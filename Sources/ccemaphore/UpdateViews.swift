import SwiftUI
import AppKit

/// SwiftUI surfaces of the in-app updater: the panel note row (every `UpdatePhase` but `.idle`) and the
/// Settings › Updates section. They render `AppUpdater` state and call its public actions only — no Sparkle
/// import here (the shared types live in `UpdateModel`). All text goes through `L()`/`Lf()`, and both views
/// observe `LocalizationManager`, so a language switch re-renders them live (CLAUDE.md l10n rule 4).

// MARK: - Panel note row

/// The update row under the panel header — the `claudeMissingNote` slot, outside the tab switch, so it shows
/// on Чаты and Настройки alike. The panel embeds it unconditionally and it renders NOTHING while `.idle`: it
/// observes `AppUpdater` itself, so a download's progress ticks re-render this row, never the session list.
///
/// Compact by design: glyph · title (+ a trailing control) · optional detail / progress / actions / caption.
/// "What's new" expands the embedded release notes inline, in a height-capped scroll box.
struct UpdateNoteRow: View {
    @ObservedObject var updater: AppUpdater
    /// Observed so the row re-renders when a permission request arrives or clears: Restart/Install are
    /// disabled while one is pending (`restartBlockedByPermission`), which is derived from
    /// `StateEngine.pendingRequests` — `AppUpdater` doesn't republish it.
    @ObservedObject var engine: StateEngine
    @ObservedObject private var loc = LocalizationManager.shared
    /// "What's new" disclosure. Collapsed by default; reset whenever the update it belongs to changes.
    @State private var notesExpanded = false

    var body: some View {
        // A real (possibly empty) container, so the reset below stays attached while the row is hidden.
        VStack(spacing: 0) {
            if updater.phase != .idle {
                phaseContent
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { DS.line.frame(height: 1) }
            }
        }
        .onChange(of: updater.phase.update?.buildVersion) { _ in notesExpanded = false }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch updater.phase {
        case .idle:
            EmptyView()
        case .consent:
            consentNote
        case .checking:
            note(.spinner, L("update.checking"), trailing: {
                UpdateButton(title: L("update.action.cancel")) { updater.cancel() }
            })
        case .upToDate:
            note(.symbol("checkmark.circle.fill", DS.green), L("update.upToDate.title"),
                 detail: Lf("update.upToDate.body", updater.currentVersion),
                 trailing: { dismissGlyph })
        case let .incompatible(version, requirement):
            // A newer version exists but can't run here: say so (and why) instead of "up to date". Its notes
            // (`openReleaseNotes` → that version's release page) help decide whether to update macOS for it.
            note(.symbol("info.circle", DS.textSecondary), requirement.title(version: version),
                 detail: Lf("update.incompatible.body", updater.currentVersion),
                 trailing: {
                     TextLinkButton(title: L("update.action.notes"), symbol: "arrow.up.right") { updater.openReleaseNotes() }
                     dismissGlyph
                 })
        case .available(let u):
            availableNote(u)
        case let .downloading(u, fraction):
            note(.symbol("arrow.down.circle", DS.textSecondary), Lf("update.downloading", u.displayVersion), trailing: {
                if let fraction { percentLabel(fraction) }
            }, content: {
                ThinProgressBar(fraction: fraction)
                FlowRow { UpdateButton(title: L("update.action.cancel")) { updater.cancel() } }
            })
        case let .extracting(u, fraction):
            note(.symbol("arrow.down.circle", DS.textSecondary), Lf("update.extracting", u.displayVersion), trailing: {
                percentLabel(fraction)
            }, content: {
                ThinProgressBar(fraction: fraction)
            })
        case .readyToInstall(let u):
            readyNote(u)
        case .installing(let u):
            note(.spinner, Lf("update.installing", u.displayVersion), detail: installingDetail)
        case .failed(let failure):
            failedNote(failure)
        case .moveToApplications:
            note(.symbol("exclamationmark.triangle.fill", DS.ctxWarning), L("update.move.title"),
                 detail: L("update.move.body"), content: {
                FlowRow {
                    UpdateButton(title: L("update.action.reveal"), kind: .primary) { updater.revealInFinder() }
                }
            })
        case .updated(let version):
            note(.symbol("checkmark.circle.fill", DS.green), Lf("update.updated", version), trailing: {
                TextLinkButton(title: L("update.action.notes"), symbol: "arrow.up.right") { updater.openReleaseNotes() }
                dismissGlyph
            })
        case .restartNeeded(let version):
            restartNeededNote(version)
        }
    }

    // MARK: Phases with more than one control

    /// First launch with a working updater: pick an `UpdateMode`. "Update automatically" wears the primary
    /// (preselected) look, but nothing is chosen until a button is clicked.
    private var consentNote: some View {
        note(.symbol("arrow.down.circle", DS.textSecondary), L("update.consent.title"),
             detail: L("update.consent.body"), content: {
            FlowRow {
                UpdateButton(title: L("update.action.automatic"), kind: .primary) { updater.setMode(.automatic) }
                UpdateButton(title: L("update.action.notify")) { updater.setMode(.notifyOnly) }
                UpdateButton(title: L("update.action.off")) { updater.setMode(.off) }
            }
        })
    }

    /// Found, awaiting the user's click. A critical update offers neither Later nor Skip; an informational one
    /// has nothing to download, so its primary action opens its page — and, quitting nothing, is never blocked.
    /// One whose archive is already on disk (`isDownloaded`: Sparkle kept it because installing needs an
    /// administrator password) offers Install — and promises nothing on quit: quitting doesn't install it.
    /// When this Mac will ask for that password (`installNeedsAdministrator`) the row says so up front: the
    /// prompt appears as the install starts, and ccemaphore waits on it until it's answered.
    private func availableNote(_ u: UpdateInfo) -> some View {
        let blocked = !u.isInformationalOnly && updater.restartBlockedByPermission
        // The downloaded body already mentions the password; an informational item installs nothing.
        let asksPassword = !u.isInformationalOnly && !u.isDownloaded && updater.installNeedsAdministrator
        let icon: NoteIcon = u.isCritical
            ? .symbol("exclamationmark.triangle.fill", DS.ctxWarning)
            : .symbol(u.isDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle", DS.textSecondary)
        let title = u.isCritical ? Lf("update.available.critical.title", u.displayVersion)
                  : u.isDownloaded ? Lf("update.available.downloaded.title", u.displayVersion)
                  : Lf("update.available.title", u.displayVersion)
        let detail: String? = u.isInformationalOnly ? L("update.available.info.body")
                            : u.isDownloaded ? L("update.available.downloaded.body")
                            : u.isCritical ? L("update.available.critical.body") : nil
        let primary = u.isInformationalOnly ? L("update.action.open")
                    : u.isDownloaded ? L("update.action.install") : L("update.action.update")
        return note(icon, title, detail: detail, trailing: { notesToggle(u) }, content: {
            FlowRow {
                UpdateButton(title: primary, kind: .primary, enabled: !blocked) { updater.install() }
                if !u.isCritical {
                    UpdateButton(title: L("update.action.later")) { updater.later() }
                    UpdateButton(title: L("update.action.skip")) { updater.skipVersion() }
                }
            }
            if blocked { caption(L("update.blockedByPermission")) }
            if asksPassword { caption(L("update.available.adminPassword")) }
            notesBox(u)
        })
    }

    /// Downloaded and validated: one click quits, installs and relaunches — unless a permission request is
    /// pending (quitting would cut its blocking hook off), in which case the caption says why. The body tells
    /// what else installs it: a silently staged installer also installs whenever the app quits
    /// (`readyInstallsOnQuit`); otherwise only Restart does. When the user already chose to install and only
    /// the pending request holds the last step (`installWaitsForPermission`), it continues by itself — the
    /// body says so and there's no Restart to press. Later hides the row (critical: no Later).
    private func readyNote(_ u: UpdateInfo) -> some View {
        let waiting = updater.installWaitsForPermission
        let blocked = !waiting && updater.restartBlockedByPermission
        let detail = waiting ? L("update.ready.body.waiting")
                   : updater.readyInstallsOnQuit ? L("update.ready.body") : L("update.ready.body.restart")
        return note(.symbol("arrow.down.circle.fill", DS.green), Lf("update.ready.title", u.displayVersion),
                    detail: detail, trailing: { notesToggle(u) }, content: {
            if !waiting || !u.isCritical {
                FlowRow {
                    if !waiting {
                        UpdateButton(title: L("update.action.restart"), kind: .primary, enabled: !blocked) {
                            updater.install()
                        }
                    }
                    if !u.isCritical {
                        UpdateButton(title: L("update.action.later")) { updater.later() }
                    }
                }
            }
            if blocked { caption(L("update.blockedByPermission")) }
            notesBox(u)
        })
    }

    /// Install triggered, the app about to quit. A pending permission request holds the quit until it's
    /// answered (Sparkle's postpone hook, or the retry that waits it out), so the row says that instead of
    /// promising a restart "in a moment".
    private var installingDetail: String {
        updater.installWaitsForPermission || updater.restartBlockedByPermission
            ? L("update.installing.waiting") : L("update.installing.body")
    }

    /// The last attempt failed: Try again / Dismiss — plus, for an install that didn't take, the version's
    /// release page, where the body tells the user to download it by hand (`openReleaseNotes` maps this phase
    /// to that page).
    private func failedNote(_ failure: UpdateFailure) -> some View {
        note(.symbol("exclamationmark.triangle.fill", DS.ctxWarning), failure.title, detail: failure.detail, content: {
            FlowRow {
                UpdateButton(title: L("update.action.retry"), kind: .primary, enabled: updater.canCheckNow) {
                    updater.checkNow()
                }
                UpdateButton(title: L("update.action.dismiss")) { updater.dismiss() }
                if failure.offersReleasePage {
                    TextLinkButton(title: L("update.notes.openPage"), symbol: "arrow.up.right") {
                        updater.openReleaseNotes()
                    }
                }
            }
        })
    }

    /// The bundle on disk is newer than this process (updated from another session / replaced by hand).
    private func restartNeededNote(_ version: String) -> some View {
        let blocked = updater.restartBlockedByPermission
        return note(.symbol("arrow.clockwise.circle", DS.textSecondary), Lf("update.restartNeeded.title", version),
                    detail: L("update.restartNeeded.body"), content: {
            FlowRow {
                UpdateButton(title: L("update.action.restart"), kind: .primary, enabled: !blocked) { updater.restartNow() }
            }
            if blocked { caption(L("update.blockedByPermission")) }
        })
    }

    // MARK: Release notes

    /// "What's new": an inline disclosure when the feed embeds notes, else a link that opens the release page
    /// (`openReleaseNotes` falls back to the version's GitHub release). An informational update without notes
    /// gets none — its Open button already goes to that page.
    @ViewBuilder
    private func notesToggle(_ u: UpdateInfo) -> some View {
        if u.hasEmbeddedNotes {
            TextLinkButton(title: L("update.action.notes"), symbol: notesExpanded ? "chevron.down" : "chevron.right",
                           accessibilityValue: notesExpanded ? L("a11y.expanded") : L("a11y.collapsed")) {
                notesExpanded.toggle()
            }
        } else if !u.isInformationalOnly {
            TextLinkButton(title: L("update.action.notes"), symbol: "arrow.up.right") { updater.openReleaseNotes() }
        }
    }

    @ViewBuilder
    private func notesBox(_ u: UpdateInfo) -> some View {
        if notesExpanded, u.hasEmbeddedNotes, let markdown = u.releaseNotesMarkdown {
            VStack(alignment: .leading, spacing: 5) {
                ReleaseNotesView(markdown: markdown)
                TextLinkButton(title: L("update.notes.openPage"), symbol: "arrow.up.right") { updater.openReleaseNotes() }
            }
        }
    }

    // MARK: Building blocks

    /// The frame every phase shares: glyph · title · trailing control on one line, then the detail text
    /// and any extra content (progress, actions, caption, notes) indented under the title.
    private func note<Trailing: View, Content: View>(
        _ icon: NoteIcon,
        _ title: String,
        detail: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                icon.view
                    .frame(width: Self.iconColumn, height: 14)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing()
            }
            // Only when there's something under the title — an empty block would still earn the 6 pt gap.
            if detail != nil || Content.self != EmptyView.self {
                VStack(alignment: .leading, spacing: 7) {
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(DS.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    content()
                }
                .padding(.leading, Self.iconColumn + 8)
            }
        }
    }

    private static let iconColumn: CGFloat = 14

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(DS.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func percentLabel(_ fraction: Double) -> some View {
        Text(Fmt.pct(min(max(fraction, 0), 1) * 100))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(DS.textTertiary)
            .fixedSize()
    }

    private var dismissGlyph: some View {
        DismissGlyph(help: L("update.action.dismiss")) { updater.dismiss() }
    }
}

/// The leading glyph of a note row: an SF Symbol in a semantic tint, or a small spinner for work in flight.
/// Decoration only — the title beside it says the same in words — so VoiceOver skips it.
private enum NoteIcon {
    case symbol(String, Color)
    case spinner

    @ViewBuilder
    var view: some View {
        switch self {
        case let .symbol(name, color):
            Image(systemName: name)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .accessibilityHidden(true)
        case .spinner:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.72)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Settings › Updates

/// Settings › Updates: the installed version, the update mode (automatic / notify only / off) with a one-line
/// explanation, Check now with its inline result and the last-check time, what a check discloses, and the
/// bundled third-party licenses. When the updater can't run in this process the controls give way to the
/// reason (`availability`) — except in Debug builds, which show both so the section can be reviewed with ⌘R.
struct UpdateSettingsSection: View {
    @ObservedObject var updater: AppUpdater
    @ObservedObject private var loc = LocalizationManager.shared

    /// Sparkle's license (bundled as a resource — its bsdiff / Mark Hamlin clauses require shipping the
    /// notice with the binary). Nil only if the resource went missing from the build.
    private static let noticesURL = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")

    var body: some View {
        VStack(spacing: 0) {
            versionRow
            if updater.availability != .enabled { unavailableNote }
            if showsControls {
                modePicker
                checkRow
                privacyNote
            }
            if let url = Self.noticesURL {
                UpdateSettingsRow(label: L("settings.updates.licenses"), action: { _ = NSWorkspace.shared.open(url) }) {
                    rowSubtitle(L("settings.updates.licenses.subtitle"))
                } trailing: {
                    Text(verbatim: "↗")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.textSecondary)
                }
            }
        }
    }

    private var showsControls: Bool {
        #if DEBUG
        return true
        #else
        return updater.availability == .enabled
        #endif
    }

    // MARK: Rows

    private var versionRow: some View {
        HStack(spacing: 8) {
            Text(L("settings.updates.version"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.textSecondary)
            Spacer(minLength: 8)
            Text(verbatim: "\(updater.currentVersion) (\(updater.currentBuild))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(DS.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Why the updater isn't running here, as a sentence the user can act on.
    private var unavailableNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(DS.textTertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(unavailableReason)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if updater.availability == .needsMoveToApplications {
                    UpdateButton(title: L("update.action.reveal")) { updater.revealInFinder() }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var unavailableReason: String {
        switch updater.availability {
        case .enabled:                 ""
        case .debugBuild:              L("settings.updates.unavailable.debug")
        case .notDeveloperIDSigned:    L("settings.updates.unavailable.unsigned")
        case .needsMoveToApplications: L("settings.updates.unavailable.move")
        case .misconfigured:           L("settings.updates.unavailable.misconfigured")
        }
    }

    /// Automatic / Notify only / Off — the same segment pills as the widget and groups settings — plus a
    /// one-line explanation of the selected mode. No pill is active until the consent is answered.
    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(UpdateMode.allCases) { mode in
                    segmentPill(modeLabel(mode), active: updater.mode == mode) { updater.setMode(mode) }
                }
            }
            Text(modeSubtitle)
                .font(.system(size: 10))
                .foregroundStyle(DS.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func modeLabel(_ mode: UpdateMode) -> String {
        switch mode {
        case .automatic:  L("settings.updates.mode.automatic")
        case .notifyOnly: L("settings.updates.mode.notifyOnly")
        case .off:        L("settings.updates.mode.off")
        }
    }

    private var modeSubtitle: String {
        switch updater.mode {
        case .automatic?:  L("settings.updates.mode.subtitle.automatic")
        case .notifyOnly?: L("settings.updates.mode.subtitle.notifyOnly")
        case .off?:        L("settings.updates.mode.subtitle.off")
        case nil:          L("settings.updates.mode.subtitle.unset")
        }
    }

    /// "Check now" (the whole row is the target) · when the last check ran · the result of the latest check on
    /// its own line (so a long translation wraps instead of squeezing the row) · a spinner while checking,
    /// else the ↻ glyph. The relative time re-renders every 30 s, so "just now" ages without other changes.
    private var checkRow: some View {
        UpdateSettingsRow(label: L("settings.updates.checkNow"), enabled: updater.canCheckNow,
                          action: { updater.checkNow() }) {
            VStack(alignment: .leading, spacing: 3) {
                TimelineView(.periodic(from: Date(), by: 30)) { _ in
                    rowSubtitle(lastCheckText)
                }
                checkResult
            }
        } trailing: {
            if updater.phase == .checking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
                    .frame(width: 16, height: 14)
            } else {
                Text(verbatim: "↻")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.textSecondary)
                    .opacity(updater.canCheckNow ? 1 : 0.45)
            }
        }
    }

    private var lastCheckText: String {
        guard let date = updater.lastCheckDate else { return L("settings.updates.neverChecked") }
        return Lf("settings.updates.lastCheck", Fmt.relative(date))
    }

    /// What the latest check found, at full strength even while the row itself is disabled: up to date, a newer
    /// version this Mac can't run, the update it found (its row above has the actions), or what failed.
    /// Nothing otherwise.
    @ViewBuilder
    private var checkResult: some View {
        switch updater.phase {
        case .upToDate:
            resultLine(L("settings.updates.status.upToDate"), symbol: "checkmark", color: DS.greenText)
        case let .incompatible(version, requirement):
            resultLine(requirement.title(version: version), symbol: "info.circle", color: DS.textSecondary)
        case .failed(let failure):
            resultLine(failure.title, symbol: "exclamationmark.triangle.fill", color: DS.ctxWarning)
        case .available(let u):
            resultLine(u.isDownloaded ? Lf("update.available.downloaded.title", u.displayVersion)
                                      : Lf("update.available.title", u.displayVersion),
                       symbol: "arrow.down.circle", color: DS.textSecondary)
        case .readyToInstall(let u):
            resultLine(Lf("update.ready.title", u.displayVersion), symbol: "arrow.down.circle.fill", color: DS.textSecondary)
        default:
            EmptyView()
        }
    }

    private func resultLine(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }

    /// What a check discloses — the in-app counterpart of the README's privacy section.
    private var privacyNote: some View {
        Text(L("settings.updates.privacy"))
            .font(.system(size: 10))
            .foregroundStyle(DS.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 4)
    }

    private func rowSubtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(DS.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One tappable settings row in the panel's flat idiom (label + subtitle on the left, a trailing view, hover
/// highlight) — the same metrics as `FloatingPanelView`'s `SettingsAppRow`, plus a custom subtitle view and a
/// tap action together. A real `Button`, so VoiceOver meets ONE element — label and subtitle read together, the
/// trailing glyph / spinner skipped as decoration — that is announced as dimmed while disabled. A disabled row
/// dims its label only, so a live status in the subtitle stays readable.
private struct UpdateSettingsRow<Subtitle: View, Trailing: View>: View {
    let label: String
    var enabled: Bool = true
    let action: () -> Void
    @ViewBuilder let subtitle: Subtitle
    @ViewBuilder let trailing: Trailing
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.textSecondary)
                        .opacity(enabled ? 1 : 0.45)
                    subtitle
                }
                Spacer(minLength: 8)
                trailing
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering && enabled ? DS.hoverRow : .clear)
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(FlatRowButtonStyle())
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

/// Draws the row exactly as composed: no pressed tint and no disabled dimming of its own — `UpdateSettingsRow`
/// dims just its label, so the status beside it stays at full strength.
private struct FlatRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - Controls

/// A small pill action — the panel's filled-pill idiom (cf. `RemoteHostsView`'s "Add"): the primary action
/// is the green fill, the others the neutral graphite fill. A pill rather than bare text, so an action
/// always looks clickable.
private struct UpdateButton: View {
    enum Kind { case primary, secondary }

    let title: String
    var kind: Kind = .secondary
    var enabled: Bool = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }

    // Disabled → plain graphite with tertiary text for every kind: a faded green pill read as muddy (dark)
    // or washed out (light), with its label barely legible.
    private var foreground: Color {
        guard enabled else { return DS.textTertiary }
        switch kind {
        case .primary:   return DS.onGreen
        case .secondary: return hovering ? DS.textPrimary : DS.textSecondary
        }
    }

    private var fill: Color {
        guard enabled else { return DS.neutralBtn }
        switch kind {
        case .primary:   return hovering ? DS.green.opacity(0.82) : DS.green
        case .secondary: return hovering ? DS.neutralBtnHover : DS.neutralBtn
        }
    }
}

/// A borderless text action with a trailing symbol — a chevron for the inline "What's new" disclosure, an
/// arrow for something that opens in the browser. The symbol is decoration (VoiceOver reads the title only);
/// a disclosure passes its expanded / collapsed state as `accessibilityValue`.
private struct TextLinkButton: View {
    let title: String
    let symbol: String
    var accessibilityValue: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title).lineLimit(1)
                Image(systemName: symbol).font(.system(size: 7.5, weight: .bold))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(hovering ? DS.textPrimary : DS.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .accessibilityValue(Text(accessibilityValue ?? ""))
    }
}

/// The ✕ that dismisses a one-shot note (up to date / updated).
private struct DismissGlyph: View {
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovering ? DS.textPrimary : DS.textTertiary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

/// A 3 pt progress line in neutral graphite (the status hues stay reserved for agent state): a determinate
/// fill for a known fraction, or a gently sweeping segment while the download's total size is unknown.
private struct ThinProgressBar: View {
    /// 0…1, or nil while the total is unknown.
    let fraction: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.neutralBtn)
                if let fraction {
                    Capsule().fill(DS.textSecondary)
                        .frame(width: max(3, geo.size.width * min(max(fraction, 0), 1)))
                        .animation(.linear(duration: 0.2), value: fraction)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        Capsule().fill(DS.textSecondary)
                            .frame(width: geo.size.width * 0.28)
                            .offset(x: geo.size.width * 0.72 * (sin(t * 2.2) + 1) / 2)
                    }
                }
            }
        }
        .frame(height: 3)
    }
}

/// Lays its subviews out left to right and wraps to a new line when the next one doesn't fit — so the action
/// buttons' longer translations (de / fr / ru) wrap instead of truncating or overflowing the fixed-width panel.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, maxWidth: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for (index, size) in zip(line.indices, line.sizes) {
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                      proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, maxWidth)   // a lone over-long item truncates instead of overflowing
            if !line.indices.isEmpty, line.width + spacing + size.width > maxWidth {
                lines.append(line)
                line = Line()
            }
            line.width += (line.indices.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
            line.sizes.append(size)
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}

// MARK: - Release notes

/// Carries the measured height of the notes out of their `ScrollView` — a bare ScrollView in this
/// fit-to-content panel has no intrinsic height and collapses to ~0 (same fix as the panel body).
private struct NotesHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The update's embedded release notes (its CHANGELOG section, English Markdown): `#` headings in bold,
/// `-` / `*` / `1.` list items with a bullet (nested by indent), wrapped continuation lines joined, and inline
/// Markdown (bold, italics, `code`, links) via `AttributedString`. Content-tall below the cap, scrolling past it.
private struct ReleaseNotesView: View {
    let markdown: String
    var maxHeight: CGFloat = 132
    @State private var contentHeight: CGFloat = 60

    var body: some View {
        let blocks = NotesMarkdown.parse(markdown)
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { item in
                    blockView(item.element, first: item.offset == 0)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(DS.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { geo in
                Color.clear.preference(key: NotesHeightKey.self, value: geo.size.height)
            })
        }
        .frame(height: min(contentHeight, maxHeight))
        .onPreferenceChange(NotesHeightKey.self) { contentHeight = $0 }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.codeBG))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func blockView(_ block: NotesMarkdown.Block, first: Bool) -> some View {
        switch block {
        case .heading(let text):
            Text(NotesMarkdown.inline(text))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DS.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, first ? 0 : 4)
        case let .item(level, marker, text):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: level > 0 && marker == "•" ? "◦" : marker)
                    .foregroundStyle(DS.textTertiary)
                Text(NotesMarkdown.inline(text))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(level) * 11)
        case .paragraph(let text):
            Text(NotesMarkdown.inline(text))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The small Markdown subset CHANGELOG sections use, turned into display blocks. Inline syntax is left in
/// the text for `inline(_:)`; anything unrecognised renders as a plain paragraph, never dropped.
private enum NotesMarkdown {
    enum Block {
        case heading(String)
        case item(level: Int, marker: String, text: String)
        case paragraph(String)
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var afterBlank = false
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { afterBlank = true; continue }
            let indent = line.prefix(while: { $0 == " " }).count
            defer { afterBlank = false }

            if trimmed.hasPrefix("#") {
                let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { blocks.append(.heading(text)) }
                continue
            }
            // Thematic breaks ("---") and link-reference definitions ("[1.3.0]: https://…") carry no prose.
            let compact = trimmed.filter { $0 != " " }
            if compact.count >= 3, Set(compact).count == 1, "-*_".contains(compact.first!) { continue }
            if trimmed.range(of: #"^\[[^\]]+\]:\s*\S+"#, options: .regularExpression) != nil { continue }

            if let item = listItem(trimmed) {
                blocks.append(.item(level: min(indent / 2, 2), marker: item.marker, text: item.text))
                continue
            }
            // A continuation line extends the item / paragraph above it: indented under a list item (also
            // across a blank line), or directly following without a blank line.
            if let last = blocks.last {
                switch last {
                case let .item(level, marker, text) where indent > 0 || !afterBlank:
                    blocks[blocks.count - 1] = .item(level: level, marker: marker, text: text + " " + trimmed)
                    continue
                case let .paragraph(text) where !afterBlank:
                    blocks[blocks.count - 1] = .paragraph(text + " " + trimmed)
                    continue
                default:
                    break
                }
            }
            blocks.append(.paragraph(trimmed))
        }
        return blocks
    }

    /// "- text" / "* text" / "+ text" → ("•", text); "1. text" / "1) text" → ("1.", text).
    private static func listItem(_ line: String) -> (marker: String, text: String)? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            return ("•", line.dropFirst(bullet.count).trimmingCharacters(in: .whitespaces))
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return ("\(digits).", rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    /// Inline Markdown (bold, italics, `code`, links, strikethrough); the literal text if it doesn't parse.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Contract helpers (display only)

private extension UpdatePhase {
    /// The update a phase is about, if any.
    var update: UpdateInfo? {
        switch self {
        case .available(let u), .readyToInstall(let u), .installing(let u),
             .downloading(let u, _), .extracting(let u, _):
            return u
        default:
            return nil
        }
    }
}

private extension UpdateInfo {
    var hasEmbeddedNotes: Bool {
        !(releaseNotesMarkdown ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private extension UpdateRequirement {
    /// What keeps `version` off this Mac, e.g. "Version 1.4.0 needs macOS 14.0 or later" — the row title and
    /// the Settings result line. Without the feed's bound, the sentence names no macOS version.
    func title(version: String) -> String {
        switch self {
        case .newerMacOS(let minimum):
            guard let minimum, !minimum.isEmpty else { return Lf("update.incompatible.newerMacOS.unknown", version) }
            return Lf("update.incompatible.newerMacOS", version, minimum)
        case .olderMacOS(let maximum):
            guard let maximum, !maximum.isEmpty else { return Lf("update.incompatible.olderMacOS.unknown", version) }
            return Lf("update.incompatible.olderMacOS", version, maximum)
        case .appleSilicon:
            return Lf("update.incompatible.appleSilicon", version)
        }
    }
}

/// Localized text per failure — the UI never shows Sparkle's own error descriptions, which follow the
/// macOS language rather than the in-app one (and are only partly translated).
private extension UpdateFailure {
    var title: String {
        switch self {
        case .network:                  L("update.failed.network.title")
        case .verification:             L("update.failed.verification.title")
        case .download:                 L("update.failed.download.title")
        case .install:                  L("update.failed.install.title")
        case .didNotInstall(let v):     Lf("update.failed.didNotInstall.title", v)
        case .other:                    L("update.failed.other.title")
        }
    }

    var detail: String {
        switch self {
        case .network:                  L("update.failed.network.body")
        case .verification:             L("update.failed.verification.body")
        case .download:                 L("update.failed.download.body")
        case .install:                  L("update.failed.install.body")
        case .didNotInstall:            L("update.failed.didNotInstall.body")
        case .other:                    L("update.failed.other.body")
        }
    }

    /// The body sends the user to download the version by hand, so the row links its release page.
    var offersReleasePage: Bool {
        if case .didNotInstall = self { return true }
        return false
    }
}

// MARK: - Relative time

extension Fmt {
    /// "2 hours ago" / "yesterday" in the active language; anything under a minute reads "just now" — not a
    /// ticking seconds count, nor the formatter's bare "now" ("Last checked: now" reads oddly in every
    /// language). Locale-aware like the rest of `Fmt` (main-actor use only, see its invariant).
    static func relative(_ date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return L("time.justNow") }
        return RelativeFormatterCache.formatter(for: Loc.effectiveCode()).localizedString(for: date, relativeTo: now)
    }
}

/// One `RelativeDateTimeFormatter` per language, so switching the picker reformats without leaking a stale
/// formatter — the same lock-guarded cache shape as `Fmt`'s `DateFormatter` cache.
private enum RelativeFormatterCache {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: RelativeDateTimeFormatter] = [:]

    static func formatter(for code: String) -> RelativeDateTimeFormatter {
        lock.lock(); defer { lock.unlock() }
        if let f = cache[code] { return f }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: code)
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        cache[code] = f
        return f
    }
}
