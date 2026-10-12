import SwiftUI

/// Small per-row decorations shared by the panel and the ribbon: which agent a chat belongs to
/// (Claude / Codex), where it runs (a host glyph), and the sub-agent rows under an expanded chat.
/// Neutral graphite like every non-status control — the lamps keep the only saturated hues.

/// "Claude" / "Codex" pill. Proper nouns, so the visible text isn't localized; the accessibility label is.
struct AgentBadge: View {
    let agent: AgentKind

    var body: some View {
        Text(agent == .claude ? "Claude" : "Codex")
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .tracking(0.3)
            .foregroundStyle(DS.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(DS.neutralBtn, in: Capsule())
            .accessibilityLabel(agent == .claude ? L("agent.claude.a11y") : L("agent.codex.a11y"))
    }
}

/// Where a chat runs, as one SF Symbol with a localized tooltip. Nothing for `.unknown`.
struct HostGlyph: View {
    let host: SessionHost

    var body: some View {
        if let symbol = HostGlyph.symbol(host) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DS.textTertiary)
                .help(HostGlyph.label(host))
                .accessibilityLabel(HostGlyph.label(host))
        }
    }

    static func symbol(_ host: SessionHost) -> String? {
        switch host {
        case .desktop:  return "macwindow"
        case .ide:      return "chevron.left.forwardslash.chevron.right"
        case .terminal: return "terminal"
        case .codexApp: return "bubble.left.and.text.bubble.right"
        case .unknown:  return nil
        }
    }

    static func label(_ host: SessionHost) -> String {
        switch host {
        case .desktop:  return L("host.desktop")
        case .ide:      return L("host.ide")
        case .terminal: return L("host.terminal")
        case .codexApp: return L("host.codexApp")
        case .unknown:  return ""
        }
    }
}

/// One sub-agent / child-session line under an expanded chat row: indented, a smaller status dot, the
/// agent's name, its prompt/title (secondary) and age. Tapping it jumps to the PARENT chat (a child has
/// no surface of its own in any host).
struct ChildAgentRow: View {
    let child: ChildAgent
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(DS.line).frame(width: 1, height: 18).padding(.leading, 4)
            StatusDot(color: DS.status(child.state), diameter: 6, glow: 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(child.name)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                    if child.kind == .workflow {
                        Text(L("child.kind.workflow"))
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(DS.textTertiary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(DS.neutralBtn, in: Capsule())
                    }
                }
                if let t = child.title, !t.isEmpty {
                    Text(t)
                        .font(.system(size: 10))
                        .foregroundStyle(DS.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Fmt.age(child.lastActivity))
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(DS.textTertiary)
                .fixedSize()
        }
        .padding(.leading, 26)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? DS.hoverRow : .clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }
}

/// The glowing status dot, shared by the panel header, session rows and child rows. (Moved here from
/// `FloatingPanelView` so `ChildAgentRow` can use it without widening that file's private scope.)
struct StatusDot: View {
    let color: Color
    var diameter: CGFloat = 9
    var glow: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .shadow(color: color.opacity(0.7), radius: glow / 2)
    }
}

extension Fmt {
    /// A rate-limit window as a compact label: 300 → "5h", 1440 → "24h", 10080 → "7d".
    static func windowLabel(minutes: Int) -> String {
        if minutes % 1440 == 0, minutes >= 2880 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// Compact relative age: "12s", "4m", "2h", "3d".
    static func age(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        switch s {
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m"
        case ..<86_400: return "\(s / 3600)h"
        default: return "\(s / 86_400)d"
        }
    }
}
