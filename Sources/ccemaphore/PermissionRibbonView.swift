import SwiftUI

/// One item shown in the ribbon. Three kinds:
///  - `.decision` — a LIVE permission request the broker hook is blocking on: actionable
///    Разрешить / Запретить / Всё-в-чате, plus a `$ …` command chip.
///  - `.attention` — INFORMATIONAL: a chat parked on Cursor's own native prompt (a permission handed off
///    after the wait window, or a question tool the user must answer in the chat). No allow/deny — the
///    hook is no longer listening — only "Перейти в чат". Built from `StateEngine.attentionSessions`.
///  - `.completed` — a transient GREEN "chat finished" notice (the in-widget replacement for the old
///    done toast). Just "Перейти в чат"; auto-expires. Built from `StateEngine.completionNotices`.
struct RibbonItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case decision(requestId: String)
        case attention(AttentionItem.Kind)
        case completed
    }
    let id: String        // requestId for decisions; sessionId (prefixed for completions) otherwise
    let kind: Kind
    let sessionId: String
    let cwd: String?
    let project: String
    let branch: String
    let command: String?  // the `$ …` chip — decisions only
    /// The chat's title (aiTitle/lastPrompt from the transcript) — shown as a one-line subtitle under
    /// the project so the user can tell WHICH chat in that project is asking. nil/empty → line hidden.
    var chatTitle: String? = nil
    /// Where the chat runs, so "перейти в чат" raises the right app (Cursor tab vs. terminal). Defaults
    /// keep older call sites compiling; the builders fill them from `StateEngine.hostInfo`.
    var host: SessionHost = .unknown
    var hostBundleId: String? = nil
    /// Non-nil ⇒ this item is for a session on a remote host (its `RemoteHost.label`) — shown as a small
    /// pill next to the project name so the user can tell a remote request apart from a local one.
    var remoteHostLabel: String? = nil
    /// The `RemoteHost.id` this item's session came from, if remote — lets `onOpenChat` route to
    /// `DeepLinker`'s remote (VS Code Remote-SSH deep-link) path instead of the local Cursor/terminal one.
    var remoteHostId: String? = nil

    var isDecision: Bool { if case .decision = kind { return true } else { return false } }
    var isCompleted: Bool { if case .completed = kind { return true } else { return false } }
}

/// Which way the ribbon body extends from the tower (§6.2): toward the free side of the screen. The
/// tower itself stays pinned to its edge; only the body grows.
enum RibbonAnchor { case left, right }

/// The permission ribbon (§6): the SAME tower with a body that slides out from under it, carrying the
/// project/branch/command and the actions. Multiple items live inside ONE ribbon with an `i из N`
/// navigator. Decision items show the three buttons; attention items show a single "Перейти в чат".
/// Visual reference: `docs/redesign-floating-window/PermWidget.dc.html`.
struct PermissionRibbonView: View {
    /// All items to show (decisions first, then attention). The view shows `items[index]` + the navigator.
    let items: [RibbonItem]
    @Binding var index: Int
    let anchor: RibbonAnchor
    /// The tower the ribbon docks to (red lamp shows the pending count).
    let light: LightInput
    var scale: CGFloat = 1
    /// Decisions for the currently-shown request.
    var onAllow: (RibbonItem) -> Void
    var onDeny: (RibbonItem) -> Void
    var onAll: (RibbonItem) -> Void
    /// Jump to the chat (attention button + tap on the item's upper area).
    var onOpenChat: (RibbonItem) -> Void

    private var current: RibbonItem? {
        guard !items.isEmpty else { return nil }
        return items[min(max(0, index), items.count - 1)]
    }

    /// How far the body's inner edge tucks under the tower so the seam is hidden (§6.1).
    private var overlap: CGFloat { DS.Geo.ribbonOverlap * scale }

    var body: some View {
        // The tower must render ON TOP of the overlap (higher z). We order body→tower (right) or
        // tower→body (left) in an HStack with a negative spacing so the body's inner edge slides
        // under the tower; `zIndex` keeps the tower painted last so the seam stays hidden.
        HStack(spacing: -overlap) {
            if anchor == .right {
                bodyIfPresent
                tower
            } else {
                tower
                bodyIfPresent
            }
        }
    }

    private var tower: some View {
        LightTowerView(input: light, scale: scale).zIndex(2)
    }

    @ViewBuilder private var bodyIfPresent: some View {
        if let r = current {
            ribbonBody(r)
                // Expand-from-the-tower feel when the parent toggles visibility (§2.7 ribbonExpand).
                .transition(.asymmetric(
                    insertion: .move(edge: anchor == .right ? .trailing : .leading)
                        .combined(with: .opacity),
                    removal: .opacity))
                .zIndex(1)
        }
    }

    // MARK: - Body

    private func ribbonBody(_ r: RibbonItem) -> some View {
        // Asymmetric inner padding: the side that tucks under the tower must clear the `overlap` first,
        // THEN add the same visible inset as the free side — otherwise the content crowds the tower
        // (only ~8pt of visible gap with the old flat 23). tuckPad = overlap + a comfortable inset.
        let freeInset:  CGFloat = 11
        let tuckInset:  CGFloat = 16   // slightly roomier than the free side so the tower doesn't crowd it
        let tuckPad = overlap + tuckInset
        let pad: EdgeInsets = anchor == .right
            ? EdgeInsets(top: 11, leading: freeInset, bottom: 11, trailing: tuckPad)
            : EdgeInsets(top: 11, leading: tuckPad, bottom: 11, trailing: freeInset)

        return VStack(alignment: .leading, spacing: 8) {
            // Upper area (header · project · command) doubles as a "jump to chat" tap target; kept
            // SEPARATE from the actions row below so the tap gesture never swallows a button press.
            VStack(alignment: .leading, spacing: 8) {
                header(r)
                projectLine(r)
                chatTitleLine(r)
                commandChip(r)
                captionLine(r)
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpenChat(r) }

            actions(r)
        }
        .padding(pad)
        .frame(width: DS.Geo.ribbonWidth)
        .background(
            RoundedRectangle(cornerRadius: DS.Geo.ribbonRadius, style: .continuous)
                .fill(DS.panelBG)
        )
        .overlay(
            // 1px neutral border…
            RoundedRectangle(cornerRadius: DS.Geo.ribbonRadius, style: .continuous)
                .strokeBorder(DS.panelBorder, lineWidth: 1)
        )
        .overlay(
            // …plus the accent rim (the mockup's `0 0 0 1px rgba(255,69,58,0.14)` glow seam): red for a
            // permission/attention item, green for a completion notice.
            RoundedRectangle(cornerRadius: DS.Geo.ribbonRadius, style: .continuous)
                .strokeBorder((r.isCompleted ? DS.green : DS.red).opacity(0.14), lineWidth: 1)
        )
        // Ribbon depth. The light panel's OS window shadow is now off (it haloed the padded tower window),
        // so the ribbon carries its own contained SwiftUI shadow — safe now that `LightRootView` pads the
        // window with `glowMargin`, so the fit-to-content edge no longer clips it into a hard rectangle.
        .shadow(color: .black.opacity(0.30), radius: 10 * scale, y: 3 * scale)
    }

    // MARK: - Header (glyph + title + nav)

    private func header(_ r: RibbonItem) -> some View {
        HStack(spacing: 7) {
            Text(verbatim: headerGlyph(r)).font(.system(size: 12))
            Text(headerTitle(r))
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .tracking(0.07 * 9.5)   // 0.07em ≈ tracking in points
                .foregroundStyle(r.isCompleted ? DS.green : DS.redText)
                .lineLimit(1)
            if items.count > 1 {
                Spacer(minLength: 6)
                navigator
            }
        }
        .frame(minHeight: 16)
    }

    /// ✅ for a completion, 💬 for a question (input needed), 🔐 for a permission (decision or handed-off).
    private func headerGlyph(_ r: RibbonItem) -> String {
        switch r.kind {
        case .completed:            return "✅"
        case .attention(.question): return "💬"
        default:                    return "🔐"
        }
    }
    private func headerTitle(_ r: RibbonItem) -> String {
        switch r.kind {
        case .completed:            return L("ribbon.done.title")
        case .attention(.question): return L("ribbon.inputNeeded")
        default:                    return L("ribbon.permissionNeeded")
        }
    }

    private var navigator: some View {
        HStack(spacing: 3) {
            NavButton(glyph: "‹", help: L("ribbon.prev"), action: prev)
            Text(Lf("ribbon.counter", index + 1, items.count))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                .frame(minWidth: 38)
                .multilineTextAlignment(.center)
            NavButton(glyph: "›", help: L("ribbon.next"), action: next)
        }
        .fixedSize()
    }

    /// Cycle the shown item with wraparound (§6.4).
    private func next() {
        guard items.count > 1 else { return }
        index = (index + 1) % items.count
    }
    private func prev() {
        guard items.count > 1 else { return }
        index = (index - 1 + items.count) % items.count
    }

    // MARK: - Project / branch

    private func projectLine(_ r: RibbonItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(r.project)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
            if !r.branch.isEmpty {
                Text(r.branch)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let label = r.remoteHostLabel {
                Text(Lf("remote.badge.host", label))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DS.neutralBtn, in: Capsule())
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Chat title (which chat in the project is asking)

    /// One-line chat title (aiTitle/lastPrompt) under the project — tail-truncated with an ellipsis;
    /// the full text lives in the tooltip. Hidden when the chat has no title yet.
    @ViewBuilder
    private func chatTitleLine(_ r: RibbonItem) -> some View {
        if let title = r.chatTitle, !title.isEmpty {
            Text(title)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, -4)   // tuck under the project line, tighter than the stack's 8pt rhythm
                .help(title)
        }
    }

    // MARK: - Command chip (decisions only)

    @ViewBuilder
    private func commandChip(_ r: RibbonItem) -> some View {
        if let command = r.command, !command.isEmpty {
            HStack(spacing: 6) {
                Text(verbatim: "$")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.textTertiary)
                Text(command)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.codeText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 9)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.codeBG)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(DS.line, lineWidth: 1)
            )
            .help(command)
        }
    }

    // MARK: - Caption (completion notices only)

    /// A one-line "Агент завершил работу" caption under the project — completion notices only (decisions
    /// carry the `$` command chip instead; attention items need no caption).
    @ViewBuilder
    private func captionLine(_ r: RibbonItem) -> some View {
        if r.isCompleted {
            Text(L("ribbon.done.caption"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.textTertiary)
                .lineLimit(1)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actions(_ r: RibbonItem) -> some View {
        if r.isDecision {
            HStack(spacing: 6) {
                ActionButton(title: L("perm.allow"), kind: .primary) { onAllow(r) }
                ActionButton(title: L("perm.deny"), kind: .deny) { onDeny(r) }
                ActionButton(title: L("perm.allInChat"), kind: .neutral,
                             help: L("perm.allInChat.tooltip")) { onAll(r) }
            }
            .padding(.top, 1)
        } else {
            // Attention: the only action is to jump into the chat and answer there.
            ActionButton(title: L("ribbon.openChat"), kind: .primary) { onOpenChat(r) }
                .padding(.top, 1)
        }
    }
}

// MARK: - Subviews

/// Square ‹/› navigator button. Hover lightens its neutral fill (mirrors the mockup `style-hover`).
private struct NavButton: View {
    let glyph: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: glyph)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(DS.textSecondary)
                .frame(width: 19, height: 19)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? DS.neutralBtnHover : DS.neutralBtn)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(DS.line, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// One decision / action button. `kind` picks the fill/text/hover per the mockup.
private struct ActionButton: View {
    enum Kind { case primary, deny, neutral }

    let title: String
    let kind: Kind
    var help: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background)
                )
                .overlay(border)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(OptionalHelp(help: help))
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary: DS.primaryText
        case .deny:    DS.redText
        case .neutral: DS.textPrimary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: hovering ? .white : DS.primaryFill
        case .deny:    hovering ? DS.denyHover : .clear
        case .neutral: hovering ? DS.neutralBtnHover : DS.neutralBtn
        }
    }

    @ViewBuilder private var border: some View {
        // Only the deny button carries a visible 1px outline; primary/neutral are borderless fills.
        if kind == .deny {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.line, lineWidth: 1)
        }
    }
}

/// Apply `.help` only when a tooltip string is present (keeps the call site declarative).
private struct OptionalHelp: ViewModifier {
    let help: String?
    func body(content: Content) -> some View {
        if let help { content.help(help) } else { content }
    }
}
