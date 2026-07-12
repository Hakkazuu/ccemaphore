import AppKit

/// Belt-and-suspenders Dock hiding. The bundle's `LSUIElement` keeps the Dock icon away for the
/// installed .app; `.accessory` does the same when running the bare binary during development
/// (`swift run`), where Launch Services hasn't read a bundle Info.plist. `.accessory` (not
/// `.prohibited`) so a future Settings window can still take focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Start file logging first: run the retention sweep + hourly timer, and record the launch.
        Log.bootstrapApp()
        // Build the shared engine now so watchers/timers start immediately (it also publishes the
        // presence beacon the blocking permission hook reads).
        _ = StateEngine.shared
        // Bring up the always-on-screen floating widget (the redesign's primary surface). System
        // toast notifications were removed — all interaction lives at the light / ribbon / panel.
        FloatingWidgetController.shared.start()
        // The menu-bar status item (v3 — a manual NSStatusItem, see StatusItemController's doc comment
        // for why SwiftUI's MenuBarExtra can't support right-click-pins/left-click-menu).
        StatusItemController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean-exit removal of the presence beacon so the hook sees "not running" immediately. A crash
        // or force-quit skips this, but the hook's `kill(pid,0)` check then reports the same — so this
        // is only an optimization for the tidy case, not load-bearing for correctness.
        AppPresence.remove()
    }
}
