import SwiftUI
import Charts

/// Post-run analysis charts (running-excellence R2) — the "pro" layer over the text splits: a
/// pace-over-distance line, an elevation profile, and a per-split bar chart. Pure read of the stored
/// GPS `samples` + computed splits; no engine changes. Monochrome marks, iridescence reserved for the
/// fastest split (earned = your best). Honors Reduce Motion. Reused by the summary + history detail.
struct RunAnalysisSection: View {
    let gps: GPSDetail
    let type: WorkoutType
    var distanceUnit: DistanceUnit = .auto

    private var unitMeters: Double { distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000 }
    private var unitLabel: String { distanceUnit.resolved() == .imperial ? "mi" : "km" }

    // MARK: Derived series

    private struct Pt { let t: TimeInterval; let distanceM: Double; let altitudeM: Double; let paceSPerKm: Double }

    /// Accepted fixes reduced to cumulative distance + altitude + instantaneous pace.
    private var points: [Pt] {
        let accepted = gps.samples.filter(\.accepted).sorted { $0.t < $1.t }
        guard let first = accepted.first else { return [] }
        var out: [Pt] = []
        var cumulative = 0.0
        var prev: LocationSample?
        for s in accepted {
            if let p = prev {
                cumulative += Geo.distance(lat1: p.lat, lon1: p.lon, lat2: s.lat, lon2: s.lon)
            }
            // Ignore near-stopped fixes for pace (they'd spike the line); 0 = "no pace here".
            let pace = s.speedMS > 0.4 ? 1000 / s.speedMS : 0
            out.append(Pt(t: s.t.timeIntervalSince(first.t), distanceM: cumulative, altitudeM: s.altitudeM, paceSPerKm: pace))
            prev = s
        }
        return out
    }

    /// Evenly thin a long trace so the charts stay smooth (keeps endpoints).
    private func thinned(_ pts: [Pt], to max: Int = 200) -> [Pt] {
        guard pts.count > max, max > 2 else { return pts }
        let stride = Double(pts.count - 1) / Double(max - 1)
        return (0..<max).map { pts[Int((Double($0) * stride).rounded())] }
    }

    private struct SplitBar: Identifiable { let id: Int; let unitIndex: Int; let paceSPerUnit: Double; let isBest: Bool }

    private var splitBars: [SplitBar] {
        let splits = CardioMetrics.splits(points.map { .init(t: $0.t, cumulativeM: $0.distanceM) }, unitMeters: unitMeters)
        let full = splits.filter { !$0.isPartial }
        // Fastest full split earns the iridescent bar.
        let bestPace = full.map { $0.durationS / ($0.distanceM / unitMeters) }.min()
        return splits.map { s in
            let pace = s.durationS / max(1, s.distanceM / unitMeters)
            let isBest = !s.isPartial && bestPace.map { abs(pace - $0) < 0.5 } == true
            return SplitBar(id: s.index, unitIndex: s.index + 1, paceSPerUnit: pace, isBest: isBest)
        }
    }

    // MARK: Body

    var body: some View {
        let pts = thinned(points)
        let hasPace = pts.contains { $0.paceSPerKm > 0 }
        let altitudes = pts.map(\.altitudeM)
        let elevRange = (altitudes.max() ?? 0) - (altitudes.min() ?? 0)
        let bars = splitBars

        if pts.count >= 4 {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                if hasPace, type != .ride { paceCard(pts) }
                if bars.count >= 2, type != .ride { splitsCard(bars) }
                if elevRange > 4 { elevationCard(pts, minAlt: altitudes.min() ?? 0) }
            }
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
        return chartCard("Splits", subtitle: "Per \(unitLabel) · taller is faster") {
            Chart(bars) { bar in
                BarMark(x: .value("Split", "\(bar.unitIndex)"),
                        y: .value("Speed", (maxPace - bar.paceSPerUnit) + base),
                        width: .ratio(0.62))
                    .foregroundStyle(bar.isBest ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.ink.opacity(0.85)))
                    .cornerRadius(4)
                    .annotation(position: .top, alignment: .center) {
                        Text(pace(bar.paceSPerUnit)).font(.rounded(9, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Theme.inkSecondary)
                    }
            }
            .chartYAxis(.hidden)
            .chartXAxis { AxisMarks { _ in AxisValueLabel() } }
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
