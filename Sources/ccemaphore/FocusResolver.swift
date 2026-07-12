import AppKit
import ApplicationServices

/// Accessibility helpers for probing Cursor's window / AX tree. Historically this also resolved "which
/// chat is the user looking at" to suppress on-screen notifications, but the floating-widget redesign
/// removed toast notifications, so that resolver is gone. What remains is the Accessibility trust check
/// (surfaced in the app) and the `--ax-dump` diagnostic, which prints Cursor's focused-window AX subtree
/// to see whether the active chat tab's title is exposed. Best-effort; never blocks or crashes without
/// Accessibility.
enum FocusResolver {
    /// Accessibility trust state (System Settings ▸ Privacy ▸ Accessibility). Cheap to query.
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Prompt for Accessibility (opens the System Settings deep-link the first time). Returns the
    /// state right now (usually false until the user flips the switch and we re-check later).
    @discardableResult
    static func requestAccessibility() -> Bool {
        // Key string literal avoids the Unmanaged<CFString> import ambiguity of kAXTrustedCheckOptionPrompt.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Cursor identification

    /// Cursor is ToDesktop-packaged; match by name too in case the bundle id changes across builds.
    /// (Also used by DeepLinker's deferred deep-link to detect "Cursor is now frontmost".)
    static func isCursor(_ app: NSRunningApplication) -> Bool {
        if app.localizedName == "Cursor" { return true }
        return app.bundleIdentifier?.contains("todesktop") ?? false
    }

    /// One-shot read of an app's focused-window title. nil ⇒ Accessibility not granted, no focused
    /// window, or no title — callers must treat nil as "can't verify", not "wrong window".
    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let window = copyElement(app, kAXFocusedWindowAttribute) else { return nil }
        return copyString(window, kAXTitleAttribute)
    }

    /// Every ON-SCREEN window of a running app, paired with its title — unlike `focusedWindowTitle`,
    /// this doesn't require the app to already be frontmost. Used by `DeepLinker.focusRemote` to find an
    /// already-open VS Code Remote-SSH window by matching the host in its title (VS Code titles a
    /// Remote-SSH window `… [SSH: <host>]`), so a remote jump can RAISE the existing window instead of
    /// asking the `code` CLI / `vscode://` URI to open one — both of which were observed to always spawn
    /// a fresh window rather than reusing one already open for that remote folder.
    static func windowTitles(pid: pid_t) -> [(window: AXUIElement, title: String)] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { w in copyString(w, kAXTitleAttribute).map { (w, $0) } }
    }

    /// Bring one specific window to the front and activate its owning app. Best-effort: AX action
    /// failures are silently ignored (mirrors every other jump path in this codebase — a failed focus is
    /// a no-op, never a crash or a visible error).
    static func raiseWindow(_ window: AXUIElement, appPid: pid_t) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: appPid) {
            if #available(macOS 14.0, *) { app.activate() }
            else { app.activate(options: [.activateIgnoringOtherApps]) }
        }
    }

    // MARK: - Accessibility reads

    private static func copyElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success, let value else { return nil }
        // Defensive: only reinterpret when the value really is an AXUIElement. `as!` to a bare CF type is
        // an unchecked reinterpret (it never traps), so a wrong-typed value would silently become a bogus
        // element; a type-id guard degrades to nil instead. (AX contract makes a mistype near-impossible,
        // but this costs nothing and removes the sharp edge.)
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyString(_ el: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func copyChildren(_ el: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success,
              let arr = value as? [AXUIElement] else { return [] }
        return arr
    }

    // MARK: - Diagnostic (`ccemaphore --ax-dump`)

    /// Dump the frontmost app, focused window, and a bounded slice of the AX tree, so we can see
    /// whether Cursor exposes the active chat tab's title (→ exact per-tab suppression).
    static func axDump() {
        let front = NSWorkspace.shared.frontmostApplication
        print("frontmost app : \(front?.localizedName ?? "?")  bundle=\(front?.bundleIdentifier ?? "?")  pid=\(front?.processIdentifier ?? -1)")
        print("is Cursor     : \(front.map(isCursor) ?? false)")
        print("AX trusted    : \(AXIsProcessTrusted())")
        guard AXIsProcessTrusted() else {
            print("\n→ Accessibility not granted. Enable ccemaphore in System Settings ▸ Privacy & Security ▸ Accessibility, then rerun.")
            return
        }
        guard let front, isCursor(front) else {
            print("\n→ Bring a Cursor window to the front, then rerun.")
            return
        }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        if let window = copyElement(app, kAXFocusedWindowAttribute) {
            print("focused window title: \(copyString(window, kAXTitleAttribute) ?? "(none)")")
            print("\n--- AX subtree (role · title/value/description) ---")
            dump(window, depth: 0, maxDepth: 7, budget: UncheckedCounter(400))
        } else {
            print("no focused window")
        }
    }

    private final class UncheckedCounter: @unchecked Sendable { var n: Int; init(_ n: Int) { self.n = n } }

    private static func dump(_ el: AXUIElement, depth: Int, maxDepth: Int, budget: UncheckedCounter) {
        guard depth <= maxDepth, budget.n > 0 else { return }
        let role = copyString(el, kAXRoleAttribute) ?? "?"
        let title = copyString(el, kAXTitleAttribute)
        let value = copyString(el, kAXValueAttribute)
        let desc = copyString(el, kAXDescriptionAttribute)
        let bits = [title, value, desc].compactMap { $0 }.filter { !$0.isEmpty }
        // Only print rows that carry text — that's where tab/chat titles would surface.
        if !bits.isEmpty {
            budget.n -= 1
            print(String(repeating: "  ", count: depth) + "\(role): " + bits.joined(separator: " | ").prefix(120))
        }
        for child in copyChildren(el) { dump(child, depth: depth + 1, maxDepth: maxDepth, budget: budget) }
    }
}
