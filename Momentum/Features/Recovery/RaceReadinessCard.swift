import SwiftUI

/// "RACE DAY FORM" — the race-day projection card (docs/RECOVERY-HUB-PLAN.md §11.1.2): where the
/// taper is actually headed, read from `RaceProjection` (actual loads + the plan's remaining
/// prescriptions through the one CTL/ATL model). The race name, days to go, the projected TSB
/// numeral with its band verdict, and a mini sparkline of the projected Form path from today to
/// race morning.
///
/// Mounting: the integrator renders this in `HealthSegmentView`'s proCluster only when
/// `RaceProjection.build(workouts:plan:)` returns non-nil (dated race ≥ 3 days out) — the card
/// itself takes a resolved projection and never gates.
///
/// Doctrine notes (§6): Form wears the recovery domain's mint ink; the path is DASHED because it
/// is a forecast — a projection never impersonates measured data (the BalanceCard ghost-bar rule).
/// No iridescence: a projection is information, not an earned moment. Reduce Motion renders the
/// path complete behind a plain fade.
struct RaceReadinessCard: View {
    let projection: RaceProjection.Projection
    /// The plan's own name for the block ("Austin Marathon"); empty falls back to "Race day".
    var raceName: String = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var dotShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            // One spoken sentence for the story; the footer's ⓘ stays its own reachable element.
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                header
                heroLine
                sparkline
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11yLine)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer
        }
        .healthCard()
        .onAppear(perform: reveal)
    }

    // MARK: Header — the label, the race, the countdown

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RACE DAY FORM")
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Text(displayName)
                    .font(.rounded(Theme.FontSize.headline, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.sm)
                Text("in \(projection.daysToRace) days")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
    }

    // MARK: Hero — the projected numeral + the band verdict

    private var heroLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text(signedTSB)
                .font(.display(34, weight: .bold)).monospacedDigit()
                .foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 1) {
                Text(bandPhrase)
                    .font(.rounded(Theme.FontSize.caption, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("Projected form on race morning")
                    .font(.rounded(Theme.FontSize.label, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
    }

    // MARK: Sparkline — the projected TSB path, today → race morning

    private var sparkline: some View {
        let tsb = projection.series.map(\.tsb)
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            GeometryReader { geo in
                let unit = unitPoints(tsb)
                if unit.count > 1 {
                    // Zero line first — "above zero by race morning" is the read; 1px solid
                    // hairline, never dashed (§5 global chart rules; the DATA is what's dashed).
                    Path { p in
                        let y = zeroY * geo.size.height
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Theme.hairline, lineWidth: 1)

                    // The projected Form path — mint ink, dashed (a forecast, not a measurement).
                    SparkPath(unit: unit)
                        .trim(from: 0, to: revealed ? 1 : 0)
                        .stroke(Theme.Health.recoveryInk,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                   lineJoin: .round, dash: [4, 4]))

                    // The race-day dot: ≥8pt end mark with a 2pt surface ring (§5), popping last.
                    if let last = unit.last {
                        let pt = CGPoint(x: last.x * geo.size.width, y: last.y * geo.size.height)
                        // Transforms before `.position` so the pop scales around the dot itself.
                        Circle().fill(Theme.surface).frame(width: 12, height: 12)
                            .opacity(dotShown ? 1 : 0)
                            .position(pt)
                        Circle().fill(Theme.Health.recoveryInk).frame(width: 8, height: 8)
                            .scaleEffect(dotShown ? 1 : 0.4)
                            .opacity(dotShown ? 1 : 0)
                            .position(pt)
                    }
                }
            }
            .frame(height: 48)
            HStack {
                Text("TODAY")
                    .font(.rounded(9, weight: .bold)).tracking(1)
                    .foregroundStyle(Theme.inkTertiary)
                Spacer()
                Text(projection.raceDay.formatted(.dateTime.month(.abbreviated).day()).uppercased())
                    .font(.rounded(9, weight: .bold)).tracking(1).monospacedDigit()
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        .accessibilityHidden(true)   // the card's combined label carries the story
    }

    // MARK: Footer — education, always free

    private var footer: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Text("Form is fitness minus fatigue — the taper's job is to lift it above zero by race morning.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.sm)
            MetricInfoButton(explainer: MetricExplainers.fitnessFreshness)
        }
    }

    // MARK: Copy

    private var displayName: String {
        let trimmed = raceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Race day" : trimmed
    }

    /// "+12" / "0" / "−6" — a true minus sign, never a hyphen.
    private var signedTSB: String {
        let value = Int(projection.tsb.rounded())
        if value > 0 { return "+\(value)" }
        if value < 0 { return "−\(abs(value))" }
        return "0"
    }

    /// The band verdict, no-shame in every direction — "heavy" is an observation about the plan's
    /// remaining loads, never a failure state.
    private var bandPhrase: String {
        switch projection.band {
        case .fresh: "Arriving fresh"
        case .ready: "Arriving ready"
        case .heavy: "This taper isn't tapering yet"
        }
    }

    private var a11yLine: String {
        let spoken = signedTSB.replacingOccurrences(of: "+", with: "plus ")
            .replacingOccurrences(of: "−", with: "minus ")
        return "Race day form. \(displayName), in \(projection.daysToRace) days. Projected \(spoken) — \(bandPhrase)."
    }

    // MARK: Geometry

    /// Series TSB → unit-space points (0…1 both axes). The y-domain always includes zero — the
    /// zero line is the chart's whole pedagogy — with a whisper of padding so the path never
    /// kisses the card edge.
    private func unitPoints(_ values: [Double]) -> [CGPoint] {
        let v = values.filter(\.isFinite)
        guard v.count > 1, let rawLo = v.min(), let rawHi = v.max() else { return [] }
        let lo = min(rawLo, 0.0), hi = max(rawHi, 0.0)
        let span = max(hi - lo, 1)
        let pad = 0.08
        let dx = 1.0 / Double(v.count - 1)
        return v.enumerated().map { i, val in
            CGPoint(x: Double(i) * dx,
                    y: pad + (1 - (val - lo) / span) * (1 - 2 * pad))
        }
    }

    /// Unit-space y of the zero line, matching `unitPoints`' mapping.
    private var zeroY: CGFloat {
        let v = projection.series.map(\.tsb).filter(\.isFinite)
        guard let rawLo = v.min(), let rawHi = v.max() else { return 0.5 }
        let lo = min(rawLo, 0.0), hi = max(rawHi, 0.0)
        let span = max(hi - lo, 1)
        let pad = 0.08
        return pad + (1 - (0.0 - lo) / span) * (1 - 2 * pad)
    }

    // MARK: Motion (transforms only; Reduce Motion = complete + crossfade)

    private func reveal() {
        if reduceMotion {
            revealed = true
            dotShown = true
        } else {
            withAnimation(.easeOut(duration: 0.6)) { revealed = true }
            withAnimation(Motion.lively.delay(0.6)) { dotShown = true }
        }
    }
}

/// The projected-TSB polyline in unit space — a `Shape` so the reveal is a `trim` (transform-only).
private struct SparkPath: Shape {
    let unit: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard let first = unit.first else { return p }
        p.move(to: place(first, rect))
        for u in unit.dropFirst() { p.addLine(to: place(u, rect)) }
        return p
    }

    private func place(_ u: CGPoint, _ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + u.x * rect.width, y: rect.minY + u.y * rect.height)
    }
}

// MARK: - Previews

#Preview("Race form — fresh") {
    RaceReadinessCardPreview(kind: .fresh)
}

#Preview("Race form — heavy, dark") {
    RaceReadinessCardPreview(kind: .heavy).preferredColorScheme(.dark)
}

private struct RaceReadinessCardPreview: View {
    let kind: RaceProjection.Band

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let days = 14
        // A believable taper path: ATL falling away from a steady CTL, crossing zero mid-taper
        // (fresh) or stalling below it (heavy).
        let series: [TrendAnalytics.DayPoint] = (0...days).map { i in
            let t = Double(i) / Double(days)
            let ctl = 46.0 - 6.0 * t
            let tsb = kind == .heavy ? (-22.0 + 16.0 * t) : (-14.0 + 26.0 * t)
            return TrendAnalytics.DayPoint(date: cal.date(byAdding: .day, value: i, to: today) ?? today,
                                           ctl: ctl, atl: ctl - tsb)
        }
        let last = series[days]
        let projection = RaceProjection.Projection(raceDay: last.date,
                                                   daysToRace: days,
                                                   ctl: last.ctl,
                                                   atl: last.atl,
                                                   band: RaceProjection.band(last.tsb),
                                                   series: series)
        return ScrollView {
            RaceReadinessCard(projection: projection, raceName: "Austin Marathon")
                .padding(Theme.Space.md)
        }
        .background(Theme.background)
    }
}
