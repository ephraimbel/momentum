import SwiftUI
import Charts

/// Tap-to-inspect for the Trends charts: tap (or drag across) any chart and a hairline cursor + pill
/// show the exact value for the nearest day/week; tap the same spot again to dismiss. One shared
/// state machine + callout so every chart answers "what's this number?" identically.
struct ChartScrubState {
    /// The pinned (snapped-to-a-data-point) x — nil when nothing is selected.
    var pinned: Date?
    private var dragging = false
    private var pendingClear = false

    /// Feeds `chartXSelection` updates through the tap/drag state machine: a tap pins the nearest
    /// point (and stays after the finger lifts), a drag scrubs, a second tap on the same point clears.
    mutating func handle(_ raw: Date?, dates: [Date]) {
        if let snapped = raw.flatMap({ Self.nearest(to: $0, in: dates) }) {
            if !dragging, snapped == pinned {
                pendingClear = true            // tap began on the pinned point — clear on release…
            } else {
                pinned = snapped               // …unless it turns into a drag to a new point
                pendingClear = false
            }
            dragging = true
        } else {
            dragging = false
            if pendingClear { pinned = nil; pendingClear = false }
        }
    }

    static func nearest(to date: Date, in dates: [Date]) -> Date? {
        dates.min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
    }
}

extension Binding where Value == ChartScrubState {
    /// The binding to hand `chartXSelection(value:)`, snapping to the chart's own points.
    func selection(dates: [Date]) -> Binding<Date?> {
        Binding<Date?>(get: { wrappedValue.pinned },
                       set: { wrappedValue.handle($0, dates: dates) })
    }
}

/// Owns one chart's tap-to-inspect cursor so scrub ticks re-render only that card. When the
/// `ChartScrubState` lived as `@State` on the screen, every selection update during a drag
/// invalidated the entire Progress tree (~60×/s) — the P1 Trends scroll glitch. The chart builder
/// receives the pinned date to draw its `TrendScrub.mark`; the host applies `chartXSelection`.
struct ScrubChartHost<ChartView: View>: View {
    /// The chart's own data points — selection snaps to these, and a change (range flip, new
    /// data) clears any pin, since a pinned day from the old window means nothing in the new one.
    let dates: [Date]
    /// Deterministic pin from outside (the `--scrub-demo` harness — simctl can't tap a chart).
    var seed: Date? = nil
    @ViewBuilder let chart: (Date?) -> ChartView
    @State private var scrub = ChartScrubState()

    var body: some View {
        chart(scrub.pinned)
            .chartXSelection(value: $scrub.selection(dates: dates))
            .onChange(of: dates) { scrub = .init() }
            .onChange(of: seed) { if let seed { scrub.pinned = seed } }
            .onAppear { if let seed { scrub.pinned = seed } }   // seed set before this chart mounted
    }
}

enum TrendScrub {
    /// The scrub callout drawn inside a chart: a vertical hairline at the selected bucket, topped by
    /// a value + date pill. Pass the same calendar `unit` the chart's marks plot with so the cursor
    /// centers on the bar/point.
    static func mark(at date: Date, unit: Calendar.Component? = nil,
                     value: String, label: String) -> some ChartContent {
        let x: PlottableValue<Date> = unit.map { .value("Selected", date, unit: $0) }
            ?? .value("Selected", date)
        return RuleMark(x: x)
            .foregroundStyle(Theme.inkSecondary.opacity(0.45))
            .lineStyle(StrokeStyle(lineWidth: 1))
            .annotation(position: .top, spacing: 4,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                VStack(spacing: 1) {
                    Text(value).font(.system(size: 12, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    Text(label).font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.background))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.hairline))
                .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
            }
    }

    /// "Wk of Jul 13" — the weekly-bucket caption used by every weekly chart.
    static func weekLabel(_ d: Date) -> String {
        "Wk of \(d.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// "Wed, Jul 15" — the daily-bucket caption.
    static func dayLabel(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
