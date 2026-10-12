import SwiftUI
import AppKit

/// Token/cost history (§4.3) — a master/detail view: a period summary + per-day bar chart on top,
/// the list of days on the left, and the chats (with names + tokens) of the selected day on the right.
///
/// Numbers come only from `ccusage`: day totals from `ccusage daily`, per-chat totals from
/// `ccusage session` — for Claude Code AND Codex, which ccusage ≥ 20 reports together. Chats are grouped
/// by their last-activity day — so a rare multi-day chat shows under the day it finished, and a day may
/// carry tokens with no chat of its own (handled in the detail empty state). When Codex usage is present
/// the window shows the per-agent split (stacked bars, badges) and an All / Claude / Codex filter.
/// History reaches only as far back as Claude Code keeps transcripts (footer).
struct HistoryView: View {
    @ObservedObject var engine: StateEngine
    var body: some View { HistoryContentView(days: engine.days) }
}

/// The history UI over a plain `[DayStat]` — split out from the engine wrapper so it renders from any
/// data source (the live engine, or a fixture for snapshot rendering).
struct HistoryContentView: View {
    let days: [DayStat]
    @State private var selectedID: String?
    /// Narrow the whole window to one agent (nil = both). Offered only when the data has Codex usage,
    /// so a Claude-only install sees the window exactly as before.
    @State private var agentFilter: AgentKind? = nil
    /// Re-render the open history window when the language changes (its NSWindow title is updated
    /// separately in `HistoryWindowController.localeDidChange`).
    @ObservedObject private var loc = LocalizationManager.shared

    private var hasCodex: Bool { days.contains { $0.share(of: .codex) != nil } }
    /// The days as filtered: each narrowed to the chosen agent, days where it did nothing dropped.
    private var visibleDays: [DayStat] {
        guard let a = agentFilter else { return days }
        return days.compactMap { $0.restricted(to: a) }
    }
    /// Draw the Claude/Codex split (bars, captions, badges) — only in the unfiltered, mixed view.
    private var showsSplit: Bool { agentFilter == nil && hasCodex }
    private var selectedDay: DayStat? { visibleDays.first { $0.id == selectedID } }
    private var maxDayTokens: Int { visibleDays.map(\.totalTokens).max() ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            if days.isEmpty {
                emptyState
            } else {
                SummaryStrip(days: visibleDays, agentFilter: $agentFilter, showsFilter: hasCodex,
                             selectedID: $selectedID)
                Divider()
                HSplitView {
                    dayList.frame(minWidth: 232, idealWidth: 256, maxWidth: 340)
                    chatDetail.frame(minWidth: 348, maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 660, minHeight: 440)
        .onAppear(perform: syncSelection)
        .onChange(of: days) { _ in syncSelection() }
        .onChange(of: agentFilter) { _ in syncSelection() }
    }

    // MARK: - Left: days

    private var dayList: some View {
        List(selection: $selectedID) {
            ForEach(visibleDays) { day in
                DayRow(day: day, maxTokens: maxDayTokens, isToday: day.id == Fmt.todayString, split: showsSplit)
                    .tag(day.id)
            }
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, 46)
    }

    // MARK: - Right: chats of the selected day

    private var chatDetail: some View {
        Group {
            if let day = selectedDay {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Fmt.dayFull(day.date)).font(.headline)
                        Text(Lf("history.detail.summary", Lcount("noun.chats", day.chatCount), Fmt.tokens(day.totalTokens), Fmt.cost(day.costUsd)))
                            .font(.caption).foregroundStyle(.secondary)
                        if showsSplit, day.agents.count > 1 {
                            Text(AgentSplit.text(day))
                                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

                    if day.chats.isEmpty {
                        detailEmpty(day)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(day.chats) { chat in
                                    ChatRow(chat: chat, maxTokens: day.chats.first?.tokens ?? 0, showsAgent: hasCodex)
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                    }
                }
            } else {
                Text(L("history.selectDay")).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func detailEmpty(_ day: DayStat) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "tray").font(.largeTitle).foregroundStyle(.tertiary)
            Text(day.totalTokens > 0
                 ? Lf("history.detail.carryOver", Fmt.tokens(day.totalTokens))
                 : L("history.detail.noChats"))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    // MARK: - Empty / footer

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(L("history.title")).font(.title2).bold()
            Text(L("history.noData")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            Text(Lf("history.footer", ClaudeRetention.label))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("settings.json") { revealSettings() }.buttonStyle(.link)
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: - Behavior

    /// Keep a valid selection: default to today, else the newest day; re-pick if the day vanished (data
    /// refresh, or the agent filter dropped it).
    private func syncSelection() {
        let shown = visibleDays
        if let s = selectedID, shown.contains(where: { $0.id == s }) { return }
        selectedID = shown.first(where: { $0.id == Fmt.todayString })?.id ?? shown.first?.id
    }

    private func revealSettings() {
        let path = HooksInstaller.settingsPath
        let url = URL(fileURLWithPath: path)
        let target = FileManager.default.fileExists(atPath: path) ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

// MARK: - Summary strip (period totals + per-day bar chart)

private struct SummaryStrip: View {
    /// The days as currently filtered (the totals follow the filter).
    let days: [DayStat]
    @Binding var agentFilter: AgentKind?
    /// Show the All / Claude / Codex picker + the per-agent totals line (only when Codex usage exists).
    let showsFilter: Bool
    @Binding var selectedID: String?

    private var totalTokens: Int { days.reduce(0) { $0 + $1.totalTokens } }
    private var totalCost: Double { days.reduce(0) { $0 + $1.costUsd } }
    private var totalChats: Int { days.reduce(0) { $0 + $1.chatCount } }
    private var maxTokens: Int { days.map(\.totalTokens).max() ?? 0 }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(L("history.title")).font(.headline)
                    if showsFilter { agentPicker }
                }
                HStack(alignment: .top, spacing: 16) {
                    stat(Fmt.tokens(totalTokens), L("history.stat.tokens"))
                    stat(Fmt.cost(totalCost), L("history.stat.cost"))
                    stat("\(totalChats)", Lplural("noun.chats", totalChats))
                    stat("\(days.count)", Lplural("noun.days", days.count))
                }
                if showsFilter, agentFilter == nil { agentTotals }
            }
            // Never let the chart squeeze this column: its texts would wrap letter by letter and the
            // picker would slide off the edge. The chart adapts to whatever width is left instead.
            .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            chart
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(.callout, design: .rounded)).bold().monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// All / Claude / Codex. Agent names are proper nouns (not localized); "All" and the control's
    /// accessibility label are.
    private var agentPicker: some View {
        Picker(L("history.filter.label"), selection: $agentFilter) {
            Text(L("history.filter.all")).tag(AgentKind?.none)
            ForEach(AgentKind.allCases, id: \.self) { a in
                Text(AgentSplit.name(a)).tag(AgentKind?.some(a))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .accessibilityLabel(L("history.filter.label"))
    }

    /// Per-agent totals over the period: badge + tokens · cost for each agent that did something.
    private var agentTotals: some View {
        HStack(spacing: 12) {
            ForEach(AgentKind.allCases, id: \.self) { a in
                let share = days.reduce(TokenShare()) { acc, d in d.share(of: a).map { acc + $0 } ?? acc }
                if share.tokens > 0 {
                    HStack(spacing: 5) {
                        AgentBadge(agent: a)
                        Text("\(Fmt.tokens(share.tokens)) · \(Fmt.cost(share.cost))")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }

    /// Widest pitch per day (the original fixed layout) and the narrowest we still draw before dropping
    /// the oldest days off the left edge.
    private static let maxSlot: CGFloat = 15
    private static let minSlot: CGFloat = 4

    /// The per-day bar chart, sized to the width the strip has left for it: the pitch shrinks from
    /// `maxSlot` down to `minSlot` as the day count grows (ccusage ≥ 20 reports Codex days beyond Claude's
    /// retention window, so 50+ days are normal now), and only when even that can't fit are the oldest
    /// days dropped — the newest always stay, hugging the right edge like before.
    private var chart: some View {
        VStack(alignment: .trailing, spacing: 5) {
            GeometryReader { geo in
                let count = max(1, days.count)
                let slot = min(Self.maxSlot, max(Self.minSlot, geo.size.width / CGFloat(count)))
                let fit = max(0, min(days.count, Int(geo.size.width / slot)))
                // `days` is newest-first; keep the newest `fit` and draw them oldest → newest.
                let shown = Array(days.prefix(fit).reversed())
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(shown) { day in
                        BarColumn(
                            fraction: maxTokens > 0 ? Double(day.totalTokens) / Double(maxTokens) : 0,
                            state: day.id == selectedID ? .selected
                                 : (day.id == Fmt.todayString ? .today : .normal),
                            tooltip: Self.tooltip(day),
                            slot: slot,
                            onTap: { selectedID = day.id })
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomTrailing)
            }
            .frame(height: 42)
            Text(L("history.chart.caption")).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// "Today, Fri · 1.2M · $3.00", plus the per-agent line on a mixed day.
    private static func tooltip(_ day: DayStat) -> String {
        var s = "\(Fmt.dayLabel(day.date)), \(Fmt.weekday(day.date)) · \(Fmt.tokens(day.totalTokens)) · \(Fmt.cost(day.costUsd))"
        if day.agents.count > 1 { s += "\n" + AgentSplit.text(day) }
        return s
    }
}

/// Per-agent labels shared by the strip, the day rows and the detail header. Agent names are proper
/// nouns and the rest is numbers, so nothing here needs localizing.
private enum AgentSplit {
    static func name(_ a: AgentKind) -> String { a == .claude ? "Claude" : "Codex" }

    /// "Claude 1.2M · $3.00   Codex 300K · $1.00" for the agents that did something that day.
    static func text(_ day: DayStat) -> String {
        day.agents.compactMap { a in
            day.share(of: a).map { "\(name(a)) \(Fmt.tokens($0.tokens)) · \(Fmt.cost($0.cost))" }
        }.joined(separator: "   ")
    }

    /// Codex draws lighter than Claude in a stacked bar, in the row's own tint — the lamps keep the only
    /// saturated hues.
    static func tint(_ a: AgentKind, base: Color) -> Color { a == .claude ? base : base.opacity(0.45) }
}

// MARK: - Rows

private struct DayRow: View {
    let day: DayStat
    let maxTokens: Int
    let isToday: Bool
    /// Draw the bar as Claude + Codex segments (mixed, unfiltered view).
    var split: Bool = false

    private var tint: Color { isToday ? .accentColor : Color.secondary.opacity(0.55) }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isToday { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                    Text(Fmt.dayLabel(day.date)).font(.callout).fontWeight(isToday ? .semibold : .regular)
                    Text(Fmt.weekday(day.date)).font(.caption2).foregroundStyle(.secondary)
                }
                if split, day.agents.count > 1 {
                    SplitVolumeBar(segments: day.agents.compactMap { a in
                        day.share(of: a).map {
                            SplitVolumeBar.Segment(id: a, fraction: maxTokens > 0 ? Double($0.tokens) / Double(maxTokens) : 0,
                                                   tint: AgentSplit.tint(a, base: tint))
                        }
                    }, width: 92)
                    .help(AgentSplit.text(day))
                } else {
                    VolumeBar(fraction: maxTokens > 0 ? Double(day.totalTokens) / Double(maxTokens) : 0,
                              width: 92, tint: tint)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.tokens(day.totalTokens)).font(.callout).monospacedDigit()
                Text("\(day.chatCount) · \(Fmt.cost(day.costUsd))").font(.caption2)
                    .foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ChatRow: View {
    let chat: ChatStat
    let maxTokens: Int
    /// Show the Claude / Codex badge — only once the data has both, so Claude-only rows stay as they were.
    var showsAgent: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Palette.color(for: chat.project)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.title ?? L("chat.untitled")).font(.callout).lineLimit(1)
                HStack(spacing: 6) {
                    if showsAgent { AgentBadge(agent: chat.agent) }
                    let models = Fmt.models(chat.models)
                    if !models.isEmpty { ModelPill(text: models) }
                    Text(chat.project).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if chat.lastActivity > .distantPast {
                        Text(Fmt.clock(chat.lastActivity)).font(.caption2)
                            .foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                VolumeBar(fraction: maxTokens > 0 ? Double(chat.tokens) / Double(maxTokens) : 0,
                          width: 180, height: 4, tint: Palette.color(for: chat.project))
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.tokens(chat.tokens)).font(.callout).fontWeight(.semibold).monospacedDigit()
                Text(Fmt.cost(chat.cost)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

/// Compact model badge in a chat row — visually distinct from the project label so the two don't blur.
private struct ModelPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.14)))
            .fixedSize()
    }
}

/// A trackless proportional bar (just the fill) — reads as "relative volume", not progress toward a
/// limit. Reserves its full slot width so rows still line up.
private struct VolumeBar: View {
    let fraction: Double
    var width: CGFloat = 90
    var height: CGFloat = 4
    var tint: Color = .secondary

    var body: some View {
        Capsule().fill(tint)
            .frame(width: max(2, width * min(1, max(0, fraction))), height: height)
            .frame(width: width, alignment: .leading)
    }
}

/// `VolumeBar` split into per-agent segments laid end to end (Claude solid, Codex lighter) in the same
/// slot width, so split and plain rows still line up. Fractions are shares of the SAME maximum as the
/// plain bars, so the segments together span what one solid bar would.
private struct SplitVolumeBar: View {
    struct Segment: Identifiable {
        let id: AgentKind
        let fraction: Double
        let tint: Color
    }
    let segments: [Segment]
    var width: CGFloat = 90
    var height: CGFloat = 4

    var body: some View {
        let gap: CGFloat = 1
        let usable = width - gap * CGFloat(max(0, segments.count - 1))
        HStack(spacing: gap) {
            ForEach(segments) { s in
                Capsule().fill(s.tint)
                    .frame(width: max(2, usable * min(1, max(0, s.fraction))), height: height)
            }
        }
        .frame(width: width, alignment: .leading)
        .clipped()
    }
}

/// One clickable bar in the per-day chart: a wide invisible hit area (easy to target), a hover
/// highlight + pointing-hand cursor (so it reads as interactive), and a selected/today accent.
/// `slot` is the column's pitch (hit area + gap); the bar itself takes about half of it, capped at the
/// original 7 pt so a short history still looks as before.
private struct BarColumn: View {
    enum BarState { case normal, today, selected }
    let fraction: Double
    let state: BarState
    let tooltip: String
    var slot: CGFloat = 15
    let onTap: () -> Void
    @State private var hovering = false

    private var hitWidth: CGFloat { max(2, slot - 2) }
    private var barWidth: CGFloat { max(2, min(7, (slot * 0.5).rounded())) }

    private var barColor: Color {
        switch state {
        case .selected: return .accentColor
        case .today: return hovering ? .accentColor : Color.accentColor.opacity(0.6)
        case .normal: return hovering ? Color.secondary.opacity(0.8) : Color.secondary.opacity(0.4)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 3)
                .fill(hovering || state == .selected ? Color.secondary.opacity(0.12) : .clear)
                .frame(width: hitWidth, height: 42)
            Capsule().fill(barColor)
                .frame(width: barWidth, height: max(3, 38 * min(1, max(0, fraction))))
        }
        .frame(width: slot, height: 42, alignment: .bottom)
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        // Guarantee a balancing pop if the view is torn down while the pointer is still inside it (the
        // history window closed mid-hover, or a bar removed): SwiftUI doesn't reliably fire .onHover(false)
        // on teardown, and an unbalanced push() would leave a stuck pointing-hand on the app cursor stack.
        .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
        .onTapGesture(perform: onTap)
        .help(tooltip)
    }
}

// MARK: - Helpers

/// Reads Claude Code's transcript-retention window so the footer can name the real limit.
enum ClaudeRetention {
    static var label: String {
        let s = HooksInstaller.readSettingsLenient()
        if let n = s["cleanupPeriodDays"] as? Int { return Lcount("noun.daysShort", n) }
        if let n = (s["cleanupPeriodDays"] as? NSNumber)?.intValue { return Lcount("noun.daysShort", n) }
        return L("retention.default")
    }
}

/// Lazily creates and shows the history window. Kept in AppKit so the window opens only on demand
/// (a SwiftUI `Window` scene would auto-create at launch, which a menu-bar app doesn't want).
@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: HistoryView(engine: .shared))
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 720, height: 480))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.title = L("window.history.title")
        window?.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Refresh the AppKit window title when the language changes; the SwiftUI content re-renders
    /// itself via its `LocalizationManager` observation.
    func localeDidChange() {
        window?.title = L("window.history.title")
    }
}
