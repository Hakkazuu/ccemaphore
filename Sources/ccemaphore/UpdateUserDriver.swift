import Foundation
import Sparkle

/// Custom Sparkle user driver: renders every update state inside ccemaphore's own panel (in the in-app
/// language) instead of Sparkle's standard windows. Implements the complete `SPUUserDriver` protocol of
/// Sparkle 2.10.0 and forwards each callback to `AppUpdater`, which owns the state and every block
/// Sparkle hands over.
///
/// Sparkle calls all of this on the main thread (`NS_SWIFT_UI_ACTOR`). Rule of the protocol: every reply,
/// acknowledgement and cancellation block must be called exactly once, at the right time — a block that
/// is never called stalls the updater session for good. Acknowledgements (not found, error, installed)
/// are therefore answered here immediately; the panel keeps its own phase for display. Replies the user
/// has to make (update found, ready to install) are held by `AppUpdater` until a button answers them,
/// and dropped (never called) only when Sparkle itself tears the session down in
/// `dismissUpdateInstallation` — exactly what Sparkle's standard driver does.
@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {
    /// Set by `AppUpdater` before the updater starts. Weak only to avoid a cycle; the singleton lives for
    /// the whole process. Every forwarder still answers Sparkle if it's ever nil, so nothing stalls.
    weak var owner: AppUpdater?

    // MARK: - Permission

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        guard let owner else {
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
            return
        }
        owner.driverPermissionRequest(reply: reply)
    }

    // MARK: - Checking

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        owner?.driverCheckStarted(cancellation: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let owner else { reply(.dismiss); return }
        owner.driverUpdateFound(Self.info(from: appcastItem), stage: state.stage,
                                userInitiated: state.userInitiated, reply: reply)
    }

    /// Only for a `<sparkle:releaseNotesLink>` (HTML). Our feed embeds Markdown notes instead and
    /// `AppUpdater` declines the extra download (`shouldDownloadReleaseNotesForUpdate` → false), so this
    /// is a no-op kept for protocol completeness; the row links to the release page.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        Log.app.info("update: release notes downloaded (\(downloadData.data.count) bytes, \(downloadData.mimeType ?? "?")) — not shown, the row links to the release page")
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        Log.app.warn("update: release notes download failed: \(Self.describe(error as NSError))")
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        owner?.driverNotFound(error as NSError)
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        owner?.driverError(error as NSError)
        acknowledgement()
    }

    // MARK: - Downloading / extracting

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        owner?.driverDownloadStarted(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        owner?.driverDownloadExpectedLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        owner?.driverDownloadReceived(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        owner?.driverExtractionStarted()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        owner?.driverExtractionProgress(progress)
    }

    // MARK: - Installing

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let owner else { reply(.dismiss); return }
        owner.driverReadyToInstall(reply: reply)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        owner?.driverInstalling(applicationTerminated: applicationTerminated, retry: retryTerminatingApplication)
    }

    /// Only reached when the updater outlives the install — never for a self-update (we are the app that
    /// was replaced). The post-relaunch "updated" note comes from the install marker instead.
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        owner?.driverInstalled(relaunched: relaunched)
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        owner?.driverDismiss()
    }

    /// "Check now" while an update (or its progress) is already shown: bring the panel row forward.
    func showUpdateInFocus() {
        owner?.driverShowInFocus()
    }

    // MARK: - Mapping (no Sparkle type crosses into the UI)

    /// `SUAppcastItem` → `UpdateInfo`. Release notes are taken only when the feed embeds them as
    /// Markdown or plain text (CI embeds the version's CHANGELOG section); HTML descriptions are left out
    /// and the row links to the release page instead.
    nonisolated static func info(from item: SUAppcastItem) -> UpdateInfo {
        let format = item.itemDescriptionFormat?.lowercased()
        let notes = item.itemDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        let markdown = (format == "markdown" || format == "plain-text") && notes?.isEmpty == false ? notes : nil
        return UpdateInfo(displayVersion: item.displayVersionString,
                          buildVersion: item.versionString,
                          releaseNotesMarkdown: markdown,
                          releaseNotesURL: item.releaseNotesURL ?? item.fullReleaseNotesURL,
                          isCritical: item.isCriticalUpdate,
                          isInformationalOnly: item.isInformationOnlyUpdate,
                          infoURL: item.infoURL)
    }

    /// Sparkle / URL-loading error → the UI's failure category (details go to the log). `downloading`
    /// tells an archive download apart from fetching the feed, which share `SUDownloadError`.
    ///
    /// A bad update signature never arrives at the top level: with `SUVerifyUpdateBeforeExtraction` the
    /// archive's EdDSA signature (and, after extraction, its code signature) is checked inside Autoupdate, and
    /// the app sees an installer error (`SUInstallationError`) with the `SUValidationError` one or two levels
    /// down `NSUnderlyingErrorKey` (SUUpdateValidator → AppInstaller → SPUInstallerDriver
    /// `_reportInstallerError`). So the chain is searched first: a validation / signature failure anywhere in
    /// it means the update was rejected as not authentic — `.verification`, not "the installer failed".
    nonisolated static func failure(for error: NSError, downloading: Bool) -> UpdateFailure {
        if containsVerificationFailure(error) { return .verification }
        if error.domain == NSURLErrorDomain { return downloading ? .download : .network }
        guard error.domain == SUSparkleErrorDomain, let code = SUError(rawValue: OSStatus(truncatingIfNeeded: error.code)) else {
            return .other
        }
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        switch code {
        case .downloadError:
            return downloading ? .download : .network
        case .temporaryDirectoryError:
            return downloading ? .download : .other
        case .appcastError:
            return underlying?.domain == NSURLErrorDomain ? .network : .verification
        case .appcastParseError, .signatureError, .validationError, .notValidUpdateError,
             .insufficientSigningError, .noPublicDSAFoundError:
            return .verification
        case .unarchivingError:
            return .download
        case .fileCopyFailure, .authenticationFailure, .missingUpdateError, .missingInstallerToolError,
             .relaunchError, .installationError, .downgradeError, .installationCanceledError,
             .installationAuthorizeLaterError, .agentInvalidationError, .installationWriteNoPermissionError:
            return .install
        default:
            return .other
        }
    }

    /// `error` followed by its `NSUnderlyingErrorKey` chain (bounded — Sparkle nests at most a few levels).
    nonisolated static func errorChain(_ error: NSError, maxDepth: Int = 6) -> [NSError] {
        var chain = [error]
        while chain.count < maxDepth, let next = chain[chain.count - 1].userInfo[NSUnderlyingErrorKey] as? NSError {
            chain.append(next)
        }
        return chain
    }

    /// A Sparkle validation or signature failure anywhere in `error`'s chain.
    nonisolated static func containsVerificationFailure(_ error: NSError) -> Bool {
        errorChain(error).contains { e in
            guard e.domain == SUSparkleErrorDomain else { return false }
            let code = SUError(rawValue: OSStatus(truncatingIfNeeded: e.code))
            return code == .validationError || code == .signatureError
        }
    }

    /// One log-friendly line: domain/code and description of the error and of each underlying error.
    nonisolated static func describe(_ error: NSError) -> String {
        errorChain(error).map { "\($0.domain)#\($0.code) \($0.localizedDescription)" }.joined(separator: " ← ")
    }
}
