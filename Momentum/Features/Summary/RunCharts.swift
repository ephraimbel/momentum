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
    /// One Strava-style split row: "1 · 9:41 · bar". `label` is the unit ordinal for full splits
    /// ("1", "2") and the fraction for the closing partial ("0.4").
    private struct SplitRow: Identifiable {
        let id: Int; let label: String; let paceSPerUnit: Double; let isBest: Bool; let isPartial: Bool
    }

    /// The chart series, derived from the GPS samples ONCE. Reducing accepted fixes to cumulative
    /// distance runs a haversine per sample; the old computed-property form recomputed it 2–3× on
    /// every `body` pass (thinned points, splits, HR), and `body` re-evaluates through the reveal
    /// cascade and when Health HR backfills. For a long run that re-walk of thousands of samples on
    /// the main thread is exactly the post-run stutter this caches away.
    private struct Derived { var pts: [Pt]; var hr: [HRPt]; var rows: [SplitRow]; var avgPaceSPerKm: Double? }
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

    private static func compute(gps: GPSDetail, type: WorkoutType,
                                health: [(date: Date, bpm: Double)], unitMeters: Double) -> Derived {
        // Points: the canonical engine-consistent replay (`GPSDetail.routePoints`) — moving seconds
        // and the same distance the headline reports, so these charts and the splits below can no
        // longer disagree with the run they describe.
        let pts: [Pt] = gps.routePoints(type: type).map {
            Pt(t: $0.t, distanceM: $0.cumulativeM, altitudeM: $0.altitudeM,
               paceSPerKm: $0.speedMS > 0.4 ? 1000 / $0.speedMS : 0)   // near-stopped → 0 = "no pace here"
        }
        // HR: prefer our own live series; fall back to Apple Health for Watch/imported runs.
        let local = gps.hrSamples.filter { $0.bpm > 0 }.sorted { $0.t < $1.t }.map { (date: $0.t, bpm: Double($0.bpm)) }
        let readings = local.count >= 4 ? local : health.sorted { $0.date < $1.date }
        var hr: [HRPt] = []
        if let firstHR = readings.first {
            hr = readings.map { HRPt(t: $0.date.timeIntervalSince(firstHR.date), bpm: Int($0.bpm.rounded())) }
        }
        // Splits, Strava-style: every full unit, plus the closing partial once it's long enough
        // for its pace to mean something (a 60 m tail normalised to a per-mile pace is noise).
        let splits = CardioMetrics.splits(pts.map { .init(t: $0.t, cumulativeM: $0.distanceM) }, unitMeters: unitMeters)
        let full = splits.filter { !$0.isPartial }
        let bestPace = full.map { $0.durationS / ($0.distanceM / unitMeters) }.min()
        var rows = full.map { s -> SplitRow in
            let pace = s.durationS / max(1, s.distanceM / unitMeters)
            let isBest = bestPace.map { abs(pace - $0) < 0.5 } == true
            return SplitRow(id: s.index, label: "\(s.index + 1)", paceSPerUnit: pace, isBest: isBest, isPartial: false)
        }
        if let partial = splits.last, partial.isPartial, partial.distanceM >= unitMeters * 0.15 {
            let fraction = partial.distanceM / unitMeters
            rows.append(SplitRow(id: partial.index, label: String(format: "%.1f", fraction),
                                 paceSPerUnit: partial.durationS / (partial.distanceM / unitMeters),
                                 isBest: false, isPartial: true))
        }
        // The run's average pace over MOVING time, from the same replay the charts plot — so the
        // headline number and the line it sits over can never disagree.
        var avg: Double?
        if let last = pts.last, last.distanceM > 50, last.t > 0 {
            avg = last.t / (last.distanceM / 1000)
        }
        return Derived(pts: Self.thinned(pts), hr: Self.thinned(hr), rows: rows, avgPaceSPerKm: avg)
    }

    // MARK: Body

    var body: some View {
        ZStack {
            // A zero-size anchor so the `.task` below always runs. `derived` starts nil, so without
            // it this view is EMPTY on first render — and a lifecycle modifier on an empty view
            // never fires, so the task that fills `derived` never ran and the whole section (pace,
            // splits, heart rate, elevation) silently rendered nothing on every run. The same trap
            // is called out and anchored the same way in `TimeInZonesCard`.
            Color.clear.frame(width: 0, height: 0)
            if let d = derived {
                let pts = d.pts
                let hasPace = pts.contains { $0.paceSPerKm > 0 }
                let altitudes = pts.map(\.altitudeM)
                let elevRange = (altitudes.max() ?? 0) - (altitudes.min() ?? 0)
                if pts.count >= 4 || d.hr.count >= 4 {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        if pts.count >= 4 {
                            // Each discipline reads in its own currency (2026-08-13): a run in
                            // pace, a ride in speed. Cycling used to drop the pace AND splits
                            // cards entirely, leaving rides with only HR + elevation.
                            if hasPace {
                                if type.isCycling { speedCard(pts, avgSPerKm: d.avgPaceSPerKm) }
                                else { paceCard(pts, avgSPerKm: d.avgPaceSPerKm) }
                            }
                            if d.rows.contains(where: { !$0.isPartial }) { splitsCard(d.rows) }
                        }
                        if d.hr.count >= 4 { hrCard(d.hr) }
                        if pts.count >= 4, elevRange > 4 { elevationCard(pts, minAlt: altitudes.min() ?? 0) }
                    }
                }
            }
        }
        .task(id: derivedKey) {
            derived = Self.compute(gps: gps, type: type, health: healthHRSeries, unitMeters: unitMeters)
        }
    }

    // MARK: Heart rate over time

    private func hrCard(_ hr: [HRPt]) -> some View {
        let avg = gps.avgHR ?? RunSignals.mean(hr.map(\.bpm))
        let floorBPM = Double(hr.map(\.bpm).min() ?? 0)
        let xs = hr.map { $0.t / 60 }
        // XY hoisted out of the per-tick closure — see paceCard.
        let xy = hr.enumerated().map { XY(id: $0.offset, x: $0.element.t / 60, y: Double($0.element.bpm)) }
        return chartCard("Heart rate", subtitle: avg.map { "avg \($0) bpm" } ?? "bpm over time") {
            RunScrubHost(xs: xs) { pinned in
                hrChart(xy, avg: avg, floorBPM: floorBPM, pinned: pinned)
            }
            .accessibilityLabel("Heart rate over time" + (avg.map { ", average \($0) beats per minute" } ?? ""))
        }
    }

    private func hrChart(_ xy: [XY], avg: Int?, floorBPM: Double, pinned: Double?) -> some View {
        // Resolved OUTSIDE the ChartContentBuilder — a min(by:) search inside the builder is
        // exactly the expression shape that times out the type-checker.
        let avgY: Double? = avg.map(Double.init)
        let pin: (x: Double, value: String, label: String)? = pinned.flatMap { pinX in
            xy.min(by: { abs($0.x - pinX) < abs($1.x - pinX) })
                .map { (pinX, "\(Int($0.y.rounded())) bpm", minuteLabel($0.x * 60)) }
        }
        return Chart {
            floorAreaMarks(xy, floor: floorBPM)
            traceMarks(xy, color: Theme.ink, width: 2)
            if let avgY { avgRule(avgY) }
            if let pin { scrubMark(x: pin.x, value: pin.value, label: pin.label) }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis { intAxis }
        .chartXAxis { minuteAxis }
        .frame(height: 150)
    }

    /// A plot-ready point: all unit/axis arithmetic done BEFORE the chart, because inline math in
    /// a ChartContentBuilder ForEach is what times out the type-checker (three build failures'
    /// worth of lesson, 2026-08-13).
    private struct XY: Identifiable { let id: Int; let x: Double; let y: Double }

    /// The filled body under a line (Strava's reading): area from the chart floor to the trace,
    /// so effort reads as mass, not just an outline.
    private func floorAreaMarks(_ pts: [XY], floor: Double) -> some ChartContent {
        ForEach(pts) { p in
            AreaMark(x: .value("X", p.x),
                     yStart: .value("Floor", floor),
                     yEnd: .value("Y", p.y))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Self.areaFill)
        }
    }

    private func groundAreaMarks(_ pts: [XY]) -> some ChartContent {
        ForEach(pts) { p in
            AreaMark(x: .value("X", p.x), y: .value("Y", p.y))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Self.areaFill)
        }
    }

    private func traceMarks(_ pts: [XY], color: Color, width: CGFloat) -> some ChartContent {
        ForEach(pts) { p in
            LineMark(x: .value("X", p.x), y: .value("Y", p.y))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }

    // MARK: Pace over distance

    private func paceCard(_ pts: [Pt], avgSPerKm: Double?) -> some View {
        let paced = pts.filter { $0.paceSPerKm > 0 }
        // The average leads the card as a real number (the HR card already does this with "avg
        // bpm") — the line shows the shape of the effort, the number is what the athlete quotes.
        let subtitle = avgSPerKm.map { "avg \(pace(perUnit($0))) /\(unitLabel)" } ?? "Per \(unitLabel) over distance"
        // The y-axis is reversed (faster reads higher), so the chart's visual floor is the
        // SLOWEST pace — the area fills from there up to the line.
        let slowest = paced.map { perUnit($0.paceSPerKm) }.max() ?? 0
        let xs = paced.map { $0.distanceM / unitMeters }
        // XY built ONCE per card, OUTSIDE the scrub closure — the closure re-runs on every scrub
        // tick, and rebuilding ~200 plot structs (plus a full-series pace scan for the pin) per
        // tick was real drag cost (perf audit 2026-08-13). The pin resolves from the same xy:
        // its y IS the display value.
        let xy = paced.enumerated().map { XY(id: $0.offset, x: $0.element.distanceM / unitMeters,
                                             y: perUnit($0.element.paceSPerKm)) }
        return chartCard("Pace", subtitle: subtitle) {
            RunScrubHost(xs: xs) { pinned in
                paceChart(xy, avgSPerKm: avgSPerKm, slowest: slowest, pinned: pinned)
            }
        }
    }

    private func paceChart(_ xy: [XY], avgSPerKm: Double?, slowest: Double, pinned: Double?) -> some View {
        // Resolved outside the builder — see hrChart.
        let avgY: Double? = avgSPerKm.map(perUnit)
        let pin: (x: Double, value: String, label: String)? = pinned.flatMap { pinX in
            xy.min(by: { abs($0.x - pinX) < abs($1.x - pinX) })
                .map { (pinX, "\(pace($0.y)) /\(unitLabel)", distanceLabel(pinX)) }
        }
        return Chart {
            // The reversed y-axis puts the SLOWEST pace at the visual floor — the area fills
            // from there up to the line, i.e. visually beneath it.
            floorAreaMarks(xy, floor: slowest)
            traceMarks(xy, color: Theme.ink, width: 2)
            if let avgY { avgRule(avgY) }
            if let pin { scrubMark(x: pin.x, value: pin.value, label: pin.label) }
        }
        // Faster (lower s/unit) reads higher — the intuitive "up = better".
        .chartYScale(domain: .automatic(includesZero: false, reversed: true))
        .chartYAxis { paceAxis }
        .chartXAxis { distanceAxis }
        .frame(height: 150)
    }

    // MARK: Speed over distance (rides)

    /// The ride twin of the pace card, read in the unit a cyclist actually quotes (mph / km/h).
    /// Pace's reversed axis makes no sense here — faster already reads higher — so the area fills
    /// from the slowest moving speed and the dashed rule is the ride's overall moving speed.
    private var speedUnitLabel: String { distanceUnit.resolved() == .imperial ? "mph" : "km/h" }
    private func speedPerHour(_ paceSPerUnit: Double) -> Double {
        guard paceSPerUnit > 0 else { return 0 }
        return 3600 / paceSPerUnit
    }
    private func speedString(_ unitPerH: Double) -> String {
        guard unitPerH.isFinite, unitPerH > 0 else { return "--" }
        return unitPerH.formatted(.number.precision(.fractionLength(1)))
    }

    private func speedCard(_ pts: [Pt], avgSPerKm: Double?) -> some View {
        let paced = pts.filter { $0.paceSPerKm > 0 }
        let avgSpeed = avgSPerKm.map { speedPerHour(perUnit($0)) }
        let subtitle = avgSpeed.map { "avg \(speedString($0)) \(speedUnitLabel)" } ?? "\(speedUnitLabel) over distance"
        let slowest = paced.map { speedPerHour(perUnit($0.paceSPerKm)) }.min() ?? 0
        let xs = paced.map { $0.distanceM / unitMeters }
        // XY hoisted out of the per-tick closure — see paceCard.
        let xy = paced.enumerated().map { XY(id: $0.offset, x: $0.element.distanceM / unitMeters,
                                             y: speedPerHour(perUnit($0.element.paceSPerKm))) }
        return chartCard("Speed", subtitle: subtitle) {
            RunScrubHost(xs: xs) { pinned in
                speedChart(xy, avgSpeed: avgSpeed, slowest: slowest, pinned: pinned)
            }
            .accessibilityLabel("Speed over distance" + (avgSpeed.map { ", average \(speedString($0)) \(speedUnitLabel)" } ?? ""))
        }
    }

    private func speedChart(_ xy: [XY], avgSpeed: Double?, slowest: Double, pinned: Double?) -> some View {
        // Resolved outside the builder — see hrChart.
        let pin: (x: Double, value: String, label: String)? = pinned.flatMap { pinX in
            xy.min(by: { abs($0.x - pinX) < abs($1.x - pinX) })
                .map { (pinX, "\(speedString($0.y)) \(speedUnitLabel)", distanceLabel(pinX)) }
        }
        return Chart {
            floorAreaMarks(xy, floor: slowest)
            traceMarks(xy, color: Theme.ink, width: 2)
            if let avgSpeed { avgRule(avgSpeed) }
            if let pin { scrubMark(x: pin.x, value: pin.value, label: pin.label) }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis { intAxis }
        .chartXAxis { distanceAxis }
        .frame(height: 150)
    }

    // MARK: Splits

    private func splitsCard(_ rows: [SplitRow]) -> some View {
        // Strava's reading: one row per unit — ordinal, exact pace, and a bar whose LENGTH is
        // speed (fastest split = full width), so the eye gets the shape and the number in the
        // same glance. The closing partial rides along in tertiary with its fraction as the
        // label. Replaces the old vertical bar chart, whose inverted "taller is faster" scale
        // needed a caption to explain itself and only labeled every bar on short runs.
        let fastest = rows.map(\.paceSPerUnit).min() ?? 1
        return chartCard("Splits", subtitle: "Per \(unitLabel) · best in colour") {
            VStack(spacing: 7) {
                ForEach(rows) { row in
                    HStack(spacing: Theme.Space.sm) {
                        Text(row.label)
                            .font(.rounded(11, weight: row.isPartial ? .semibold : .bold)).monospacedDigit()
                            .foregroundStyle(row.isPartial ? Theme.inkTertiary : Theme.inkSecondary)
                            .frame(width: 26, alignment: .trailing)
                        // Rides read their splits in speed — the same bar, the cyclist's number.
                        Text(type.isCycling ? speedString(speedPerHour(row.paceSPerUnit)) : pace(row.paceSPerUnit))
                            .font(.rounded(12, weight: .bold)).monospacedDigit()
                            .foregroundStyle(row.isPartial ? Theme.inkSecondary : Theme.ink)
                            .frame(width: 44, alignment: .trailing)
                        GeometryReader { geo in
                            Capsule()
                                .fill(row.isBest ? AnyShapeStyle(IridescentMaterial())
                                                 : AnyShapeStyle(Theme.ink.opacity(row.isPartial ? 0.22 : 0.55)))
                                .frame(width: max(10, geo.size.width * (fastest / max(row.paceSPerUnit, 1))))
                        }
                        .frame(height: 10)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.isPartial ? "Final \(row.label)" : "\(unitLabel == "mi" ? "Mile" : "Kilometre") \(row.label)"), \(type.isCycling ? "\(speedString(speedPerHour(row.paceSPerUnit))) \(speedUnitLabel)" : "\(pace(row.paceSPerUnit)) per \(unitLabel)")\(row.isBest ? ", fastest" : "")")
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: Elevation

    private func elevationCard(_ pts: [Pt], minAlt: Double) -> some View {
        // Axis in the athlete's unit (feet for imperial) — raw metres on an unlabeled axis read
        // as whatever the athlete assumes, which for the US market was wrong.
        let yScale = distanceUnit.resolved() == .imperial ? Formatters.feetPerMeter : 1
        let unitName = distanceUnit.resolved() == .imperial ? "ft" : "m"
        let xs = pts.map { $0.distanceM / unitMeters }
        // XY hoisted out of the per-tick closure — see paceCard.
        let xy = pts.enumerated().map { XY(id: $0.offset, x: $0.element.distanceM / unitMeters,
                                           y: ($0.element.altitudeM - minAlt) * yScale) }
        return chartCard("Elevation", subtitle: "\(Formatters.elevation(meters: gps.elevationGainM, unit: distanceUnit)) gain") {
            RunScrubHost(xs: xs) { pinned in
                elevationChart(xy, unitName: unitName, pinned: pinned)
            }
        }
    }

    private func elevationChart(_ xy: [XY], unitName: String, pinned: Double?) -> some View {
        // Resolved outside the builder — see hrChart.
        let pin: (x: Double, value: String, label: String)? = pinned.flatMap { pinX in
            xy.min(by: { abs($0.x - pinX) < abs($1.x - pinX) })
                .map { (pinX, "\(Int($0.y.rounded())) \(unitName)", distanceLabel(pinX)) }
        }
        return Chart {
            groundAreaMarks(xy)
            traceMarks(xy, color: Theme.inkSecondary, width: 1.5)
            if let pin { scrubMark(x: pin.x, value: pin.value, label: pin.label) }
        }
        .chartYAxis { intAxis }
        .chartXAxis { distanceAxis }
        .frame(height: 150)
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

    /// The one fill every run chart's area wears — ink fading down, so the mass reads without
    /// competing with the line.
    private static let areaFill = LinearGradient(
        colors: [Theme.ink.opacity(0.10), Theme.ink.opacity(0.02)],
        startPoint: .top, endPoint: .bottom)

    /// The dashed average reference every run chart draws — the number the athlete quotes,
    /// visible against the shape of the effort.
    private func avgRule(_ y: Double) -> some ChartContent {
        RuleMark(y: .value("Average", y))
            .foregroundStyle(Theme.inkSecondary.opacity(0.35))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
    }

    // MARK: Shared axes — one grammar for every run chart.

    private var intAxis: some AxisContent {
        AxisMarks { value in
            AxisGridLine().foregroundStyle(Theme.hairline)
            AxisValueLabel {
                if let d = value.as(Double.self) { tick("\(Int(d))") }
            }
        }
    }
    private var paceAxis: some AxisContent {
        AxisMarks { value in
            AxisGridLine().foregroundStyle(Theme.hairline)
            AxisValueLabel {
                if let d = value.as(Double.self) { tick(pace(d)) }
            }
        }
    }
    private var distanceAxis: some AxisContent {
        AxisMarks { value in
            AxisGridLine().foregroundStyle(Theme.hairline)
            AxisValueLabel {
                if let d = value.as(Double.self) { tick(d.formatted(.number.precision(.fractionLength(0)))) }
            }
        }
    }
    private var minuteAxis: some AxisContent {
        AxisMarks { value in
            AxisGridLine().foregroundStyle(Theme.hairline)
            AxisValueLabel {
                // Minute marks in runner's notation (12′), never "m" (reads as meters).
                if let d = value.as(Double.self) { tick("\(Int(d))′") }
            }
        }
    }

    /// The scrub cursor + callout — same grammar as the Trends charts' `TrendScrub.mark`, on the
    /// run charts' numeric axes (distance / minutes) instead of dates.
    private func scrubMark(x: Double, value: String, label: String) -> some ChartContent {
        RuleMark(x: .value("Selected", x))
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

    /// "mi 2.3" / "km 4.1" — the scrub caption on distance-axis charts.
    private func distanceLabel(_ x: Double) -> String {
        "\(unitLabel) \(x.formatted(.number.precision(.fractionLength(1))))"
    }
    /// "at 12:34" — the scrub caption on the time-axis HR chart.
    private func minuteLabel(_ t: TimeInterval) -> String {
        "at \(Formatters.duration(s: t))"
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
    /// What the week's bars measure — every discipline reads its own currency (2026-08-13):
    /// cardio sums GPS distance; strength sums working-set tonnage. One card, one look.
    enum Metric { case distance, volume }

    /// The workout being summarised — its day is the last (highlighted) bar and the window's right edge.
    let anchor: Date
    /// The workout's seven-day window, fetched by the host. It's injected (not fetched here) so the load
    /// runs on the host's always-present `.task`: a `.task` on this card alone never fires while the
    /// card is collapsed for want of data, and the card would then never learn it has data to show.
    var weekWorkouts: [Workout]
    var distanceUnit: DistanceUnit = .auto
    var metric: Metric = .distance
    var weightUnit: WeightUnit = .default()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    /// `raw` is the metric's SI value for the day (metres or kilograms). `idx` (0…6, oldest →
    /// newest) is the bar's x position — the chart plots INDEXES, not dates (see the chart note).
    private struct DayBar: Identifiable { let id = UUID(); let idx: Int; let dayStart: Date; let raw: Double; let isAnchor: Bool }

    private var unitMeters: Double { distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000 }
    private var unitLabel: String {
        switch metric {
        case .distance: return distanceUnit.resolved() == .imperial ? "mi" : "km"
        case .volume: return weightUnit == .lb ? "lb" : "kg"
        }
    }
    private func disp(_ raw: Double) -> Double {
        switch metric {
        case .distance: return raw / unitMeters
        case .volume: return weightUnit == .lb ? raw * Formatters.lbPerKg : raw
        }
    }
    /// A day's SI value under the chosen metric.
    private func rawValue(_ w: Workout) -> Double {
        switch metric {
        case .distance: return w.gps?.distanceM ?? 0
        case .volume: return w.strength?.totalVolumeKg ?? 0
        }
    }
    /// Bar/total numeral — tonnage runs four to five digits, so it reads compact ("12.4k").
    private func fmt(_ v: Double) -> String {
        switch metric {
        case .distance: return v >= 10 ? "\(Int(v.rounded()))" : String(format: "%.1f", v)
        case .volume: return v >= 1000 ? String(format: "%.1fk", v / 1000) : "\(Int(v.rounded()))"
        }
    }

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
            let total = weekWorkouts
                .filter { $0.startedAt >= dayStart && $0.startedAt < dayEnd }
                .reduce(0.0) { $0 + rawValue($1) }
            bars.append(DayBar(idx: bars.count, dayStart: dayStart, raw: total, isAnchor: i == 0))
        }
        return bars
    }

    var body: some View {
        Group {
            // Need at least two active days for a "week" to mean anything — a lone bar is just the run
            // we're already looking at, so the card would add nothing.
            if days.filter({ $0.raw > 0 }).count >= 2 {
                let maxDist = days.map { disp($0.raw) }.max() ?? 0
                let total = days.reduce(0) { $0 + $1.raw }
                card(total: total) {
                    // Plotted on a plain INDEX axis, not dates (2026-08-14): date bands put each
                    // bar at the band's centre (noon) while the domain ended at the last
                    // midnight+12h, so the anchor bar clipped at the edge and every weekday
                    // letter sat half a bar off. Integer x-positions with labels AT those same
                    // integers make bar and letter alignment exact by construction.
                    Chart(days) { d in
                        BarMark(x: .value("Day", d.idx),
                                y: .value("Total", animate ? disp(d.raw) : 0),
                                width: .fixed(20))
                            .foregroundStyle(d.isAnchor ? AnyShapeStyle(IridescentMaterial())
                                                        : AnyShapeStyle(Theme.ink.opacity(0.18)))
                            .cornerRadius(3)
                            .annotation(position: .top, spacing: 4) {
                                if animate, d.isAnchor, disp(d.raw) > 0 {
                                    Text(fmt(disp(d.raw)))
                                        .font(.rounded(9, weight: .bold)).monospacedDigit()
                                        .foregroundStyle(Theme.ink).fixedSize()
                                }
                            }
                    }
                    .chartXScale(domain: -0.5...6.5)
                    .chartYScale(domain: 0...max(1, maxDist * 1.2))
                    .chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks(values: Array(0...6)) { value in
                            AxisValueLabel {
                                if let i = value.as(Int.self), let d = days.first(where: { $0.idx == i }) {
                                    Text(d.dayStart, format: .dateTime.weekday(.narrow))
                                        .font(.rounded(9, weight: d.isAnchor ? .bold : .semibold))
                                        .foregroundStyle(d.isAnchor ? Theme.ink : Theme.inkTertiary)
                                }
                            }
                        }
                    }
                    .frame(height: 118)
                    .accessibilityLabel(metric == .distance
                        ? "This week's distance by day, with this run's day highlighted"
                        : "This week's training volume by day, with this session's day highlighted")
                }
                .task { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { animate = true } }
            }
        }
    }

    private func card<Content: View>(total: Double, @ViewBuilder _ content: () -> Content) -> some View {
        let totalStr = fmt(disp(total))
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

// MARK: - Scrub host for numeric-axis charts

/// The Trends charts scrub with `ScrubChartHost` (Date-keyed); the run charts plot distance and
/// minutes, so this is its Double-keyed twin — the identical tap/drag state machine, isolated per
/// card for the same reason (a drag must re-render one chart, not the whole summary cascade).
private struct RunScrubState {
    var pinned: Double?
    private var dragging = false
    private var pendingClear = false

    mutating func handle(_ raw: Double?, xs: [Double]) {
        if let raw, let snapped = xs.min(by: { abs($0 - raw) < abs($1 - raw) }) {
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
}

private struct RunScrubHost<ChartView: View>: View {
    let xs: [Double]
    @ViewBuilder let chart: (Double?) -> ChartView
    @State private var scrub = RunScrubState()

    /// Compact change key — `.onChange(of: xs)` diffed the full ~200-element array on every body
    /// pass of every scrub tick (perf audit 2026-08-13). Count + endpoints move whenever the
    /// series really changes (unit flip, HR backfill, re-derive).
    private var xsToken: Int {
        var h = Hasher()
        h.combine(xs.count); h.combine(xs.first ?? 0); h.combine(xs.last ?? 0)
        return h.finalize()
    }

    var body: some View {
        chart(scrub.pinned)
            .chartXSelection(value: Binding(get: { scrub.pinned },
                                            set: { scrub.handle($0, xs: xs) }))
            .onChange(of: xsToken) { scrub = .init() }
    }
}
