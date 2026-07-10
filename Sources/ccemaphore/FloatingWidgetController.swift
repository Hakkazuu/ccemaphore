import AppKit
import SwiftUI
import Combine

/// AppKit host for the floating widget — the integration core. Owns the borderless, non-activating
/// `NSPanel` that floats over everything (incl. fullscreen Spaces) and hosts the SwiftUI tower /
/// ribbon, plus a second panel for the expanded management view.
///
/// Interaction model (v2): **no clicks on the light itself.** Hovering the light reveals the
/// management panel (the old toolbar menu — sessions, История/Обновить/Настройки/Выход); leaving it
/// collapses it back. Dragging still repositions it (unless "закрепить" is on). A pending permission
/// request takes the light over with the ribbon (the hover panel yields to it). The widget's own
/// appearance settings (opacity / size / pin) live only inside the panel's Настройки.
@MainActor
final class FloatingWidgetController: NSObject, NSWindowDelegate {
    static let shared = FloatingWidgetController()

    private let engine = StateEngine.shared
    private let settings = WidgetSettings.shared

    private var lightPanel: LightPanel?
    private var expandedPanel: NSPanel?
    private var expanded = false
    /// Set by `forceShowExpanded()` (the menu-bar "Open panel" escape hatch) so `hoverTick()` skips its
    /// ribbon auto-collapse for this one open — cleared by `hideExpanded()`. See `forceShowExpanded`.
    private var forcedOpen = false
    /// Set by `togglePinnedPanel()` (left-click on the menu-bar status item — see `StatusItemController`)
    /// to keep the panel open regardless of mouse position, until the SAME action closes it again. Unlike
    /// `forcedOpen`, this bypasses `hoverTick()` ENTIRELY (checked first, before the ribbon-preemption
    /// guard OR the mouse-leave collapse timer) — a true pin, not just a one-shot escape hatch.
    private(set) var pinnedOpen = false
    private var cancellables = Set<AnyCancellable>()
    /// Guards `windowDidResize`/`windowDidMove` re-entrancy while WE are setting the frame.
    private var adjustingFrame = false

    // Hover tracking (drives expand/collapse instead of clicks).
    private var hoverTimer: Timer?
    /// Observers for system events (display sleep/wake, active-Space switch, display reconfiguration)
    /// that can hide the expanded panel or pause the poll timer WITHOUT routing through our own
    /// collapse path — which used to strand `expanded=true` and kill hover until relaunch. Held so
    /// they outlive `start()`; the controller is a process-lifetime singleton so they're never removed.
    private var systemObservers: [NSObjectProtocol] = []
    private var insideSince: Date?
    private var outsideSince: Date?
    private let expandDelay: TimeInterval = 0.28    // hover intent before the panel opens
    private let collapseGrace: TimeInterval = 0.40  // slack so crossing the gap doesn't dismiss it
    /// When the panel was last ordered in — the ghost check below waits `ghostGrace` after this before
    /// trusting `occlusionState` (occlusion is delivered async, a beat after ordering).
    private var expandedSince: Date?
    /// Last ghost-window rebuild, so a persistently unhappy WindowServer is retried at a gentle pace
    /// instead of every 0.12s tick.
    private var lastGhostRebuild: Date = .distantPast
    private let ghostGrace: TimeInterval = 0.7
    private let ghostRebuildCooldown: TimeInterval = 2.0
    /// Remembered anchor edges so a content resize (ribbon appears, or size preset changes) re-pins the
    /// tower in place instead of growing from the bottom-left: the vertical CENTER stays put (the ribbon
    /// extends symmetrically from the light's middle, §6) and the tower's docked horizontal edge stays.
    /// Captured on the last move — NOT updated on resize — so toggling the ribbon returns to the same spot.
    private var savedCenterY: CGFloat?
    private var savedRight: CGFloat?
    private var savedLeft: CGFloat?

    /// New-alert detector + sound: the ribbon at the light IS the notification now (toasts are gone), so
    /// a newly-appearing request / question / completion chimes with our bundled alert sound. `alertedIds`
    /// holds what's currently alerting (live request ids + question-attention session ids + `done-<sid>`
    /// completion ids). `alertDepartedAt` remembers when each id last LEFT that set, so an id that merely
    /// flickers out and back within `alertReChimeCooldown` is NOT re-chimed — the guard against the
    /// click→optimistic-clear→disk-reread→red round-trip (fix 3a removes its source) and any transient
    /// state flap. A handed-off permission (`permission-native`) is not a separate id — it already chimed
    /// as a live request. Cooldown is set-membership based for present ids, so tick cadence can't re-arm it.
    private var alertedIds: Set<String> = []
    private var alertDepartedAt: [String: Date] = [:]
    private let alertReChimeCooldown: TimeInterval = 2.0
    private lazy var permSound: NSSound? = {
        guard let url = Bundle.main.url(forResource: "ccemaphore_notification", withExtension: "aiff") else { return nil }
        return NSSound(contentsOf: url, byReference: true)
    }()

    /// The ribbon is on screen — for a live broker request OR an attention item (native prompt / question).
    /// It owns the light: the hover panel is suppressed and the light forced fully opaque while it shows.
    private var hasRibbon: Bool {
        !engine.pendingRequests.isEmpty || !engine.attentionSessions.isEmpty || !engine.completionNotices.isEmpty
    }

    // MARK: - Lifecycle

    func start() {
        buildLightPanel()
        settings.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.applyWindowState() } }
            .store(in: &cancellables)
        engine.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.applyWindowState() } }
            .store(in: &cancellables)
        applyWindowState()
        startHoverTracking()
        registerSystemObservers()
    }

    /// Recover hover from system events that bypass our collapse path. Display sleep/wake can also
    /// pause the run-loop timer, and a Space switch / display reconfiguration can leave the light's
    /// cached frame disagreeing with its on-screen position (hover hit-tests the frame vs the cursor),
    /// so we collapse any stale expansion, re-arm the poll, and re-clamp the light onto the current
    /// screen. Cheap; fires only on real system events.
    private func registerSystemObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        systemObservers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recoverHover("wake", rearmTimer: true) }
        })
        systemObservers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recoverHover("space", rearmTimer: false) }
        })
        systemObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recoverHover("screens", rearmTimer: false) }
        })
    }

    private func recoverHover(_ why: String, rearmTimer: Bool) {
        if expanded { hideExpanded() }       // drop any stale expansion so hover re-opens cleanly
        if rearmTimer { startHoverTracking() }   // the run loop can drop the timer across sleep
        if let panel = lightPanel, let screen = panel.screen ?? NSScreen.main {
            if settings.visible, !panel.isVisible { panel.orderFrontRegardless() }
            adjustingFrame = true
            panel.setFrameOrigin(clamp(origin: panel.frame.origin, size: panel.frame.size, into: screen.visibleFrame))
            adjustingFrame = false
            captureAnchors(panel)
        }
        Log.watcher.info("hover recover (\(why))")
    }

    private func configure(_ panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The OS draws a rounded shadow OUTSIDE the window, tracing the alpha of the rounded vibrancy
        // content. This is the ONLY shadow now — the views carry no outer SwiftUI `.shadow` (one clipped
        // by the fit-to-content window edge rendered the old hard-cornered dark rectangle). Content
        // resizes call `invalidateShadow()` so this never lingers stale/square.
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // No implicit show/hide animation. The system plays a fade+scale on panel orderOut, and an
        // order-in that lands mid-animation (hover flapping, Space-switch recover) can strand the
        // WindowServer-side window: `isVisible` says true, `kCGWindowIsOnscreen` stays false, and the
        // "expanded" panel is pure air until relaunch (live-caught 2026-07-02, win #81814 alpha=0).
        // Hover reveal wants to be instant anyway.
        panel.animationBehavior = .none
    }

    /// Host SwiftUI in the panel and force the hosting view's layer clear, so the area OUTSIDE the
    /// rounded content (the window corners) shows the desktop through — otherwise the corners read as a
    /// sharp opaque rectangle.
    private func host<V: View>(_ root: V, in panel: NSPanel) {
        let controller = NSHostingController(rootView: root)
        panel.contentViewController = controller
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func buildLightPanel() {
        let root = LightRootView(engine: engine, settings: settings)
        let panel = LightPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 90),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        configure(panel)
        // The light draws its OWN depth via a SwiftUI shadow on the housing (see `LightTowerView`). The
        // OS window shadow is disabled here because it traces the alpha of the *whole* window — it can't
        // tell the frosted housing from the soft lamp glows, so over the padded (glow-room) window it
        // rendered a big dark rounded-rect halo around the light. One contained SwiftUI shadow instead.
        panel.hasShadow = false
        panel.delegate = self
        host(root, in: panel)
        self.lightPanel = panel
        restorePosition(panel)
        panel.orderFrontRegardless()
    }

    // MARK: - Window state (opacity / pin / visibility)

    private func applyWindowState() {
        guard let panel = lightPanel else { return }
        if settings.visible {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else {
            panel.orderOut(nil)
            hideExpanded()
        }
        panel.isMovableByWindowBackground = !settings.pinned
        updateLightOpacity()
        // The ribbon at the visible light is where the user answers a permission request, so the broker
        // treats "widget visible" as "user is reachable now" (→ a real wait window).
        engine.setWidgetVisible(settings.visible)
        // The ribbon owns the light — never overlap it with the hover panel (unless the user explicitly
        // force-opened it via the menu-bar "Open panel" item, or pinned it open — see `forceShowExpanded`
        // / `togglePinnedPanel`).
        if hasRibbon, expanded, !forcedOpen, !pinnedOpen { hideExpanded() }
        // The ribbon IS the notification now: chime when a genuinely NEW live request, question, or
        // completion appears. An id that merely flickered out and back within `alertReChimeCooldown`
        // (a transient state flap, or the pre-fix-3a click round-trip) is NOT re-chimed; a continuously
        // present id never re-chimes because the guard is set membership, not an age comparison.
        let now = Date()
        let alerts = Set(engine.pendingRequests.map(\.requestId))
            .union(engine.attentionSessions.filter { $0.kind == .question }.map(\.id))
            .union(engine.completionNotices.map { "done-\($0.id)" })
        let appeared = alerts.subtracting(alertedIds)
        for id in alertedIds.subtracting(alerts) { alertDepartedAt[id] = now }   // record departures for the guard
        let fresh = appeared.filter { id in
            guard let left = alertDepartedAt[id] else { return true }            // not recently on screen → real new
            return now.timeIntervalSince(left) > alertReChimeCooldown           // gone long enough → a new episode
        }
        if !fresh.isEmpty {
            permSound?.stop(); permSound?.play()
            Log.watcher.info("chime new=\(fresh.count) [\(fresh.map { String($0.prefix(14)) }.sorted().joined(separator: ","))]")
        } else if !appeared.isEmpty {
            Log.watcher.debug("chime suppressed (flicker) [\(appeared.map { String($0.prefix(14)) }.sorted().joined(separator: ","))]")
        }
        alertedIds = alerts
        alertDepartedAt = alertDepartedAt.filter { now.timeIntervalSince($0.value) <= alertReChimeCooldown }   // prune old marks
        // Content (tower ↔ ribbon, item count) may have changed the window size → recompute the native
        // rounded shadow so it never lingers as a stale square from the previous frame.
        panel.invalidateShadow()
        if expanded { positionExpandedPanel() }
    }

    /// The light reflects the user's opacity live — even while the management panel is open — so dragging
    /// the Opacity slider shows its effect immediately (the panel is a SEPARATE window and always stays
    /// at full opacity for readability). Only a shown ribbon forces the light fully opaque, since it
    /// carries text the user must read to decide / act (§8).
    private func updateLightOpacity() {
        guard let panel = lightPanel else { return }
        panel.alphaValue = hasRibbon ? 1.0 : settings.opacity
    }

    // MARK: - Hover-driven expand / collapse (no clicks)

    private func startHoverTracking() {
        hoverTimer?.invalidate()
        // Poll the cursor against the light/panel rects: reliable regardless of window activation
        // (a non-activating panel doesn't reliably get mouse-moved events), and cheap at ~8 Hz.
        // Registered in `.common` (not the implicit `.default` of `scheduledTimer`) so it keeps firing
        // during modal/event-tracking run-loop passes — window drags, menu tracking, and the run-loop
        // modes some fullscreen video players spin — instead of silently stalling until they end.
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.hoverTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    private func hoverTick() {
        guard let light = lightPanel, light.isVisible, settings.visible else { return }
        // Pinned open (menu-bar left-click) bypasses hover entirely — no ribbon-preemption check, no
        // mouse-leave collapse timer. Only `togglePinnedPanel()` closes it.
        if pinnedOpen { return }
        // While the ribbon is on screen it owns the light — suppress the hover panel. Skipped when the
        // user explicitly force-opened it (menu-bar "Open panel"): normal mouse-leaves-the-panel
        // collapse still applies below, just not this auto-collapse-because-a-request-arrived path.
        if hasRibbon, !forcedOpen {
            if expanded { hideExpanded() }
            return
        }
        // Self-heal: `expanded` must agree with the panel ACTUALLY being on screen. A system event
        // (display sleep/wake, Space switch, entering/leaving fullscreen video) can drop the panel
        // without routing through hideExpanded(), stranding the flag `true` — after which the
        // `if !expanded` guard below never re-opens on hover. That's the "hover stops expanding after
        // a few hours, fixed only by relaunch" bug. Reconcile to reality before deciding.
        if expanded, !(expandedPanel?.isVisible ?? false) {
            expanded = false; insideSince = nil; outsideSince = nil
            Log.watcher.info("hover self-heal: cleared stale expanded (panel off-screen)")
        }
        // Ghost-window heal: `isVisible` is only the CLIENT's "I ordered it in" flag. After heavy
        // Space churn the SERVER-side window can silently die — isVisible true, occlusionState never
        // .visible, nothing rendered (the "hover does nothing until relaunch" bug, live-caught
        // 2026-07-02: `hover expand` logged while kCGWindowIsOnscreen=false). occlusionState is the
        // WindowServer's truth, delivered a beat after ordering — so give it `ghostGrace`, then
        // rebuild the panel outright: a fresh window is exactly why relaunching always cured this.
        if expanded, let panel = expandedPanel, panel.isVisible,
           !panel.occlusionState.contains(.visible),
           Date().timeIntervalSince(expandedSince ?? .distantPast) > ghostGrace,
           Date().timeIntervalSince(lastGhostRebuild) > ghostRebuildCooldown {
            lastGhostRebuild = Date()
            rebuildExpandedPanel()
            return
        }
        // Reverse desync: the flag says collapsed but a panel window is still up (a path that skipped
        // hideExpanded()). Cheap to reconcile; keeps the recover path honest now that it only collapses
        // when `expanded` is set.
        if !expanded, let panel = expandedPanel, panel.isVisible { panel.orderOut(nil) }
        let p = NSEvent.mouseLocation
        let inLight = light.frame.insetBy(dx: -8, dy: -8).contains(p)
        let inPanel = expandedPanel.map { $0.isVisible && $0.frame.insetBy(dx: -8, dy: -8).contains(p) } ?? false
        // While the panel holds keyboard focus (a TextField is being edited) it becomes the key window;
        // treat that as "inside" so the mouse drifting off the panel mid-type can't collapse it and eat
        // the input. becomesKeyOnlyIfNeeded means it's only key while a field is actually active.
        let editing = expandedPanel?.isKeyWindow ?? false
        if inLight || inPanel || editing {
            outsideSince = nil
            if !expanded {
                if insideSince == nil { insideSince = Date() }
                else if Date().timeIntervalSince(insideSince!) >= expandDelay { showExpanded() }
            }
        } else {
            insideSince = nil
            if expanded {
                if outsideSince == nil { outsideSince = Date() }
                else if Date().timeIntervalSince(outsideSince!) >= collapseGrace { hideExpanded() }
            }
        }
    }

    /// Lazily build the management panel once and reuse it (its SwiftUI content observes the engine, so
    /// it stays live across show/hide — and remembers whether Настройки was open).
    private func ensureExpandedPanel() -> NSPanel {
        if let p = expandedPanel { return p }
        let root = FloatingPanelView(
            engine: engine, settings: settings,
            onJump: { [weak self] s in DeepLinker.focus(s); self?.hideExpanded() },
            onHistory: { HistoryWindowController.shared.show() },
            onRefresh: { [weak self] in self?.engine.forceRefresh() },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
        // ManagementPanel (not a bare NSPanel): a borderless panel's `canBecomeKey` is false by default,
        // so its TextField (the trusted-command "Add" field) could never take keyboard focus — you could
        // open the tool dropdown but not type. As a `.nonactivatingPanel` it can become key WITHOUT
        // activating the app; `becomesKeyOnlyIfNeeded` (set in configure) then hands focus to the field
        // only when clicked, leaving plain hover non-stealing.
        let panel = ManagementPanel(contentRect: NSRect(x: 0, y: 0, width: DS.Geo.panelWidth, height: 420),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        configure(panel)
        host(root, in: panel)
        expandedPanel = panel
        return panel
    }

    private func showExpanded() {
        guard !expanded, let light = lightPanel else { return }
        let panel = ensureExpandedPanel()
        expanded = true
        expandedSince = Date()
        positionExpandedPanel()
        // orderFrontRegardless like the light itself (which has never gone ghost), THEN slot just
        // above it. A bare order(.above, relativeTo:) is what kept "showing" the dead server-side
        // window without resurrecting it.
        panel.orderFrontRegardless()
        panel.order(.above, relativeTo: light.windowNumber)
        updateLightOpacity()
        Log.watcher.debug("hover expand")
    }

    /// Tear down and recreate the management panel. The nuclear option for a ghost window — the
    /// WindowServer-side window is dead (never occlusion-visible) while `isVisible` still reads true;
    /// no ordering call revives it, only a fresh window does (that's why relaunching cured it). The
    /// SwiftUI content rebuilds against the same observed engine/settings.
    private func rebuildExpandedPanel() {
        let old = expandedPanel
        expandedPanel = nil
        expanded = false
        old?.orderOut(nil)
        old?.contentViewController = nil
        guard let light = lightPanel else { return }
        let panel = ensureExpandedPanel()
        expanded = true
        expandedSince = Date()
        positionExpandedPanel()
        panel.orderFrontRegardless()
        panel.order(.above, relativeTo: light.windowNumber)
        Log.watcher.warn("hover panel rebuilt (ghost window: isVisible without occlusion .visible)")
    }

    /// Force-open the management panel regardless of ribbon/hover state. `hoverTick()`'s `hasRibbon`
    /// guard deliberately yields the light to the permission ribbon (see its doc comment) — which also
    /// means hover can't open the panel AT ALL while a request is pending, with no other way in. This
    /// is the escape hatch: wired to the always-available menu-bar dropdown item (`CcemaphoreApp`, not
    /// gated by the ribbon), so Настройки/История/Обновить/Выход stay reachable even when red.
    /// `forcedOpen` tells `hoverTick()` to skip its ribbon auto-collapse for THIS open — normal
    /// mouse-leaves-the-panel collapse still applies, and any panel action (or the ribbon getting a NEW
    /// event) that calls `hideExpanded()` clears the flag.
    func forceShowExpanded() {
        guard lightPanel != nil, settings.visible else { return }
        forcedOpen = true
        if !expanded { showExpanded() }
    }

    /// Left-click on the menu-bar status item (`StatusItemController`) — open the panel and PIN it open
    /// (no hover-based auto-collapse at all, see the `pinnedOpen` guard at the top of `hoverTick()`), or
    /// if it's already pinned, unpin and close it. This is the "stays open until clicked again" behavior
    /// requested for the menu-bar icon, distinct from `forceShowExpanded`'s one-shot escape hatch.
    func togglePinnedPanel() {
        guard lightPanel != nil, settings.visible else { return }
        if pinnedOpen {
            hideExpanded()
        } else {
            pinnedOpen = true
            if !expanded { showExpanded() }
        }
    }

    /// Hide the management panel (hover left, or a panel action asked to close). Public alias for the
    /// panel's own ▾ button. Never re-enters `applyWindowState` (that recursed in v1).
    func hideExpanded() {
        let wasExpanded = expanded
        expanded = false
        expandedSince = nil
        insideSince = nil
        outsideSince = nil
        forcedOpen = false
        pinnedOpen = false
        expandedPanel?.orderOut(nil)
        updateLightOpacity()
        if wasExpanded { Log.watcher.debug("hover collapse") }
    }

    /// Place the panel beside the light, toward the free side of the screen, clamped on-screen.
    private func positionExpandedPanel() {
        guard let light = lightPanel, let panel = expandedPanel,
              let screen = light.screen ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        let lf = light.frame
        let pf = panel.frame
        let gap: CGFloat = 8
        let onLeftHalf = lf.midX < vis.midX
        var x = onLeftHalf ? lf.maxX + gap : lf.minX - pf.width - gap
        x = min(max(vis.minX + 8, x), vis.maxX - pf.width - 8)
        var y = lf.maxY - pf.height
        y = min(max(vis.minY + 8, y), vis.maxY - pf.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.invalidateShadow()   // refresh the native rounded shadow (content/size may have changed)
    }

    // MARK: - Position memory (per display)

    private func displayID(_ screen: NSScreen) -> String {
        let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return n.map { "\($0.uint32Value)" } ?? "main"
    }

    private func restorePosition(_ panel: NSPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        if let saved = settings.position(forDisplay: displayID(screen)) {
            adjustingFrame = true
            panel.setFrameOrigin(clamp(origin: saved, size: panel.frame.size, into: screen.visibleFrame))
            adjustingFrame = false
        } else {
            let vis = screen.visibleFrame
            adjustingFrame = true
            panel.setFrameOrigin(NSPoint(x: vis.maxX - panel.frame.width - 24, y: vis.maxY - panel.frame.height - 24))
            adjustingFrame = false
        }
        captureAnchors(panel)
    }

    /// Snapshot the tower's anchor edges (vertical centre + both horizontal edges) from the current
    /// frame. Whichever edge the tower is docked to equals the window edge (the tower is always at the
    /// docked end + vertically centred), so these stay correct regardless of the ribbon's width.
    private func captureAnchors(_ panel: NSPanel) {
        savedCenterY = panel.frame.midY
        savedRight = panel.frame.maxX
        savedLeft = panel.frame.minX
    }

    private func clamp(origin: CGPoint, size: CGSize, into vis: CGRect) -> CGPoint {
        CGPoint(x: min(max(vis.minX + 6, origin.x), vis.maxX - size.width - 6),
                y: min(max(vis.minY + 6, origin.y), vis.maxY - size.height - 6))
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard !adjustingFrame, let panel = lightPanel, panel === notification.object as? NSWindow,
              let screen = panel.screen else { return }
        settings.setPosition(panel.frame.origin, forDisplay: displayID(screen))
        captureAnchors(panel)
        if expanded { positionExpandedPanel() }
    }

    func windowDidResize(_ notification: Notification) {
        // The content resizes when the ribbon appears/disappears or the size preset (S/M/L) changes.
        // Re-pin so the tower stays put: keep the vertical CENTRE (ribbon grows from the light's middle)
        // and the tower's docked horizontal edge — docked right → grow left, docked left → grow right —
        // then clamp on-screen. Anchors come from the last move (not updated here), so toggling the
        // ribbon returns to the exact same spot.
        guard !adjustingFrame, let panel = lightPanel, panel === notification.object as? NSWindow,
              let screen = panel.screen else { return }
        let vis = screen.visibleFrame
        let f = panel.frame
        let towerOnRight = f.midX >= vis.midX
        var origin = f.origin
        origin.y = (savedCenterY ?? f.midY) - f.height / 2
        if towerOnRight {
            if let r = savedRight { origin.x = r - f.width }
        } else {
            if let l = savedLeft { origin.x = l }
        }
        let clamped = clamp(origin: origin, size: f.size, into: vis)
        if clamped != f.origin {
            adjustingFrame = true
            panel.setFrameOrigin(clamped)
            adjustingFrame = false
        }
        panel.invalidateShadow()   // window resized (ribbon toggled / size preset) → refresh native shadow
        if expanded { positionExpandedPanel() }
    }
}

// MARK: - Light panel subclass

/// Borderless non-activating panel that can still become key when a control genuinely needs it. A plain
/// (left) click on the light is intentionally inert (the management panel opens on HOVER, not click);
/// a RIGHT-click force-opens the management panel — the same escape hatch as the menu-bar "Открыть
/// панель" item, just reachable at the light itself instead of only from the menu bar.
final class LightPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func rightMouseDown(with event: NSEvent) {
        FloatingWidgetController.shared.forceShowExpanded()
    }
}

/// The hover management panel. Borderless panels default `canBecomeKey` to false, which starves the
/// trusted-command "Add" TextField of keyboard focus; overriding it (paired with `.nonactivatingPanel`)
/// lets the field take input on click without activating the app.
final class ManagementPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - SwiftUI root for the light window

/// The reactive content of the light panel: the ribbon while any request/attention item is present,
/// otherwise the bare tower. Decision items carry Allow/Deny/All; attention items (native prompts /
/// questions) carry "Перейти в чат". Tapping an item's upper area also jumps to the chat. Observes the
/// engine + settings so it re-renders itself.
struct LightRootView: View {
    @ObservedObject var engine: StateEngine
    @ObservedObject var settings: WidgetSettings

    @State private var ribbonIndex = 0

    /// LIVE broker requests (actionable) — the red decision items.
    private var decisionItems: [RibbonItem] {
        engine.pendingRequests.map { req in
            let h = engine.hostInfo(for: req.sessionId)
            let session = engine.sessions.first { $0.id == req.sessionId }
            return RibbonItem(id: req.requestId,
                       kind: .decision(requestId: req.requestId),
                       sessionId: req.sessionId,
                       cwd: req.cwd,
                       project: (req.cwd as NSString).lastPathComponent,
                       branch: session?.gitBranch ?? "",
                       command: req.detail ?? req.summary,
                       chatTitle: session?.title,
                       host: h.host, hostBundleId: h.bundleId,
                       remoteHostLabel: req.remoteHostId.flatMap { RemoteHosts.resolve($0)?.label },
                       remoteHostId: req.remoteHostId)
        }
    }
    /// Chats parked on a native prompt / question the user answers in Cursor — the red attention items.
    private var attentionItems: [RibbonItem] {
        engine.attentionSessions.map { a in
            let h = engine.hostInfo(for: a.id)
            let session = engine.sessions.first { $0.id == a.id }
            return RibbonItem(id: a.id, kind: .attention(a.kind), sessionId: a.id, cwd: a.cwd,
                       project: a.project, branch: a.branch, command: nil,
                       chatTitle: session?.title,
                       host: h.host, hostBundleId: h.bundleId,
                       remoteHostLabel: session?.remoteHostId.flatMap { RemoteHosts.resolve($0)?.label },
                       remoteHostId: session?.remoteHostId)
        }
    }
    /// Transient GREEN "chat finished" notices.
    private var completionItems: [RibbonItem] {
        engine.completionNotices.map { n in
            let h = engine.hostInfo(for: n.id)
            return RibbonItem(id: "done-\(n.id)", kind: .completed, sessionId: n.id, cwd: n.cwd,
                       project: n.project, branch: n.branch, command: nil,
                       chatTitle: engine.sessions.first { $0.id == n.id }?.title,
                       host: h.host, hostBundleId: h.bundleId)
        }
    }
    /// Red (act-now) items — a live decision or a native-prompt attention. These ALONE pulse the tower;
    /// a completion notice is calm (green) and must not animate it.
    private var urgentItems: [RibbonItem] { decisionItems + attentionItems }
    /// Everything the ribbon shows: urgent items first, then the transient completions. Empty → bare tower.
    private var ribbonItems: [RibbonItem] { urgentItems + completionItems }

    /// The tower ONLY animates (pulses) while a red request/attention item is on screen — driven here.
    private var light: LightInput {
        LightInput(red: engine.waitingCount, yellow: engine.workingCount, green: engine.doneCount,
                   detail: settings.displayMode == .summary, urgent: !urgentItems.isEmpty,
                   compacting: engine.compactingCount > 0)
    }

    /// Anchor the ribbon body toward the free side: tower docked right → body grows left (.right), and
    /// vice-versa. Single source of truth shared with `windowDidResize`, so the SwiftUI side and the
    /// window-pinning side can never disagree about which way to grow.
    private var anchor: RibbonAnchor {
        FloatingWidgetController.shared.ribbonExtendsLeftward ? .right : .left
    }

    var body: some View {
        Group {
            if ribbonItems.isEmpty {
                LightTowerView(input: light, scale: settings.size.scale)
            } else {
                PermissionRibbonView(
                    items: ribbonItems,
                    index: clampedIndexBinding,
                    anchor: anchor,
                    light: light,
                    scale: settings.size.scale,
                    onAllow: { decide($0, .allowOnce) },
                    onDeny: { decide($0, .deny) },
                    onAll: { decide($0, .allowAll) },
                    onOpenChat: { openChat($0) }
                )
            }
        }
        .fixedSize()
        // Breathing room so lamp glows fade out instead of being hard-clipped at the (fit-to-content)
        // window edge — the left/right "dashes". Must scale with the widget size, since the glows do.
        .padding(LightTowerView.glowMargin(scale: settings.size.scale))
    }

    private var clampedIndexBinding: Binding<Int> {
        Binding(
            get: { min(ribbonIndex, max(0, ribbonItems.count - 1)) },
            set: { ribbonIndex = $0 }
        )
    }

    private func decide(_ r: RibbonItem, _ decision: PermissionBroker.Decision) {
        guard let req = engine.pendingRequests.first(where: { $0.requestId == r.id }) else { return }
        engine.decidePermission(req, decision)
    }

    /// Jump to the chat (attention button + tap on an item's upper area). We DON'T resolve a live
    /// decision here: the user answers in Cursor's own dialog, and the broker's external-resolution
    /// detection then drops the request — so the ribbon stays truthful (red) until it's actually answered.
    private func openChat(_ r: RibbonItem) {
        DeepLinker.focus(sessionId: r.sessionId, cwd: r.cwd, host: r.host, hostBundleId: r.hostBundleId,
                         remoteHostId: r.remoteHostId)
        // A completion notice is informational; jumping to it clears it (it also auto-expires).
        if r.isCompleted { engine.dismissCompletion(r.sessionId) }
    }
}

extension FloatingWidgetController {
    /// Read-only access to the light window's frame for the ribbon's anchor computation.
    var lightFrame: CGRect? { lightPanel?.frame }

    /// True when the ribbon body should extend LEFT — i.e. the tower sits on the right side of its
    /// screen, so the body grows into the free space toward the centre. Uses the same screen +
    /// midX criterion as `windowDidResize`, keeping the view and the window pinning in agreement.
    var ribbonExtendsLeftward: Bool {
        guard let panel = lightPanel, let screen = panel.screen ?? NSScreen.main else { return true }
        return panel.frame.midX >= screen.visibleFrame.midX
    }
}
