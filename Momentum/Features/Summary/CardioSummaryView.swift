import SwiftUI
import CoreLocation
import SwiftData

/// Reusable cardio summary body: route map, distance/pace/elevation, per-unit splits.
struct CardioSummaryContent: View {
    let workout: Workout
    var distanceUnit: DistanceUnit = .auto
    /// Show the user's title/description header (off in the save editor, which has editable fields).
    var showsHeader: Bool = true
    /// Allow attaching/replacing the workout photo (post-workout only; read-only in history).
    var canEditPhoto: Bool = false

    @Environment(\.modelContext) private var context
    @State private var hits: [CardioAchievements.Hit] = []

    private var unitMeters: Double {
        distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000
    }

    var body: some View {
        if let gps = workout.gps {
            // Reveal-first: lead with the mastery payoff (hero distance + any "you got better" win),
            // then the route, the AI read, and the splits. Naming lives at the bottom of the save flow.
            VStack(spacing: Theme.Space.lg) {
                if showsHeader, !workout.title.isEmpty || !workout.note.isEmpty { titleHeader }
                headline(workout, gps).reveal(0)
                if !hits.isEmpty {
                    achievementsSection.reveal(0.10)
                    EarnedShareButton(workout: workout, distanceUnit: distanceUnit, title: "Share your run").reveal(0.16)
                }
                WorkoutPhotoSection(workout: workout, canEdit: canEditPhoto).reveal(0.20)
                routeMap(gps).reveal(0.22)
                AIReadCard(workout: workout, distanceUnit: distanceUnit).reveal(0.30)
                PlanProposalCard().reveal(0.34)
                repsSection(gps).reveal(0.35)   // a structured run's headline: how each rep landed
                RunAnalysisSection(gps: gps, type: workout.type, distanceUnit: distanceUnit).reveal(0.38)
                TimeInZonesCard(workout: workout).reveal(0.39)
                splitsSection(gps).reveal(0.40)
            }
            .task {
                hits = CardioAchievements.detect(for: workout, distanceUnit: distanceUnit, in: context)
            }
        } else {
            Text("No GPS data").foregroundStyle(Theme.inkTertiary)
        }
    }

    /// One self-relative line that frames the run as progress — the top achievement, if any.
    private var competenceText: String? {
        hits.first.map { "\($0.label) · \($0.detail)" }
    }

    private var achievementsSection: some View {
        VStack(spacing: Theme.Space.sm) {
            ForEach(hits) { hit in
                PRBadge(text: "\(hit.label) · \(hit.detail)", celebrate: true)
            }
        }
    }

    private var titleHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if !workout.title.isEmpty {
                Text(workout.title).font(.display(26, weight: .black)).foregroundStyle(Theme.ink)
            }
            if !workout.note.isEmpty {
                Text(workout.note).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func routeMap(_ gps: GPSDetail) -> some View {
        let coords = gps.routeCoordinates(type: workout.type)
        if coords.count > 1 {
            RouteMapView(coordinates: RouteSmoothing.smooth(coords))
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                // When the map-matched route lands post-finish (nil→present), the coordinates change
                // underneath RouteMapView. Its route line is added imperatively once on style-load (a
                // live gradient update crashes Mapbox), so a reframe would drop the line. Keying the
                // identity on match-presence forces one clean remount, re-running style-load with the
                // snapped route.
                .id(gps.matchedRouteData != nil)
        }
    }

    private func headline(_ workout: Workout, _ gps: GPSDetail) -> some View {
        let isImperial = distanceUnit.resolved() == .imperial
        let distanceTarget = isImperial ? gps.distanceM / Formatters.metersPerMile : gps.distanceM / 1000
        return VStack(spacing: Theme.Space.lg) {
            CountUpHero(target: distanceTarget,
                        format: { String(format: "%.2f", $0) },
                        label: isImperial ? "Miles" : "Kilometers")
            if let competenceText { EarnedLine(text: competenceText) }
            HStack(spacing: Theme.Space.lg) {
                stat(Formatters.duration(s: workout.durationS), "Time")
                stat(paceOrSpeed(workout, gps), workout.type == .ride ? "Avg speed" : "Avg pace")
                stat("\(Int(gps.elevationGainM)) m", "Elevation")
                if let kcal = workout.calories, kcal > 0 { stat("\(Int(kcal))", "Calories") }
            }
        }
        .padding(.vertical, Theme.Space.md)
    }

    private func paceOrSpeed(_ workout: Workout, _ gps: GPSDetail) -> String {
        if workout.type == .ride {
            let speed = workout.durationS > 0 ? gps.distanceM / workout.durationS : 0
            return Formatters.speed(ms: speed, unit: distanceUnit)
        }
        let pace = gps.distanceM > 0 ? workout.durationS / (gps.distanceM / 1000) : 0
        return Formatters.pace(secPerKm: pace, unit: distanceUnit)
    }

    private func splitsSection(_ gps: GPSDetail) -> some View {
        let points = samplePoints(gps)
        let splits = CardioMetrics.splits(points, unitMeters: unitMeters)
        let unitLabel = distanceUnit.resolved() == .imperial ? "mi" : "km"
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if !splits.isEmpty {
                Text("SPLITS").font(.rounded(Theme.FontSize.label, weight: .bold))
                    .tracking(1.4).foregroundStyle(Theme.inkTertiary)
                ForEach(splits, id: \.index) { split in
                    HStack {
                        Text("\(split.index + 1) \(unitLabel)\(split.isPartial ? " (partial)" : "")")
                            .foregroundStyle(Theme.inkSecondary)
                        Spacer()
                        Text(Formatters.duration(s: split.durationS)).monospacedDigit().foregroundStyle(Theme.ink)
                    }
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Per-rep adherence breakdown for a guided structured run — how each rep landed vs its target pace.
    @ViewBuilder
    private func repsSection(_ gps: GPSDetail) -> some View {
        let reps = gps.structuredReps
        if !reps.isEmpty {
            let paced = reps.filter { $0.verdict != .noTarget }
            let onPace = paced.filter { $0.verdict == .onPace }.count
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    Text("REPS").font(.rounded(Theme.FontSize.label, weight: .bold))
                        .tracking(1.4).foregroundStyle(Theme.inkTertiary)
                    Spacer()
                    if !paced.isEmpty {
                        Text("\(onPace)/\(paced.count) on pace").font(.rounded(Theme.FontSize.label, weight: .bold))
                            .foregroundStyle(Theme.inkTertiary)
                    }
                }
                ForEach(Array(reps.enumerated()), id: \.offset) { _, rep in
                    HStack(spacing: Theme.Space.sm) {
                        Text(rep.label).foregroundStyle(Theme.ink).frame(width: 92, alignment: .leading)
                        Spacer()
                        Text(Formatters.pace(secPerKm: rep.achievedPaceSPerKm, unit: distanceUnit))
                            .monospacedDigit().foregroundStyle(Theme.ink)
                        repVerdictChip(rep.verdict)
                    }
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func repVerdictChip(_ v: RepResult.Verdict) -> some View {
        let label: String
        switch v {
        case .onPace: label = "on"; case .tooFast: label = "fast"; case .tooSlow: label = "slow"; case .noTarget: label = "—"
        }
        let filled = v == .onPace
        return Text(label).font(.rounded(Theme.FontSize.label, weight: .bold))
            .foregroundStyle(filled ? Theme.background : Theme.inkSecondary)
            .frame(width: 48, height: 24)
            .background {
                Capsule().fill(filled ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                if !filled { Capsule().stroke(Theme.hairline) }
            }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.display(20, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1).foregroundStyle(Theme.inkTertiary)
        }
    }

    private func samplePoints(_ gps: GPSDetail) -> [CardioMetrics.SamplePoint] {
        let accepted = gps.samples.filter(\.accepted).sorted { $0.t < $1.t }
        guard let first = accepted.first else { return [] }
        var pts: [CardioMetrics.SamplePoint] = []
        var cumulative = 0.0
        var prev: LocationSample?
        for s in accepted {
            if let p = prev {
                cumulative += Geo.distance(lat1: p.lat, lon1: p.lon, lat2: s.lat, lon2: s.lon)
            }
            pts.append(.init(t: s.t.timeIntervalSince(first.t), cumulativeM: cumulative))
            prev = s
        }
        return pts
    }
}
