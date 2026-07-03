import SwiftUI
import AppKit

/// Design tokens for the floating-widget redesign — the single source for the spec's colors,
/// surfaces, shadows, type and animation timings (§2 of `docs/redesign-floating-window/
/// ccemaphore-design-spec.md`). Status colors are the ONLY saturated hues in the product; every
/// other surface/button is neutral graphite so nothing competes with the light.
///
/// Light/dark is automatic: theme-dependent tokens are dynamic `Color`s (an `NSColor` provider that
/// resolves per appearance), so a single token renders correctly in both themes without threading
/// `colorScheme` through every view.
enum DS {

    // MARK: - Status colors (§2.1) — identical in both themes

    static let red    = Color(hex: 0xFF453A)   // waiting
    static let yellow = Color(hex: 0xFFD60A)   // working
    static let green  = Color(hex: 0x30D158)   // done
    static let gray   = Color(hex: 0x8E8E93)   // idle

    /// Status hue for a per-session state (drives lamps, row dots).
    static func status(_ s: SessionState) -> Color {
        switch s {
        case .working: yellow
        case .waiting: red
        case .done:    green
        case .stale:   gray
        }
    }

    /// Status hue for the aggregate (the dominant lamp / header dot).
    static func status(_ c: AggregateColor) -> Color {
        switch c {
        case .yellow: yellow
        case .red:    red
        case .green:  green
        case .gray:   gray
        }
    }

    /// Glow color (same RGB as the status, variable alpha) for lamp box-shadows / dot halos.
    static func glow(_ c: AggregateColor, _ alpha: Double) -> Color { status(c).opacity(alpha) }
    static func glow(_ s: SessionState, _ alpha: Double) -> Color { status(s).opacity(alpha) }

    // MARK: - Accent-free semantic text (§2.2/2.3) — dynamic

    /// "Требуется разрешение" / "Запретить" labels (red, theme-tuned: brighter on dark, deeper on light).
    static let redText = dynamic(dark: Color(hex: 0xFF6961), light: Color(hex: 0xD7372B))
    /// Context bar amber for the 65–79% band (≥80% uses `redText`).
    static let ctxWarning = Color(hex: 0xFFB340)

    static let textPrimary   = dynamic(dark: .white.opacity(0.93), light: .black.opacity(0.90))
    static let textSecondary = dynamic(dark: .white.opacity(0.56), light: .black.opacity(0.55))
    static let textTertiary  = dynamic(dark: .white.opacity(0.40), light: .black.opacity(0.42))

    // MARK: - Surfaces (§2.2/2.3) — dynamic

    /// Tower housing — lighter, more translucent than the panels (it floats bare on the desktop).
    static let towerBG     = dynamic(dark: Color(hex: 0x1A1A1D, alpha: 0.74), light: Color(hex: 0xF8F8FA, alpha: 0.82))
    static let towerBorder = dynamic(dark: .white.opacity(0.10), light: .black.opacity(0.07))
    /// Ribbon + panel share a denser surface (they carry text that must stay readable).
    static let panelBG     = dynamic(dark: Color(hex: 0x141417, alpha: 0.96), light: Color(hex: 0xF4F4F7, alpha: 0.95))
    static let panelBorder = dynamic(dark: .white.opacity(0.11), light: .black.opacity(0.09))

    static let line        = dynamic(dark: .white.opacity(0.10), light: .black.opacity(0.09))
    static let hoverRow    = dynamic(dark: .white.opacity(0.06), light: .black.opacity(0.05))
    static let codeBG      = dynamic(dark: .black.opacity(0.34), light: .black.opacity(0.06))
    static let codeText    = dynamic(dark: .white.opacity(0.86), light: .black.opacity(0.80))
    /// Neutral (graphite) button — "Всё в чате", footer, etc.
    static let neutralBtn      = dynamic(dark: .white.opacity(0.08), light: .black.opacity(0.06))
    static let neutralBtnHover = dynamic(dark: .white.opacity(0.14), light: .black.opacity(0.11))
    /// Primary button (white on dark / near-black on light) with its text.
    static let primaryFill = dynamic(dark: .white.opacity(0.92), light: Color(hex: 0x1C1C1E))
    static let primaryText = dynamic(dark: Color(hex: 0x15151A), light: .white)
    static let denyHover   = dynamic(dark: Color(hex: 0xFF453A, alpha: 0.14), light: Color(hex: 0xFF3B30, alpha: 0.10))

    /// Inset/empty lamp fill (a dark socket) — the unlit lamp in the tower.
    static let lampOff       = dynamic(dark: .white.opacity(0.045), light: .black.opacity(0.06))

    // MARK: - Context-percent tint (§7) — shared by the panel rows

    static func contextTint(_ pct: Double) -> Color {
        if pct >= 80 { return redText }
        if pct >= 65 { return ctxWarning }
        return textSecondary
    }

    // MARK: - Animation timings (§2.7)

    static let breathe   = Animation.easeInOut(duration: 3.4).repeatForever(autoreverses: true)
    static let urgent    = Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)
    static let glowPulse = Animation.easeInOut(duration: 2.6).repeatForever(autoreverses: true)
    static let ring      = Animation.easeOut(duration: 1.6).repeatForever(autoreverses: false)
    static let ribbonExpand = Animation.timingCurve(0.2, 0.82, 0.25, 1, duration: 0.34)
    static let panelPop     = Animation.timingCurve(0.2, 0.85, 0.35, 1.1, duration: 0.22)

    // MARK: - Geometry at size = M (§2.6). Scale by the widget size factor (0.75 / 1.0 / 1.45).

    enum Geo {
        static let lampSummary: CGFloat = 17   // lamp ⌀ in "summary with counts" mode
        static let lampSingle:  CGFloat = 13   // lamp ⌀ in "single color" mode
        static let housingPadX: CGFloat = 8
        static let housingPadY: CGFloat = 9
        static let lampGap:     CGFloat = 8
        static let housingRadius: CGFloat = 14
        static let ribbonWidth:  CGFloat = 300
        static let ribbonRadius: CGFloat = 15
        static let panelWidth:   CGFloat = 300
        static let panelRadius:  CGFloat = 16
        /// The ribbon body tucks under the tower by this much so the seam is hidden (§6.1).
        static let ribbonOverlap: CGFloat = 15
    }

    // MARK: - Builders

    /// A dynamic `Color` that resolves to `dark` under a dark appearance and `light` otherwise.
    static func dynamic(dark: Color, light: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}

/// A real behind-window vibrancy backing (frosted blur of the DESKTOP behind a clear floating panel).
/// SwiftUI's `.ultraThinMaterial` only blurs content WITHIN the window, so over a transparent panel it
/// reads as flat grey — this taps the same `NSVisualEffectView` the system uses for menus/popovers.
/// Use as a `.background(...)`; it rounds ITSELF (see below), so no outer `.clipShape` is needed for it.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    /// Corner radius of the frosted surface, matched to the SwiftUI `.continuous` shape drawn on top.
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> RoundedMaskEffectView {
        let v = RoundedMaskEffectView()
        v.material = material
        v.blendingMode = .behindWindow   // blur what's behind the window (the desktop), not within it
        v.state = .active                // stay active even when the app isn't frontmost
        v.radius = cornerRadius
        return v
    }

    func updateNSView(_ nsView: RoundedMaskEffectView, context: Context) {
        nsView.material = material
        nsView.radius = cornerRadius
    }
}

/// An `NSVisualEffectView` rounded via its **`maskImage`** — the only mechanism that reshapes the
/// *vibrancy itself* (and thus the window's native shadow) rather than just clipping the layer's
/// backing. `layer.cornerRadius + masksToBounds` does NOT reshape behind-window vibrancy for the
/// window-server composite, so it left a hard rectangular edge on the shadowed sides — a dark strip
/// under the light and banding along the panel's top. The mask is rendered from the SAME
/// `RoundedRectangle(style: .continuous)` the SwiftUI tint/border use, so the frost edge, the tint,
/// and the system shadow all trace one identical squircle contour.
final class RoundedMaskEffectView: NSVisualEffectView {
    var radius: CGFloat = 0 { didSet { if radius != oldValue { needsLayout = true } } }

    /// Cache so we only re-render the mask when size / radius / backing-scale actually change.
    private var maskedSize: NSSize = .zero
    private var maskedRadius: CGFloat = -1
    private var maskedScale: CGFloat = 0

    override func layout() {
        super.layout()
        refreshMask()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshMask()
    }

    private func refreshMask() {
        let scale = window?.backingScaleFactor ?? 2
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }
        if size == maskedSize, radius == maskedRadius, scale == maskedScale { return }
        maskedSize = size; maskedRadius = radius; maskedScale = scale
        maskImage = Self.roundedMask(size: size, radius: radius, scale: scale)
    }

    /// A black `.continuous` rounded rect at the view's exact size — opaque where the frost shows,
    /// transparent (clipped) outside. Rendered through `ImageRenderer` so the corner curve is
    /// byte-for-byte the SwiftUI squircle, never a plain circular arc.
    private static func roundedMask(size: NSSize, radius: CGFloat, scale: CGFloat) -> NSImage? {
        let r = min(radius, min(size.width, size.height) / 2)
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
            .fill(Color.black)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: shape)
        renderer.scale = scale
        return renderer.nsImage
    }
}

extension Color {
    /// 0xRRGGBB literal → `Color` (sRGB), with optional alpha.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}
