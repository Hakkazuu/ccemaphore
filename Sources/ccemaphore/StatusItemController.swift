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

        let showItem = NSMenuItem(title: L("menubar.showLight"), action: #selector(toggleShowLight), keyEquivalent: "")
        showItem.target = self
        showItem.state = WidgetSettings.shared.visible ? .on : .off
        menu.addItem(showItem)

        let openItem = NSMenuItem(title: L("menubar.openPanel"), action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        openItem.state = FloatingWidgetController.shared.pinnedOpen ? .on : .off
        menu.addItem(openItem)

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
        // "Open panel" while the light is hidden used to do nothing — `togglePinnedPanel` bails on
        // `!settings.visible`. Show the light first so the menu item always opens the panel (V16b). The
        // light panel persists across a hidden state (it's ordered out, not destroyed), so the pin lands
        // even though the actual re-show is applied one runloop turn later.
        if !WidgetSettings.shared.visible { WidgetSettings.shared.visible = true }
        FloatingWidgetController.shared.togglePinnedPanel()
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
