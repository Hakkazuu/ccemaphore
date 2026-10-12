import AppKit
import Combine

/// Manual `NSStatusItem` replacing SwiftUI's `MenuBarExtra` (v3 of the menu-bar surface). `MenuBarExtra`
/// in `.menu` style gives no raw "the icon itself was clicked" event separate from its dropdown — every
/// click, regardless of button, opens the same menu. That's fine for a pure dropdown, but it can't
/// support two DIFFERENT behaviors per mouse button: LEFT-click shows the Show-light/Open-panel/Quit
/// menu (the original, familiar behavior), RIGHT-click PINS the management panel open (stays open,
/// bypassing hover auto-collapse, until the SAME right-click toggles it closed again — like "Показать
/// огонёк" is a persistent toggle, not a momentary action). Only a manually-owned `NSStatusItem`
/// (inspecting `NSApp.currentEvent` inside its action) can tell the two clicks apart.
@MainActor
final class StatusItemController {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        // `.variableLength`, not `.squareLength` — a fixed square width wraps "🟡 2" onto two stacked
        // lines instead of the single-line "glyph + count" the old MenuBarExtra label rendered (observed
        // live). Variable length sizes the item to fit its title on one line, same as MenuBarExtra did.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Emoji keeps its color in the menu bar (SF Symbols render as monochrome templates), and the
        // distinct glyphs double as the non-color accessibility cue — same rationale as the old
        // MenuBarExtra label.
        item.button?.title = StateEngine.shared.menuBarText
        item.button?.action = #selector(handleClick)
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        // Re-render the title whenever the engine's published state changes (menuBarText is derived from
        // `color`/`sessions`, not itself @Published, so listen on the engine's own objectWillChange).
        StateEngine.shared.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.updateTitle() } }
            .store(in: &cancellables)
        // Also refresh on language switch — the right-click menu's item labels are localized and are
        // rebuilt fresh on each right-click, but re-set here too in case a future title ever carries text.
        LocalizationManager.shared.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.updateTitle() } }
            .store(in: &cancellables)
    }

    private func updateTitle() {
        // This fires on EVERY engine objectWillChange (each render, several times a second under load), but
        // menuBarText is derived and usually unchanged. Skip the reassign when it hasn't changed — an
        // NSStatusItem title set re-lays-out the status bar, so the no-op churn is real (F4).
        let new = StateEngine.shared.menuBarText
        if statusItem?.button?.title != new { statusItem?.button?.title = new }
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            FloatingWidgetController.shared.togglePinnedPanel()
        } else {
            showMenu()
        }
    }

    /// Built fresh on every left-click (not cached) so the "Показать огонёк" checkmark and localized
    /// labels always reflect the current `WidgetSettings`/language state. Attached to the status item
    /// only for the duration of this one click — `statusItem.menu` is cleared right after
    /// `performClick(nil)` returns, so a later RIGHT-click still reaches `handleClick` instead of
    /// re-opening this menu (AppKit shows `statusItem.menu`, when set, unconditionally on any click).
    private func showMenu() {
        let menu = NSMenu()
        // Enabled state is set explicitly: some update items are disabled (Restart while a permission request
        // is pending), which `autoenablesItems` would silently re-enable. Every other item stays enabled.
        menu.autoenablesItems = false

        let showItem = NSMenuItem(title: L("menubar.showLight"), action: #selector(toggleShowLight), keyEquivalent: "")
        showItem.target = self
        showItem.state = WidgetSettings.shared.visible ? .on : .off
        menu.addItem(showItem)

        let openItem = NSMenuItem(title: L("menubar.openPanel"), action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        openItem.state = FloatingWidgetController.shared.pinnedOpen ? .on : .off
        menu.addItem(openItem)

        let updateItems = updateMenuItems()
        if !updateItems.isEmpty {
            menu.addItem(.separator())
            for item in updateItems { menu.addItem(item) }
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L("menu.quit"), action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func toggleShowLight() { WidgetSettings.shared.visible.toggle() }
    @objc private func openPanel() {
        let widget = FloatingWidgetController.shared
        // The item is checked while the panel is pinned, so this click closes it. Leave the setting alone
        // then: with the light hidden, a pinned panel is an update panel shown over a temporary reveal, and
        // saving `visible` here would bring the light back for good.
        if widget.pinnedOpen {
            widget.togglePinnedPanel()
            return
        }
        // "Open panel" while the light is hidden used to do nothing — `togglePinnedPanel` bails on
        // `!settings.visible`. Show the light first so the menu item always opens the panel (V16b). The
        // light panel persists across a hidden state (it's ordered out, not destroyed), so the pin lands
        // even though the actual re-show is applied one runloop turn later.
        if !WidgetSettings.shared.visible { WidgetSettings.shared.visible = true }
        widget.togglePinnedPanel()
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: - Updates

    /// The update entry above Quit, mirroring the panel's update row: "Restart to Update to X" once it's
    /// staged (disabled while a permission request is pending — quitting would cut its blocking hook off),
    /// "Update to X…" when one is available ("Install Version X…" when its archive is already on disk, "View
    /// Version X…" for an informational item, which only opens its page), a progress line while a check /
    /// download runs, else "Check for Updates…" when the updater runs in this build (omitted otherwise). The
    /// actions that keep running bring the panel's update row into view (progress, errors, release notes).
    /// Debug builds add a submenu that simulates every phase.
    private func updateMenuItems() -> [NSMenuItem] {
        let updater = AppUpdater.shared
        var items: [NSMenuItem] = []
        switch updater.phase {
        case .readyToInstall(let u):
            items.append(restartGated(menuItem(Lf("menubar.update.restart", u.displayVersion), #selector(installUpdate))))
        case .restartNeeded(let version):
            items.append(restartGated(menuItem(Lf("menubar.update.restartNeeded", version), #selector(restartIntoUpdate))))
        case .available(let u):
            let title = u.isInformationalOnly ? Lf("menubar.update.view", u.displayVersion)
                      : u.isDownloaded ? Lf("menubar.update.install", u.displayVersion)
                      : Lf("menubar.update.available", u.displayVersion)
            let item = menuItem(title, #selector(installUpdate))
            // An informational update only opens its page — nothing quits, so nothing to gate.
            items.append(u.isInformationalOnly ? item : restartGated(item))
        // The progress items have their own `menubar.*` keys: the panel row's text is sentence case, while every
        // item in this menu follows the macOS menu style (Title Case in English).
        case .checking:
            items.append(menuItem(L("menubar.update.checking"), #selector(revealUpdates)))
        case let .downloading(u, fraction):
            let percent = fraction.map { " " + Fmt.pct(min(max($0, 0), 1) * 100) } ?? ""
            items.append(menuItem(Lf("menubar.update.downloading", u.displayVersion) + percent, #selector(revealUpdates)))
        case .extracting(let u, _):
            items.append(menuItem(Lf("menubar.update.extracting", u.displayVersion), #selector(revealUpdates)))
        case .installing(let u):
            let item = menuItem(Lf("menubar.update.installing", u.displayVersion), nil)
            item.isEnabled = false
            items.append(item)
        default:
            if updater.availability == .enabled {
                let item = menuItem(L("menubar.update.check"), #selector(checkForUpdates))
                item.isEnabled = updater.canCheckNow
                items.append(item)
            }
        }
        #if DEBUG
        items.append(simulateUpdateMenu())
        #endif
        return items
    }

    private func menuItem(_ title: String, _ action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Disable an install/restart item while a permission request is pending, with the reason as a tooltip.
    private func restartGated(_ item: NSMenuItem) -> NSMenuItem {
        let updater = AppUpdater.shared
        // In a release, `installWaitsForPermission` implies a pending request anyway; checking it too keeps a
        // simulated waiting state (Debug) in step with the row, which shows no Restart then.
        guard updater.restartBlockedByPermission || updater.installWaitsForPermission else { return item }
        item.isEnabled = false
        item.toolTip = L("update.blockedByPermission")
        return item
    }

    @objc private func checkForUpdates() {
        AppUpdater.shared.checkNow()
        revealUpdatePanel()
    }

    /// The offer's primary action — the row's Update / Install / Restart / Open. A download (or the install of a
    /// downloaded archive) keeps running, so the panel opens on its progress. Restart quits and relaunches in a
    /// moment: the panel shows "Installing…" only where the light is up anyway — a hidden light isn't shown just
    /// to vanish with the app. An informational item only opens its page in the browser.
    @objc private func installUpdate() {
        let phase = AppUpdater.shared.phase
        AppUpdater.shared.install()
        switch phase {
        case .available(let u) where u.isInformationalOnly:
            break
        case .available:
            revealUpdatePanel()
        default:
            FloatingWidgetController.shared.showUpdatePanel()
        }
    }

    /// Quits and relaunches from the bundle on disk: nothing to watch.
    @objc private func restartIntoUpdate() { AppUpdater.shared.restartNow() }

    @objc private func revealUpdates() { revealUpdatePanel() }

    /// Bring the panel's update row into view after an update action: open + pin the panel, showing the light
    /// for it if the user hid it — but only while that panel is open. The saved "Show light" setting is never
    /// flipped here: that brought the light back for good (also across the relaunch of an install), and
    /// through the presence beacon changed how long the permission hook waits. The pin is the update row's:
    /// it's handed back to hover once the result has been seen, or the phase is idle again (see
    /// `FloatingWidgetController.showUpdatePanel`).
    private func revealUpdatePanel() {
        FloatingWidgetController.shared.showUpdatePanel(revealingLight: true)
    }

    #if DEBUG
    /// Developer-only (Debug builds; English on purpose): force any `UpdatePhase` so every update surface —
    /// panel row, Settings section, this menu — can be checked visually with ⌘R. The updater itself never
    /// runs in Debug. "Clear" ends the simulation.
    private func simulateUpdateMenu() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let current = AppUpdater.shared.phase
        let currentFlags = AppUpdater.shared.simulatedFlags
        for (index, sample) in Self.simulatedPhases.enumerated() {
            let item = NSMenuItem(title: sample.title, action: #selector(simulateUpdatePhase(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = sample.phase == current && sample.flags == currentFlags ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear", action: #selector(simulateUpdatePhase(_:)), keyEquivalent: "")
        clear.target = self
        clear.tag = -1
        submenu.addItem(clear)

        let root = NSMenuItem(title: "Debug: Simulate Update", action: nil, keyEquivalent: "")
        root.submenu = submenu
        return root
    }

    @objc private func simulateUpdatePhase(_ sender: NSMenuItem) {
        let samples = Self.simulatedPhases
        let sample = samples.indices.contains(sender.tag) ? samples[sender.tag] : (title: "", phase: .idle, flags: [])
        AppUpdater.shared.simulate(sample.phase, flags: sample.flags)
        if sample.phase != .idle { revealUpdatePanel() }
    }

    /// One entry per `UpdatePhase` (plus the critical / informational / already-downloaded / unknown-size
    /// variants, every incompatibility and every failure kind), all around a sample 9.9.9 update with
    /// multi-section CHANGELOG-style notes. The rows' held states (`readyInstallsOnQuit`,
    /// `installWaitsForPermission`, `installNeedsAdministrator`) come from live Sparkle state in a release,
    /// so each variant sets them through `flags`.
    private static let simulatedPhases: [(title: String, phase: UpdatePhase, flags: AppUpdater.SimulatedFlags)] = {
        let notes = """
        ## [9.9.9] - 2026-10-09

        ### Added
        - **In-app updates** — check, download and restart into a new version right from the panel, in the
          app's own language. Three modes: automatic, notify only, off.
        - **Release notes inline** — this list renders from the version's `CHANGELOG.md` section:
          - nested items get a hollow bullet;
          - wrapped lines join their item.

        ### Changed
        1. The status menu mirrors the update row.
        2. Restart waits while a permission request is pending.

        ### Fixed
        - A *very* long line to check wrapping inside the capped, scrollable notes box — it should wrap \
        cleanly, never overflow the panel edge, and scroll once the box reaches its height cap.
        - See the [release page](https://github.com/hakkazuu/ccemaphore/releases) for everything else.
        """
        let page = URL(string: "https://github.com/hakkazuu/ccemaphore/releases")
        let update = UpdateInfo(displayVersion: "9.9.9", buildVersion: "999", releaseNotesMarkdown: notes,
                                releaseNotesURL: page, isCritical: false, isInformationalOnly: false, infoURL: nil)
        var critical = update
        critical.isCritical = true
        var informational = update
        informational.isInformationalOnly = true
        informational.infoURL = page
        informational.releaseNotesMarkdown = nil
        var downloaded = update
        downloaded.isDownloaded = true
        return [
            ("Consent", .consent, []),
            ("Checking", .checking, []),
            ("Up to date", .upToDate, []),
            ("Incompatible: needs macOS 14.0", .incompatible(version: "9.9.9", requirement: .newerMacOS(minimum: "14.0")), []),
            ("Incompatible: needs a newer macOS", .incompatible(version: "9.9.9", requirement: .newerMacOS(minimum: nil)), []),
            ("Incompatible: macOS 15.0 or earlier", .incompatible(version: "9.9.9", requirement: .olderMacOS(maximum: "15.0")), []),
            ("Incompatible: Apple silicon", .incompatible(version: "9.9.9", requirement: .appleSilicon), []),
            ("Available", .available(update), []),
            ("Available (needs admin password)", .available(update), [.needsAdministrator]),
            ("Available (critical)", .available(critical), []),
            ("Available (informational)", .available(informational), []),
            ("Available (downloaded)", .available(downloaded), []),
            ("Downloading (size unknown)", .downloading(update, fraction: nil), []),
            ("Downloading 42%", .downloading(update, fraction: 0.42), []),
            ("Extracting 70%", .extracting(update, fraction: 0.7), []),
            ("Ready to install (installs on quit)", .readyToInstall(update), [.installsOnQuit]),
            ("Ready to install (waiting for permission)", .readyToInstall(update), [.installsOnQuit, .waitsForPermission]),
            ("Ready to install (Restart only, fallback)", .readyToInstall(update), []),
            ("Installing", .installing(update), []),
            ("Installing (waiting for permission)", .installing(update), [.waitsForPermission]),
            ("Failed: network", .failed(.network), []),
            ("Failed: verification", .failed(.verification), []),
            ("Failed: download", .failed(.download), []),
            ("Failed: install", .failed(.install), []),
            ("Failed: didn't install 9.9.9", .failed(.didNotInstall(version: "9.9.9")), []),
            ("Failed: other", .failed(.other), []),
            ("Move to Applications", .moveToApplications, []),
            ("Updated to 9.9.9", .updated(version: "9.9.9"), []),
            ("Restart needed (9.9.9)", .restartNeeded(version: "9.9.9"), []),
        ]
    }()
    #endif
}
