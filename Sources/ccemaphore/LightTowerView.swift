import SwiftUI

/// Input describing what the tower should show. Pure value type so the view is trivially previewable
/// and the controller can rebuild it from `StateEngine` each render.
struct LightInput: Equatable {
    var red: Int       // waiting chats
    var yellow: Int    // working chats
    var green: Int     // done chats
    var detail: Bool   // true = "summary with counts" (§3.2 A); false = "single color" (§3.2 B)
    /// Attention state: a permission/question ribbon is on screen for a RED light right now. This — and
    /// ONLY this — animates the tower (housing pulse + lamp glow-pulse + urgency ring). Any other state
    /// (idle, plain working/done, even a red with no ribbon shown) renders statically. So the pulse is a
    /// meaningful "act now" cue that stops the instant the ribbon clears — never ambient, never stuck.
    var urgent: Bool = false
    /// A working chat is compacting its context right now → show the compress chip on the YELLOW lamp.
    /// The lamp stays yellow (compacting is a `working` sub-state); the chip is a "quiet signal" that says
    /// "busy because it's compacting", not stuck. Static: it must NOT animate (motion is reserved for an
    /// on-screen urgent-red request, see `urgent`).
    var compacting: Bool = false

    /// Precedence color across the active lamps (§4): red > yellow > green > gray.
    var dominant: AggregateColor {
        if red > 0 { return .red }
        if yellow > 0 { return .yellow }
        if green > 0 { return .green }
        return .gray
    }
    /// Count of chats in the dominant status (used by single-color mode's badge).
    var dominantCount: Int {
        switch dominant {
        case .red: red
        case .yellow: yellow
        case .green: green
        case .gray: 0
        }
    }

    static let idle = LightInput(red: 0, yellow: 0, green: 0, detail: true)
}

/// The collapsed "огонёк": a 3-lamp traffic-light tower (§3). The dominant lamp is full-color, glows
/// and "breathes"; others are dimmed; empty statuses are dark sockets. Visual reference:
/// `docs/redesign-floating-window/Light.dc.html` (exact geometry, glows, animation curves).
struct LightTowerView: View {
    let input: LightInput
    /// Size factor from `WidgetSettings.WidgetSize.scale` (0.75 / 0.87 / 1.0 / 1.45 / 1.9).
    var scale: CGFloat = 1
    /// Lamp layout: stacked (default) or a horizontal row (§8's orientation setting).
    var orientation: WidgetSettings.Orientation = .vertical

    /// Transparent breathing room the *window* must leave around the housing so the lamp glows fade out
    /// instead of being hard-clipped at the panel edge. SwiftUI `.frame`/`.padding` don't clip content —
    /// the fit-to-content `NSPanel`/`NSHostingView` edge does — so a too-tight window sliced each lit
    /// lamp's soft `.shadow` at its vertical centre, leaving the left/right "dashes". Sized to the widest
    /// steady glow (dominant outer halo, 11·scale) plus its soft tail so even at size L nothing is cut;
    /// the urgent-red pulse peaks larger but is transient and only its faint outer tail can graze the edge.
    static func glowMargin(scale: CGFloat) -> CGFloat { 16 * scale }

    // MARK: Animation drivers
    // Each is a bool toggled in `.onAppear` inside the matching `withAnimation`, so the repeating
    // curve interpolates between the two endpoint states. Gated on `input.urgent` so a non-urgent tower
    // never moves and never burns a render loop. The modifier VALUES below also read `input.urgent`, so
    // the visual snaps to rest the instant urgency ends — even if a repeatForever driver lingers.

    /// Housing urgent scale.
    @State private var pulse = false
    /// Dominant lamp's glow pulse (radius + alpha).
    @State private var glow = false
    /// Red-only expanding ring (scale 1→2.3, opacity .65→0).
    @State private var ring = false

    var body: some View {
        let g = Geo(detail: input.detail, scale: scale, orientation: orientation)

        return housing(g)
            .scaleEffect(input.urgent ? breatheScale : 1, anchor: .center)
            .onAppear(perform: startAnimations)
            // Re-arm when urgency toggles (start/stop the loops) or the dominant changes the curve.
            .onChange(of: input.urgent) { _ in startAnimations() }
            .onChange(of: input.dominant) { _ in startAnimations() }
    }

    // MARK: - Housing

    private func housing(_ g: Geo) -> some View {
        Group {
            if orientation == .vertical {
                VStack(spacing: g.gap) {
                    slot(.red, g: g)
                    slot(.yellow, g: g)
                    slot(.green, g: g)
                }
            } else {
                HStack(spacing: g.gap) {
                    slot(.red, g: g)
                    slot(.yellow, g: g)
                    slot(.green, g: g)
                }
            }
        }
        // padX is tuned as the flanking padding on the SHORT axis (a single lamp's width in vertical
        // mode), padY on the LONG axis (the 3-lamp stack) — swap which physical side each lands on
        // so the padding still matches `housingW`/`housingH` once the axes themselves are swapped.
        .padding(.horizontal, orientation == .vertical ? g.padX : g.padY)
        .padding(.vertical, orientation == .vertical ? g.padY : g.padX)
        .frame(width: g.housingW, height: g.housingH)
        .background(
            // Real behind-window blur (NSVisualEffectView) + a translucent tint, both clipped to the
            // housing shape. SwiftUI's own materials only blur within the window, so over a clear
            // floating panel they read as flat grey; this frosts the desktop behind the housing.
            RoundedRectangle(cornerRadius: g.radius, style: .continuous)
                .fill(DS.towerBG)
                .background(VisualEffectBlur(material: .popover, cornerRadius: g.radius))
                .overlay(
                    // Top inner highlight: the "inset 0 1px 0 white .1" lip from §2.4 that makes the
                    // housing read as a physical surface catching light.
                    RoundedRectangle(cornerRadius: g.radius, style: .continuous)
                        .strokeBorder(DS.towerBorder, lineWidth: 1)
                )
                // Housing depth, drawn in SwiftUI on the frosted shape ITSELF (not the OS window shadow,
                // which traced the whole padded window's alpha — incl. the soft lamp glows — into a dark
                // halo). It sits well inside `glowMargin`, so the fit-to-content window edge never clips
                // it into the old hard-cornered rectangle.
                .shadow(color: .black.opacity(0.30), radius: 8 * scale, y: 2.5 * scale)
        )
        // Single-mode count badge sits at the housing's top-right corner (§3.2 B).
        .overlay(alignment: .topTrailing) {
            if showBadge {
                badge(g)
                    .offset(x: 8 * scale, y: -5 * scale)
            }
        }
    }

    // MARK: - One lamp slot

    /// A lamp + its in-lamp count (summary), plus the red ring underlay and the compacting chip on the
    /// yellow lamp when applicable.
    @ViewBuilder
    private func slot(_ c: AggregateColor, g: Geo) -> some View {
        let state = lampState(c)
        ZStack {
            // Expanding urgency ring behind the red lamp only (§3.3). Drawn first so it sits under the bulb.
            if c == .red && wantsRing {
                Circle()
                    .stroke(DS.red, lineWidth: max(1, 1.4 * scale))
                    .frame(width: g.lamp, height: g.lamp)
                    .scaleEffect(ring ? 2.3 : 1)
                    .opacity(ring ? 0 : 0.65)
            }

            lamp(c, state: state, g: g)

            // In-lamp count (summary mode, active lamp only).
            if input.detail, count(c) > 0 {
                Text(String(count(c)))
                    .font(.system(size: numberSize(count(c)), weight: .bold, design: .monospaced))
                    .tracking(-0.03 * numberSize(count(c)))   // ≈ -0.03em
                    .foregroundStyle(c == .yellow ? Color(hex: 0x1A1500) : .white)
            }
        }
        .frame(width: g.lamp, height: g.lamp)
        // Quiet-signal chip rides the yellow lamp's top-right corner: the compress glyph when a working
        // chat is compacting. (A pending permission takes the whole light over with the ribbon instead,
        // so there's no on-tower chip for it.)
        .overlay(alignment: .topTrailing) {
            if c == .yellow && input.compacting && state != .off {
                compactChip(g)
                    .offset(x: 7 * scale, y: -7 * scale)
            }
        }
    }

    /// The bulb itself: socket / dim / dominant, with the matching glow + inner highlight.
    @ViewBuilder
    private func lamp(_ c: AggregateColor, state: LampState, g: Geo) -> some View {
        switch state {
        case .off:
            // Dark inset socket — no light at all.
            Circle()
                .fill(DS.lampOff)
                .overlay(Circle().strokeBorder(.white.opacity(0.05), lineWidth: 1))
                .frame(width: g.lamp, height: g.lamp)

        case .dim:
            // Active but non-dominant: ~50% color, weak static glow, faint inner highlight.
            Circle()
                .fill(dimFill(c))
                .overlay(innerHighlight(alpha: 0.22))
                .frame(width: g.lamp, height: g.lamp)
                .shadow(color: DS.glow(c, 0.3), radius: 5 * scale)

        case .dominant:
            // Full color + the layered glow from §2.4, whose radius/alpha pulse via `glow` — but only
            // while urgent; otherwise the lamp is lit with a steady (non-pulsing) glow.
            let pulsing = input.urgent && c != .gray
            Circle()
                .fill(DS.status(c))
                .overlay(innerHighlight(alpha: pulsing && glow ? 0.6 : 0.42))
                .frame(width: g.lamp, height: g.lamp)
                // Outer soft halo (the "0 0 11px 2px glow .5" → "0 0 20px glow .85" pulse).
                .shadow(color: DS.glow(c, pulsing && glow ? domGlowOuterMaxAlpha(c) : 0.5),
                        radius: (pulsing && glow ? domGlowOuterMaxRadius(c) : 11) * scale)
                // Tight bright core ("0 0 3px glow .9").
                .shadow(color: DS.glow(c, 0.9), radius: 3 * scale)
        }
    }

    // MARK: - Badges

    /// Single-mode count badge (rounded pill) at the housing corner.
    private func badge(_ g: Geo) -> some View {
        let c = input.dominant
        return Text(String(input.dominantCount))
            .font(.system(size: 10 * scale, weight: .bold, design: .monospaced))
            .tracking(-0.02 * 10 * scale)
            .foregroundStyle(c == .yellow ? Color(hex: 0x1A1500) : .white)
            .padding(.horizontal, 4 * scale)
            .frame(minWidth: 16 * scale, minHeight: 16 * scale)
            .background(
                Capsule().fill(DS.status(c))
                    // Glow + a ring punching it out of whatever's behind (the housing/desktop).
                    .overlay(Capsule().strokeBorder(badgeRing, lineWidth: max(1, 1.5 * scale)))
            )
            .shadow(color: DS.glow(c, 0.55), radius: 5 * scale, y: scale)
    }

    /// The compacting "quiet signal" chip — a dark disc with a monochrome compress SF Symbol (reads as
    /// "shrinking the context", cleaner than gmr's broom). Static — motion is reserved for urgent red.
    private func compactChip(_ g: Geo) -> some View {
        let d = 14 * scale
        return Image(systemName: "rectangle.compress.vertical")
            .font(.system(size: 7 * scale, weight: .bold))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: d, height: d)
            .background(Circle().fill(Color(hex: 0x121214).opacity(0.95)))
            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    // MARK: - Lit-bulb inner highlight

    /// A white radial sheen biased to the top-left, clipped to the bulb — the "inset white" of the
    /// box-shadow recipe, which sells the lamp as a glowing dome rather than a flat disc.
    private func innerHighlight(alpha: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [.white.opacity(alpha), .clear],
                    center: UnitPoint(x: 0.35, y: 0.3),
                    startRadius: 0,
                    endRadius: 9 * scale
                )
            )
    }

    // MARK: - Animation control

    private func startAnimations() {
        // Reset to the base endpoint so a re-arm always starts from a known state. When not urgent we
        // stop here: no loops armed, and the urgent-gated modifier values above already sit at rest.
        pulse = false; glow = false; ring = false
        guard input.urgent else { return }   // ONLY an on-screen red request animates the tower

        // Housing urgent pulse.
        if let curve = breatheCurve {
            withAnimation(curve) { pulse = true }
        }
        // Dominant lamp glow pulse (the dominant is red whenever urgent).
        if input.dominant != .gray {
            withAnimation(DS.glowPulse) { glow = true }
        }
        // Red urgency ring.
        if wantsRing {
            withAnimation(DS.ring) { ring = true }
        }
    }

    /// Whole-housing scale endpoint while `pulse` is on (urgent ⇒ dominant red): 1.075, else 1.
    private var breatheScale: CGFloat {
        guard input.urgent, input.dominant != .gray, pulse else { return 1 }
        return input.dominant == .red ? 1.075 : 1.045
    }

    private var breatheCurve: Animation? {
        switch input.dominant {
        case .red:  DS.urgent
        case .gray: nil
        default:    DS.breathe
        }
    }

    /// Ring shows only for an urgent, dominant-red tower (§3.3).
    private var wantsRing: Bool { input.urgent && input.dominant == .red }

    // MARK: - Per-lamp state

    private enum LampState { case off, dim, dominant }

    private func lampState(_ c: AggregateColor) -> LampState {
        if input.detail {
            // Summary: every status with a count lights; the dominant one is full color.
            if c == input.dominant && input.dominantCount > 0 { return .dominant }
            return count(c) > 0 ? .dim : .off
        } else {
            // Single: only the dominant lamp is lit, the rest are dark sockets.
            return c == input.dominant && input.dominant != .gray ? .dominant : .off
        }
    }

    // MARK: - Color / count helpers

    private func count(_ c: AggregateColor) -> Int {
        switch c {
        case .red: input.red
        case .yellow: input.yellow
        case .green: input.green
        case .gray: 0
        }
    }

    /// Dimmed (non-dominant active) fill — ~50% saturation per the mockup's `dimC`.
    private func dimFill(_ c: AggregateColor) -> Color {
        switch c {
        case .red:    DS.red.opacity(0.46)
        case .yellow: DS.yellow.opacity(0.5)
        case .green:  DS.green.opacity(0.46)
        case .gray:   DS.lampOff
        }
    }

    private func numberSize(_ n: Int) -> CGFloat { (n >= 10 ? 8 : 9.5) * scale }

    private var showBadge: Bool { !input.detail && input.dominantCount > 1 }

    /// Ring around the single-mode badge — a near-opaque surface color so the badge reads as floating
    /// above the housing/desktop regardless of theme.
    private var badgeRing: Color { Color(hex: 0x121214).opacity(0.95) }

    // Per-color glow-pulse maxima (the keyframe `50%` values differ per hue in the mockup).
    private func domGlowOuterMaxRadius(_ c: AggregateColor) -> CGFloat {
        switch c {
        case .red:    20
        case .yellow: 16
        case .green:  14
        case .gray:   11
        }
    }
    private func domGlowOuterMaxAlpha(_ c: AggregateColor) -> Double {
        switch c {
        case .red:    0.85
        case .yellow: 0.7
        case .green:  0.6
        case .gray:   0.5
        }
    }

    // MARK: - Resolved geometry

    /// All sizes for one render, pre-multiplied by `scale`, mirroring `renderVals()` in Light.dc.html.
    private struct Geo {
        let lamp, padX, padY, gap, housingW, housingH, radius: CGFloat
        init(detail: Bool, scale: CGFloat, orientation: WidgetSettings.Orientation = .vertical) {
            lamp = (detail ? DS.Geo.lampSummary : DS.Geo.lampSingle) * scale
            padX = (detail ? DS.Geo.housingPadX : 7) * scale
            padY = DS.Geo.housingPadY * scale
            gap  = DS.Geo.lampGap * scale
            let short = lamp + padX * 2      // one lamp + the padding on its two flanking sides
            let long  = lamp * 3 + gap * 2 + padY * 2   // three lamps + gaps + padding along the stack
            if orientation == .vertical {
                housingW = short
                housingH = long
            } else {
                housingW = long
                housingH = short
            }
            // HTML: radius = round((detail?0.4:0.46) * W / size) — the `/size` cancels W's scale, so
            // the effective radius is (factor * unscaled-short-axis) * scale. Derived off `min(W, H)`
            // (rather than hardcoding W) so it stays correct in both orientations.
            radius = (detail ? 0.4 : 0.46) * min(housingW, housingH)
        }
    }
}
