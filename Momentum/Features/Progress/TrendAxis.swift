import SwiftUI
import Charts

/// The ONE x-axis system for date-keyed charts (axis-alignment pass 2026-08-19).
///
/// The alignment law — learned once in `RunCharts` ("weekday letters sat half a bar off") and
/// now applied everywhere: **marks plot at the series' own instants, and labels are placed at
/// those exact same instants**, so a label can only ever sit under a mark that exists. The old
/// axes broke this two ways at once: `unit:`-binned bars center mid-band while
/// `.stride(by:)` ticks sit at the band's left edge (a constant half-bin offset), and rolling
/// weekly windows start on an arbitrary weekday while `.weekOfYear` strides tick calendar week
/// starts — labels naming dates with no bar at all.
///
/// Charts therefore plot **unit-less** x values and take their whole x treatment from here:
/// - `marks(for:granularity:)` — labels at a subset of the data's own dates, anchored to the
///   NEWEST point and striding backward (the newest bar is the one being looked for; Oura and
///   Garmin both anchor labeling to "now"). Density adapts: weekday letters across a week of
///   bars, month + day for mid ranges, month-only for long ranges (the first point of each
///   month — a month can never label twice). Edge labels nestle inward so nothing clips.
/// - `domain(for:granularity:)` — the data span padded by half the point spacing per side, so
///   edge bars center cleanly inside the plot instead of clipping at the frame.
/// - `labelFont` / `styleValueLabel` — the one axis typeface: Inter at `Theme.FontSize.label`,
///   medium, tabular digits, `inkTertiary` (the docs/RECOVERY-HUB-PLAN.md rule the Health
///   cards already followed; Progress had drifted to 10 pt system).
///
/// No x gridlines or ticks: bars are their own gridlines (the quiet Oura look); value structure
/// comes from the y-axis hairlines.
enum TrendAxis {

    enum Granularity { case daily, weekly }

    /// The one axis-label typeface (see header). Apply `.foregroundStyle(Theme.inkTertiary)`
    /// alongside — kept separate because `AxisValueLabel` takes them as separate modifiers.
    static var labelFont: Font { Font.rounded(Theme.FontSize.label, weight: .medium).monospacedDigit() }

    // MARK: Domain

    /// Median gap between consecutive points — robust to a missing bucket or an irregular tail.
    private static func spacing(_ sorted: [Date], fallback: TimeInterval) -> TimeInterval {
        guard sorted.count > 1 else { return fallback }
        let gaps = zip(sorted.dropFirst(), sorted).map { $0.timeIntervalSince($1) }.filter { $0 > 0 }.sorted()
        guard !gaps.isEmpty else { return fallback }
        return gaps[gaps.count / 2]
    }

    /// The plot's x domain: data span + half the point spacing each side, so the first and last
    /// bars sit fully inside the frame (every chart previously chose its own padding, or none —
    /// which is why edge bars clipped on some cards and floated on others).
    static func domain(for dates: [Date], granularity: Granularity) -> ClosedRange<Date> {
        let fallback: TimeInterval = granularity == .daily ? 86_400 : 7 * 86_400
        let sorted = dates.sorted()
        guard let lo = sorted.first, let hi = sorted.last else {
            return Date().addingTimeInterval(-fallback)...Date()
        }
        let half = spacing(sorted, fallback: fallback) / 2
        return lo.addingTimeInterval(-half)...(hi.addingTimeInterval(half))
    }

    // MARK: Label selection

    enum LabelForm { case weekdayNarrow, monthDay, monthOnly }

    static func labelForm(count: Int, granularity: Granularity) -> LabelForm {
        switch granularity {
        case .daily: count <= 9 ? .weekdayNarrow : (count <= 42 ? .monthDay : .monthOnly)
        case .weekly: count <= 14 ? .monthDay : .monthOnly
        }
    }

    /// The subset of the series' own dates that carry labels (~`target`, newest always included).
    static func labelDates(for dates: [Date], granularity: Granularity, target: Int = 5) -> [Date] {
        let sorted = dates.sorted()
        guard sorted.count > 1 else { return sorted }
        switch labelForm(count: sorted.count, granularity: granularity) {
        case .weekdayNarrow:
            return sorted   // a letter under every bar, Oura's week view
        case .monthDay:
            let stride = max(1, Int((Double(sorted.count) / Double(target)).rounded(.up)))
            return thinFromEnd(sorted, stride: stride)
        case .monthOnly:
            // First point of each calendar month present, then thinned — labels land on real
            // marks AND no month repeats (the "Jun · Jun" rule, kept by construction).
            let cal = Calendar.current
            var firsts: [Date] = []
            var seen = Set<Int>()
            for d in sorted {
                let c = cal.dateComponents([.year, .month], from: d)
                if seen.insert((c.year ?? 0) * 12 + (c.month ?? 0)).inserted { firsts.append(d) }
            }
            let stride = max(1, Int((Double(firsts.count) / Double(target)).rounded(.up)))
            return thinFromEnd(firsts, stride: stride)
        }
    }

    /// Every `stride`-th element counted from the END — the newest point always labels.
    private static func thinFromEnd(_ dates: [Date], stride: Int) -> [Date] {
        guard stride > 1 else { return dates }
        var out: [Date] = []
        var i = dates.count - 1
        while i >= 0 { out.append(dates[i]); i -= stride }
        return out.reversed()
    }

    static func text(_ date: Date, form: LabelForm) -> String {
        switch form {
        case .weekdayNarrow: date.formatted(.dateTime.weekday(.narrow))
        case .monthDay: date.formatted(.dateTime.month(.abbreviated).day())
        case .monthOnly: date.formatted(.dateTime.month(.abbreviated))
        }
    }

    // MARK: The axis itself

    /// The complete x-axis for a date-keyed chart whose marks plot unit-less at `dates`.
    static func marks(for dates: [Date], granularity: Granularity, target: Int = 5) -> some AxisContent {
        let form = labelForm(count: dates.count, granularity: granularity)
        let values = labelDates(for: dates, granularity: granularity, target: target)
        let newest = values.last
        let oldest = values.first
        return AxisMarks(values: values) { value in
            AxisValueLabel(anchor: anchor(for: value.as(Date.self), form: form,
                                          oldest: oldest, newest: newest)) {
                if let d = value.as(Date.self) {
                    Text(text(d, form: form))
                        .font(labelFont)
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
        }
    }

    /// Wide edge labels nestle inward (leading anchor at the left edge, trailing at the right)
    /// so the newest label never clips off the frame — single weekday letters stay centered.
    private static func anchor(for date: Date?, form: LabelForm,
                               oldest: Date?, newest: Date?) -> UnitPoint {
        guard form != .weekdayNarrow, let date else { return .top }
        if date == newest { return .topTrailing }
        if date == oldest { return .topLeading }
        return .top
    }
}
