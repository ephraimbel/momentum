import SwiftUI
import Charts
import SwiftData

/// Post-run analysis charts (running-excellence R2) — the "pro" layer over the text splits: a
/// pace-over-distance line, an elevation profile, and a per-split bar chart. Pure read of the stored
/// GPS `samples` + computed splits; no engine changes. Monochrome marks, iridescence reserved for the
/// fastest split (earned = your best). Honors Reduce Motion. Reused by the summary + history detail.
struct RunAnalysisSection: View {
    let gps: GPSDetail
    let type: WorkoutType
    var distanceUnit: DistanceUnit = .auto
    /// HR series from Apple Health for the workout window, used ONLY when we didn't capture a live
    /// series ourselves (an Apple Watch run, or a HealthKit-imported workout — the phone never
    /// streamed HR, but the Watch wrote it to Health). Resolved by the summary and passed in, so the
    /// HR chart shows for every run with heart-rate data anywhere — not just BLE-strap runs.
    var healthHRSeries: [(date: Date, bpm: Double)] = []

    private var unitMeters: Double { distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000 }
    private var unitLabel: String { distanceUnit.resolved() == .imperial ? "mi" : "km" }

    // MARK: Derived series

    private struct Pt { let t: TimeInterval; let distanceM: Double; let altitudeM: Double; let paceSPerKm: Double }
    private struct HRPt { let t: TimeInterval; let bpm: Int }
    private struct SplitBar: Identifiable { let id: Int; let unitIndex: Int; let paceSPerUnit: Double; let isBest: Bool }

    /// The chart series, derived from the GPS samples ONCE. Reducing accepted fixes to cumulative
    /// distance runs a haversine per sample; the old computed-property form recomputed it 2–3× on
    /// every `body` pass (thinned points, splits, HR), and `body` re-evaluates through the reveal
    /// cascade and when Health HR backfills. For a long run that re-walk of thousands of samples on
    /// the main thread is exactly the post-run stutter this caches away.
    private struct Derived { var pts: [Pt]; var hr: [HRPt]; var bars: [SplitBar] }
    @State private var derived: Derived?

    /// Recompute only when an input that shapes the series actually changes.
    private var derivedKey: String {
        "\(gps.samples.count)|\(gps.hrSamples.count)|\(healthHRSeries.count)|\(unitMeters)"
    }

    /// Evenly thin a long trace so the charts stay smooth (keeps endpoints).
    private static func thinned<T>(_ pts: [T], to max: Int = 200) -> [T] {
        guard pts.count > max, max > 2 else { return pts }
        let stride = Double(pts.count - 1) / Double(max - 1)
        return (0..<max).map { pts[Int((Double($0) * stride).rounded())] }
    }

    private static func compute(gps: GPSDetail, health: [(date: Date, bpm: Double)], unitMeters: Double) -> Derived {
        // Points: accepted fixes reduced to cumulative distance + altitude + instantaneous pace.
        let accepted = gps.samples.filter(\.accepted).sorted { $0.t < $1.t }
        var pts: [Pt] = []
        if let first = accepted.first {
            var cumulative = 0.0
            var prev: LocationSample?
            for s in accepted {
                if let p = prev { cumulative += Geo.distance(lat1: p.lat, lon1: p.lon, lat2: s.lat, lon2: s.lon) }
                let pace = s.speedMS > 0.4 ? 1000 / s.speedMS : 0   // near-stopped → 0 = "no pace here"
                pts.append(Pt(t: s.t.timeIntervalSince(first.t), distanceM: cumulative, altitudeM: s.altitudeM, paceSPerKm: pace))
                prev = s
            }
        }
        // HR: prefer our own live series; fall back to Apple Health for Watch/imported runs.
        let local = gps.hrSamples.filter { $0.bpm > 0 }.sorted { $0.t < $1.t }.map { (date: $0.t, bpm: Double($0.bpm)) }
        let readings = local.count >= 4 ? local : health.sorted { $0.date < $1.date }
        var hr: [HRPt] = []
        if let firstHR = readings.first {
            hr = readings.map { HRPt(t: $0.date.timeIntervalSince(firstHR.date), bpm: Int($0.bpm.rounded())) }
        }
        // Splits: only full units (a partial's short sample yields an unreliable pace).
        let splits = CardioMetrics.splits(pts.map { .init(t: $0.t, cumulativeM: $0.distanceM) }, unitMeters: unitMeters)
        let full = splits.filter { !$0.isPartial }
        let bestPace = full.map { $0.durationS / ($0.distanceM / unitMeters) }.min()
        let bars = full.map { s -> SplitBar in
            let pace = s.durationS / max(1, s.distanceM / unitMeters)
            let isBest = bestPace.map { abs(pace - $0) < 0.5 } == true
            return SplitBar(id: s.index, unitIndex: s.index + 1, paceSPerUnit: pace, isBest: isBest)
        }
        return Derived(pts: Self.thinned(pts), hr: Self.thinned(hr), bars: bars)
    }

    // MARK: Body

    var body: some View {
        Group {
            if let d = derived {
                let pts = d.pts
                let hasPace = pts.contains { $0.paceSPerKm > 0 }
                let altitudes = pts.map(\.altitudeM)
                let elevRange = (altitudes.max() ?? 0) - (altitudes.min() ?? 0)
                if pts.count >= 4 || d.hr.count >= 4 {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        if pts.count >= 4 {
                            if hasPace, type != .ride { paceCard(pts) }
                            if d.bars.count >= 2, type != .ride { splitsCard(d.bars) }
                        }
                        if d.hr.count >= 4 { hrCard(d.hr) }
                        if pts.count >= 4, elevRange > 4 { elevationCard(pts, minAlt: altitudes.min() ?? 0) }
                    }
                }
            }
        }
        .task(id: derivedKey) {
            derived = Self.compute(gps: gps, health: healthHRSeries, unitMeters: unitMeters)
        }
    }

    // MARK: Heart rate over time

    private func hrCard(_ hr: [HRPt]) -> some View {
        let avg = gps.avgHR ?? RunSignals.mean(hr.map(\.bpm))
        return chartCard("Heart rate", subtitle: avg.map { "avg \($0) bpm" } ?? "bpm over time") {
            Chart(Array(hr.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Time", p.t / 60),
                         y: .value("BPM", p.bpm))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Theme.ink)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        if let d = value.as(Double.self) { tick("\(Int(d))") }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        // Minute marks in runner's notation (12′), never "m" (reads as meters).
                        if let d = value.as(Double.self) { tick("\(Int(d))′") }
                    }
                }
            }
            .frame(height: 150)
            .accessibilityLabel("Heart rate over time" + (avg.map { ", average \($0) beats per minute" } ?? ""))
        }
    }

    // MARK: Pace over distance

    private func paceCard(_ pts: [Pt]) -> some View {
        let paced = pts.filter { $0.paceSPerKm > 0 }
        return chartCard("Pace", subtitle: "Per \(unitLabel) over distance") {
            Chart(Array(paced.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Distance", p.distanceM / unitMeters),
                         y: .value("Pace", perUnit(p.paceSPerKm)))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Theme.ink)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            // Faster (lower s/unit) reads higher — the intuitive "up = better".
            .chartYScale(domain: .automatic(includesZero: false, reversed: true))
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        if let d = value.as(Double.self) { tick(pace(d)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        if let d = value.as(Double.self) { tick(d.formatted(.number.precision(.fractionLength(0)))) }
                    }
                }
            }
            .frame(height: 150)
        }
    }

    // MARK: Splits

    private func splitsCard(_ bars: [SplitBar]) -> some View {
        let maxPace = bars.map(\.paceSPerUnit).max() ?? 1
        let minPace = bars.map(\.paceSPerUnit).min() ?? 0
        // Plot "how much faster than your slowest split" + a base, so a FASTER split is a TALLER bar —
        // matching the pace line's up-is-faster reading right above it. The m:ss annotation carries the
        // exact value, so the inverted magnitude is never read directly.
        let base = (maxPace - minPace) * 0.4 + 4
        // Per-bar time labels only fit for shorter runs; past ~8 splits they collide into an
        // unreadable stack, so we label just the fastest split (its exact time — and every
        // other split's — lives in the SPLITS list right below). Long runs still read as the
        // shape of the effort, with your best in colour.
        let labelEvery = bars.count <= 8
        let subtitle = labelEvery ? "Per \(unitLabel) · taller is faster"
                                  : "Per \(unitLabel) · taller is faster · best in colour"
        return chartCard("Splits", subtitle: subtitle) {
            Chart(bars) { bar in
                BarMark(x: .value("Split", "\(bar.unitIndex)"),
                        y: .value("Speed", (maxPace - bar.paceSPerUnit) + base),
                        width: .ratio(0.62))
                    .foregroundStyle(bar.isBest ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.ink.opacity(0.85)))
                    .cornerRadius(4)
                    .annotation(position: .top, alignment: .center) {
                        if labelEvery || bar.isBest {
                            Text(pace(bar.paceSPerUnit)).font(.rounded(9, weight: .bold)).monospacedDigit()
                                .foregroundStyle(bar.isBest ? Theme.ink : Theme.inkSecondary)
                                .fixedSize()
                        }
                    }
            }
            .chartYAxis(.hidden)
            // Thin the axis labels so 20+ split numbers never crowd — every split for a short
            // run, roughly every 5th once the run is long.
            .chartXAxis {
                AxisMarks { value in
                    if labelEvery {
                        AxisValueLabel()
                    } else if let s = value.as(String.self), let n = Int(s),
                              n == 1 || n % 5 == 0 || n == bars.count {
                        AxisValueLabel()
                    }
                }
            }
            .frame(height: 150)
        }
    }

    // MARK: Elevation

    private func elevationCard(_ pts: [Pt], minAlt: Double) -> some View {
        chartCard("Elevation", subtitle: "\(Int(gps.elevationGainM)) m gain") {
            Chart(Array(pts.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("Distance", p.distanceM / unitMeters),
                         y: .value("Elevation", p.altitudeM - minAlt))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Theme.inkTertiary.opacity(0.18))
                LineMark(x: .value("Distance", p.distanceM / unitMeters),
                         y: .value("Elevation", p.altitudeM - minAlt))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        if let d = value.as(Double.self) { tick("\(Int(d))") }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        if let d = value.as(Double.self) { tick(d.formatted(.number.precision(.fractionLength(0)))) }
                    }
                }
            }
            .frame(height: 130)
        }
    }

    // MARK: Chrome

    private func chartCard<Content: View>(_ title: String, subtitle: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Text(title.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
                Text(subtitle).font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary.opacity(0.7))
            }
            content()
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }

    /// A small monospaced axis tick label in the app's type.
    private func tick(_ text: String) -> some View {
        Text(text).font(.rounded(9, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.inkTertiary)
    }

    // MARK: Formatting

    /// Convert stored s/km pace to the display unit (s per km or per mile).
    private func perUnit(_ sPerKm: Double) -> Double {
        distanceUnit.resolved() == .imperial ? sPerKm * (Formatters.metersPerMile / 1000) : sPerKm
    }
    private func pace(_ sPerUnit: Double) -> String {
        guard sPerUnit.isFinite, sPerUnit > 0 else { return "--" }
        let t = Int(sPerUnit.rounded())
        return "\(t / 60):\(String(format: "%02d", t % 60))"
    }
}

/// "This week" — the run in the context of its seven days, as daily distance bars (Strava's post-run
/// week strip). Anchored on the *run's* day, not today, so an old run in History reads against the week
/// it belonged to; a run just finished reads against the current week. The run's own day glints
/// iridescent — the earned accent, since this card celebrates the effort you just banked. Distance sums
/// every discipline's GPS metres (matching the Progress "distance" chart), so a cross-training day still
/// shows up. Self-contained: fetches its own window so any host that shows a run summary gets it free.
struct WeekContextCard: View {
    /// The run being summarised — its day is the last (highlighted) bar and the window's right edge.
    let anchor: Date
    /// The run's seven-day window, fetched by the host. It's injected (not fetched here) so the load
    /// runs on the host's always-present `.task`: a `.task` on this card alone never fires while the
    /// card is collapsed for want of data, and the card would then never learn it has data to show.
    var weekWorkouts: [Workout]
    var distanceUnit: DistanceUnit = .auto

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    private struct DayBar: Identifiable { let id = UUID(); let dayStart: Date; let distanceM: Double; let isAnchor: Bool }

    private var unitMeters: Double { distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000 }
    private var unitLabel: String { distanceUnit.resolved() == .imperial ? "mi" : "km" }
    private func disp(_ m: Double) -> Double { m / unitMeters }

    /// The 7-day window (ending on the run's day) the card plots — the host fetches this and passes it
    /// in. nil only if date math fails (never in practice).
    static func windowDescriptor(anchor: Date, calendar: Calendar = .current) -> FetchDescriptor<Workout>? {
        let anchorDay = calendar.startOfDay(for: anchor)
        guard let start = calendar.date(byAdding: .day, value: -6, to: anchorDay),
              let end = calendar.date(byAdding: .day, value: 1, to: anchorDay) else { return nil }
        return FetchDescriptor<Workout>(predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end })
    }

    /// Bucket the window into seven daily distances (oldest → newest); the last bucket is the run's own
    /// day. Cheap (≤ a handful of workouts, 7 buckets), so it runs inline on each body pass.
    private var days: [DayBar] {
        let calendar = Calendar.current
        let anchorDay = calendar.startOfDay(for: anchor)
        var bars: [DayBar] = []
        for i in stride(from: 6, through: 0, by: -1) {
            guard let dayStart = calendar.date(byAdding: .day, value: -i, to: anchorDay),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let dist = weekWorkouts
                .filter { $0.startedAt >= dayStart && $0.startedAt < dayEnd }
                .reduce(0.0) { $0 + ($1.gps?.distanceM ?? 0) }
            bars.append(DayBar(dayStart: dayStart, distanceM: dist, isAnchor: i == 0))
        }
        return bars
    }

    var body: some View {
        Group {
            // Need at least two active days for a "week" to mean anything — a lone bar is just the run
            // we're already looking at, so the card would add nothing.
            if days.filter({ $0.distanceM > 0 }).count >= 2 {
                let maxDist = days.map { disp($0.distanceM) }.max() ?? 0
                let total = days.reduce(0) { $0 + $1.distanceM }
                let anchorDate = days.first(where: \.isAnchor)?.dayStart
                card(total: total) {
                    Chart(days) { d in
                        BarMark(x: .value("Day", d.dayStart, unit: .day),
                                y: .value("Distance", animate ? disp(d.distanceM) : 0),
                                width: .fixed(20))
                            .foregroundStyle(d.isAnchor ? AnyShapeStyle(IridescentMaterial())
                                                        : AnyShapeStyle(Theme.ink.opacity(0.18)))
                            .cornerRadius(3)
                            .annotation(position: .top, spacing: 4) {
                                if animate, d.isAnchor, disp(d.distanceM) > 0 {
                                    let v = disp(d.distanceM)
                                    Text(v >= 10 ? "\(Int(v.rounded()))" : String(format: "%.1f", v))
                                        .font(.rounded(9, weight: .bold)).monospacedDigit()
                                        .foregroundStyle(Theme.ink).fixedSize()
                                }
                            }
                    }
                    .chartXScale(domain: xDomain)
                    .chartYScale(domain: 0...max(1, maxDist * 1.2))
                    .chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { value in
                            AxisValueLabel {
                                if let d = value.as(Date.self) {
                                    Text(d, format: .dateTime.weekday(.narrow))
                                        .font(.rounded(9, weight: d == anchorDate ? .bold : .semibold))
                                        .foregroundStyle(d == anchorDate ? Theme.ink : Theme.inkTertiary)
                                }
                            }
                        }
                    }
                    .frame(height: 118)
                    .accessibilityLabel("This week's distance by day, with this run's day highlighted")
                }
                .task { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { animate = true } }
            }
        }
    }

    /// Half-a-day of padding on each edge so the first/last bars aren't clipped by the plot frame.
    private var xDomain: ClosedRange<Date> {
        guard let lo = days.first?.dayStart, let hi = days.last?.dayStart, lo <= hi else {
            return anchor...anchor.addingTimeInterval(1)
        }
        return lo.addingTimeInterval(-12 * 3600)...hi.addingTimeInterval(12 * 3600)
    }

    private func card<Content: View>(total: Double, @ViewBuilder _ content: () -> Content) -> some View {
        let miles = disp(total)
        let totalStr = miles >= 10 ? "\(Int(miles.rounded()))" : String(format: "%.1f", miles)
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Text("THIS WEEK").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
                Text("\(totalStr) \(unitLabel) total").font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary.opacity(0.7))
            }
            content()
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }
}
