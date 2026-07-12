import SwiftUI

/// The right-click quick popover on the light (§8 A): the three widget controls — opacity slider,
/// size XS/S/M/L/XL, "закрепить позицию" toggle. The same three live inside the panel's settings
/// ("Виджет на экране", §8 B). Visual reference: block 06 of `ccemaphore.dc.html` and the
/// "ВИДЖЕТ НА ЭКРАНЕ" group in `Panel.dc.html`.
///
/// The outer container is intentionally neutral (no heavy surface): this view is embedded both
/// standalone in the quick popover and inside the panel's settings group, so the host owns the
/// background. Live theme switching is automatic — every color is a `DS` dynamic token.
struct WidgetQuickSettingsView: View {
    @ObservedObject var settings: WidgetSettings
    /// This view is its own top-level struct (embedded in the panel's Settings tab and in the
    /// standalone right-click popover), so it must observe the localization manager directly:
    /// its stored inputs don't change on a language switch, so SwiftUI would otherwise skip
    /// re-invoking `body` and leave the `L(...)` labels stale. (CLAUDE.md localization rule 4.)
    @ObservedObject private var loc = LocalizationManager.shared
    /// `true` when hosted inside the panel's Settings tab: drop the card padding/fixed width and the
    /// own section header (the panel supplies `SettingsSectionHeader`), and sit on the panel's 12px
    /// gutter. `false` (default) is the standalone right-click quick popover, which owns its surface.
    var embedded: Bool = false

    /// Shared label column width so the three rows line up. Slightly tighter when embedded so the
    /// controls have more room at the panel width.
    private var labelWidth: CGFloat { embedded ? 84 : 88 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !embedded {
                Text(L("widget.section"))
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .tracking(0.9)
                    .foregroundStyle(DS.textTertiary)
            }

            opacityRow
            sizeRow
            modeRow
            orientationRow
            pinRow
        }
        .padding(.horizontal, embedded ? 12 : 13)
        .padding(.vertical, embedded ? 2 : 13)
        .frame(width: embedded ? nil : 240)
        .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
    }

    // MARK: - Rows

    /// Прозрачность: label · slider · live "%". Bound to the 0.25…1.0 collapsed-opacity range.
    private var opacityRow: some View {
        HStack(spacing: 10) {
            rowLabel(L("widget.opacity"))
            Slider(value: $settings.opacity, in: 0.25...1.0)
            Text("\(Int((settings.opacity * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(DS.textSecondary)
                .frame(width: 30, alignment: .trailing)
        }
    }

    /// Размер: label · custom XS/S/M/L/XL pill segments. Custom pills (not `.segmented`) so the active
    /// fill matches the spec's neutral graphite tokens in both themes.
    private var sizeRow: some View {
        HStack(spacing: 10) {
            rowLabel(L("widget.size"))
            HStack(spacing: 5) {
                ForEach(WidgetSettings.WidgetSize.allCases) { size in
                    sizeSegment(size)
                }
            }
        }
    }

    /// Вид: label · доска / один цвет segments — picks summary (per-status counts) vs single (dominant
    /// lamp only). Same custom-pill style as the size row.
    private var modeRow: some View {
        HStack(spacing: 10) {
            rowLabel(L("widget.mode"))
            HStack(spacing: 5) {
                ForEach(WidgetSettings.DisplayMode.allCases) { mode in
                    modeSegment(mode)
                }
            }
        }
    }

    /// Ориентация: label · vertical / horizontal segments — picks whether the three lamps stack or
    /// run in a row. Same custom-pill style as the size/mode rows.
    private var orientationRow: some View {
        HStack(spacing: 10) {
            rowLabel(L("widget.orientation"))
            HStack(spacing: 5) {
                ForEach(WidgetSettings.Orientation.allCases) { o in
                    orientationSegment(o)
                }
            }
        }
    }

    /// Закрепить позицию: label · trailing switch. Tinted green when on (the lock is engaged).
    private var pinRow: some View {
        HStack {
            rowLabel(L("widget.pin"), fixedWidth: false)
            Spacer(minLength: 8)
            Toggle("", isOn: $settings.pinned)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(DS.green)
        }
    }

    // MARK: - Pieces

    /// A row label (SF Pro 500 11px, secondary). Opacity/size rows pin the width for alignment;
    /// the pin row lets it size to content so the toggle can hug the trailing edge.
    private func rowLabel(_ text: String, fixedWidth: Bool = true) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DS.textSecondary)
            .frame(width: fixedWidth ? labelWidth : nil, alignment: .leading)
    }

    /// One XS/S/M/L/XL pill; active segment uses the brighter neutral fill + primary text.
    private func sizeSegment(_ size: WidgetSettings.WidgetSize) -> some View {
        segmentPill(size.letter, active: settings.size == size, mono: true) { settings.size = size }
    }

    /// One доска/один-цвет pill; active segment uses the brighter neutral fill + primary text.
    private func modeSegment(_ mode: WidgetSettings.DisplayMode) -> some View {
        segmentPill(modeLabel(mode), active: settings.displayMode == mode) { settings.displayMode = mode }
    }

    private func modeLabel(_ mode: WidgetSettings.DisplayMode) -> String {
        switch mode {
        case .summary: L("widget.mode.summary")
        case .single:  L("widget.mode.single")
        }
    }

    /// One vertical/horizontal pill; active segment uses the brighter neutral fill + primary text.
    private func orientationSegment(_ o: WidgetSettings.Orientation) -> some View {
        segmentPill(orientationLabel(o), active: settings.orientation == o) { settings.orientation = o }
    }

    private func orientationLabel(_ o: WidgetSettings.Orientation) -> String {
        switch o {
        case .vertical:   L("widget.orientation.vertical")
        case .horizontal: L("widget.orientation.horizontal")
        }
    }
}
