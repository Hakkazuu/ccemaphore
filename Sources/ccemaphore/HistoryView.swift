import SwiftUI
import AppKit

/// Token/cost history (§4.3) — a master/detail view: a period summary + per-day bar chart on top,
/// the list of days on the left, and the chats (with names + tokens) of the selected day on the right.
///
/// Numbers come only from `ccusage`: day totals from `ccusage daily`, per-chat totals from
/// `ccusage session`. Chats are grouped by their last-activity day — so a rare multi-day chat shows
/// under the day it finished, and a day may carry tokens with no chat of its own (handled in the
/// detail empty state). History reaches only as far back as Claude Code keeps transcripts (footer).
struct HistoryView: View {
    @ObservedObject var engine: StateEngine
    var body: some View { HistoryContentView(days: engine.days) }
}

/// The history UI over a plain `[DayStat]` — split out from the engine wrapper so it renders from any
/// data source (the live engine, or a fixture for snapshot rendering).
struct HistoryContentView: View {
    let days: [DayStat]
    @State private var selectedID: String?
    /// Re-render the open history window when the language changes (its NSWindow title is updated
    /// separately in `HistoryWindowController.localeDidChange`).
    @ObservedObject private var loc = LocalizationManager.shared

    private var selectedDay: DayStat? { days.first { $0.id == selectedID } }
    private var maxDayTokens: Int { days.map(\.totalTokens).max() ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            if days.isEmpty {
                emptyState
            } else {
                SummaryStrip(days: days, selectedID: $selectedID)
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
    }

    // MARK: - Left: days

    private var dayList: some View {
        List(selection: $selectedID) {
            ForEach(days) { day in
                DayRow(day: day, maxTokens: maxDayTokens, isToday: day.id == Fmt.todayString)
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
                    }
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

                    if day.chats.isEmpty {
                        detailEmpty(day)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(day.chats) { chat in
                                    ChatRow(chat: chat, maxTokens: day.chats.first?.tokens ?? 0)
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

    /// Keep a valid selection: default to today, else the newest day; re-pick if the day vanished.
    private func syncSelection() {
        if let s = selectedID, days.contains(where: { $0.id == s }) { return }
        selectedID = days.first(where: { $0.id == Fmt.todayString })?.id ?? days.first?.id
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
    let days: [DayStat]
    @Binding var selectedID: String?

    private var totalTokens: Int { days.reduce(0) { $0 + $1.totalTokens } }
    private var totalCost: Double { days.reduce(0) { $0 + $1.costUsd } }
    private var totalChats: Int { days.reduce(0) { $0 + $1.chatCount } }
    private var maxTokens: Int { days.map(\.totalTokens).max() ?? 0 }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("history.title")).font(.headline)
                HStack(alignment: .top, spacing: 16) {
                    stat(Fmt.tokens(totalTokens), L("history.stat.tokens"))
                    stat(Fmt.cost(totalCost), L("history.stat.cost"))
                    stat("\(totalChats)", Lplural("noun.chats", totalChats))
                    stat("\(days.count)", Lplural("noun.days", days.count))
                }
            }
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

    private var chart: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(days.reversed())) { day in
                    BarColumn(
                        fraction: maxTokens > 0 ? Double(day.totalTokens) / Double(maxTokens) : 0,
                        state: day.id == selectedID ? .selected
                             : (day.id == Fmt.todayString ? .today : .normal),
                        tooltip: "\(Fmt.dayLabel(day.date)), \(Fmt.weekday(day.date)) · \(Fmt.tokens(day.totalTokens)) · \(Fmt.cost(day.costUsd))",
                        onTap: { selectedID = day.id })
                }
            }
            .frame(height: 42, alignment: .bottom)
            Text(L("history.chart.caption")).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Rows

private struct DayRow: View {
    let day: DayStat
    let maxTokens: Int
    let isToday: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isToday { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                    Text(Fmt.dayLabel(day.date)).font(.callout).fontWeight(isToday ? .semibold : .regular)
                    Text(Fmt.weekday(day.date)).font(.caption2).foregroundStyle(.secondary)
                }
                VolumeBar(fraction: maxTokens > 0 ? Double(day.totalTokens) / Double(maxTokens) : 0,
                          width: 92, tint: isToday ? .accentColor : Color.secondary.opacity(0.55))
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

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Palette.color(for: chat.project)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.title ?? L("chat.untitled")).font(.callout).lineLimit(1)
                HStack(spacing: 6) {
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

/// One clickable bar in the per-day chart: a wide invisible hit area (easy to target), a hover
/// highlight + pointing-hand cursor (so it reads as interactive), and a selected/today accent.
private struct BarColumn: View {
    enum BarState { case normal, today, selected }
    let fraction: Double
    let state: BarState
    let tooltip: String
    let onTap: () -> Void
    @State private var hovering = false

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
                .frame(width: 13, height: 42)
            Capsule().fill(barColor)
                .frame(width: 7, height: max(3, 38 * min(1, max(0, fraction))))
        }
        .frame(width: 13, height: 42, alignment: .bottom)
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
