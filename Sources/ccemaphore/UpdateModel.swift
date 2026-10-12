import Foundation

// MARK: - In-app updates: the shared contract (Sparkle 2.10.0)
//
// The CORE (`AppUpdater`, `UpdateUserDriver`, `UpdateSupport`) produces these values; the UI
// (`UpdateViews`, `FloatingPanelView`, `StatusItemController`) only renders them and calls
// `AppUpdater`'s public actions. This file deliberately does NOT import Sparkle, so no view ever
// depends on a Sparkle type. Change it only together with both sides.

/// Whether the in-app updater runs in this process, and why not. Decided once at launch.
enum UpdateAvailability: Equatable, Sendable {
    /// Sparkle is running: automatic checks follow `UpdateMode`; "Check now" works.
    case enabled
    /// A Debug build (Xcode ⌘R). Never self-updates: Sparkle would replace the DerivedData copy with
    /// the Developer-ID release and break the signature-keyed grants (see CLAUDE.md hard rules).
    case debugBuild
    /// Not signed with a Developer ID certificate (ad-hoc, Apple Development, unsigned) — a local
    /// build that must never be swapped for the release.
    case notDeveloperIDSigned
    /// Running from a read-only volume (the mounted DMG) or an App Translocation path. Sparkle refuses
    /// to update from there — silently, for scheduled checks — so the user has to move the app.
    case needsMoveToApplications
    /// Sparkle failed to start (e.g. the `SUPublicEDKey` placeholder was never replaced). `detail` is
    /// developer-facing — logged and printed by `--update-status`, never shown verbatim in the UI.
    case misconfigured(detail: String)
}

/// The user's update preference: answered once in the first-launch consent row, then editable in
/// Settings. Persisted by `AppUpdater`.
enum UpdateMode: String, CaseIterable, Identifiable, Sendable {
    /// Check daily and download in the background; one click restarts into the new version.
    case automatic
    /// Check daily and show "available"; download only when the user clicks Update.
    case notifyOnly
    /// Never check on its own; "Check now" still works.
    case off

    var id: String { rawValue }
}

/// A found update, in UI terms (no Sparkle types).
struct UpdateInfo: Equatable, Sendable {
    /// Human version, e.g. "1.3.1" (appcast `sparkle:shortVersionString`).
    var displayVersion: String
    /// Build number, e.g. "5" (appcast `sparkle:version`, compared with our `CFBundleVersion`).
    var buildVersion: String
    /// Embedded release notes — Markdown (CI embeds the version's CHANGELOG section), if present.
    var releaseNotesMarkdown: String?
    /// External release notes / release page, if the feed provides one.
    var releaseNotesURL: URL?
    /// Critical update: the UI offers neither "Skip" nor "Later".
    var isCritical: Bool
    /// Informational-only item: nothing to download; `infoURL` is opened instead of installing.
    var isInformationalOnly: Bool
    var infoURL: URL?
    /// The archive is already downloaded (Sparkle resumed a kept download, e.g. after the silent install
    /// needed an administrator password). Installing still needs the user's click — and possibly that
    /// password — so it is shown as `.available`, never as "installs on quit".
    var isDownloaded: Bool = false
}

/// Why a newer version found by a user-initiated check can't run on this Mac.
enum UpdateRequirement: Equatable, Sendable {
    /// Needs a newer macOS (`minimum` is the feed's `sparkle:minimumSystemVersion`, if known).
    case newerMacOS(minimum: String?)
    /// Needs an older macOS (`maximum` is the feed's `sparkle:maximumSystemVersion`, if known).
    case olderMacOS(maximum: String?)
    /// Needs an Apple silicon Mac (`sparkle:hardwareRequirements` = arm64).
    case appleSilicon
}

/// Why the last update attempt failed. The UI maps each case to localized text; details go to the log.
enum UpdateFailure: Equatable, Sendable {
    /// The update server (GitHub) couldn't be reached.
    case network
    /// The update failed EdDSA / code-signing / feed validation and was NOT installed.
    case verification
    /// The download failed or was interrupted.
    case download
    /// The installer failed, or the administrator authorization was denied.
    case install
    /// We quit to install `version`, but came back still on the old build.
    case didNotInstall(version: String)
    /// Anything else (logged).
    case other
}

/// The single thing every update surface renders. Exactly one phase at a time.
///
/// Precedence when several apply (AppUpdater resolves it in `recomputePhase`): `restartNeeded` >
/// `failed(.didNotInstall)` from the previous launch (kept above the session so the launch-time re-check
/// can't erase the report within seconds; its Retry / Dismiss bring the re-found offer forward) > any
/// non-idle Sparkle session phase (`checking`, `upToDate`, `incompatible`, `available`, `downloading`,
/// `extracting`, `readyToInstall`, `installing`, `failed`) > `updated` (any later session activity clears
/// it for good) > `moveToApplications` > `consent` > `idle`. An informational note never hides an
/// actionable update.
enum UpdatePhase: Equatable, Sendable {
    /// Nothing to show.
    case idle
    /// First launch with a working updater: ask for an `UpdateMode`.
    case consent
    /// A user-initiated check is in flight (cancellable via `AppUpdater.cancel()`).
    case checking
    /// A user-initiated check found nothing. Transient: AppUpdater returns to `.idle` on its own.
    case upToDate
    /// A user-initiated check found `version`, but it can't run on this Mac (see `UpdateRequirement`).
    /// Transient like `.upToDate`.
    case incompatible(version: String, requirement: UpdateRequirement)
    /// An update was found and awaits the user's Update click (`UpdateInfo.isDownloaded` tells whether
    /// the archive is already on disk).
    case available(UpdateInfo)
    /// Downloading; `fraction` is 0…1, or nil while the total size is unknown.
    case downloading(UpdateInfo, fraction: Double?)
    /// Extracting / validating the downloaded archive; `fraction` is 0…1.
    case extracting(UpdateInfo, fraction: Double)
    /// Downloaded and validated: one click quits, installs and relaunches. Whether quitting installs it
    /// too is `AppUpdater.readyInstallsOnQuit`; whether it is only waiting for a pending permission
    /// request is `AppUpdater.installWaitsForPermission`.
    case readyToInstall(UpdateInfo)
    /// Install was triggered; the app is about to quit.
    case installing(UpdateInfo)
    /// The last attempt failed; the UI offers Retry (`checkNow()`) / Dismiss (`dismiss()`).
    case failed(UpdateFailure)
    /// Running from a DMG / translocated path: can't update (or safely install hooks) until moved.
    case moveToApplications
    /// One-shot note after a successful update and relaunch.
    case updated(version: String)
    /// The bundle on disk is newer than this running process (updated from another user session, or
    /// replaced by hand): restart to finish (`AppUpdater.restartNow()`).
    case restartNeeded(version: String)
}
