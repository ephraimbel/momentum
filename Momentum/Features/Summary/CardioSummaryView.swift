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
    /// Live style override from the save editor's map-style row — the hero map previews the choice
    /// before it's saved. nil (history/read-only) renders the workout's own persisted style.
    var mapStyleOverride: MapStyleOption? = nil
    /// Added to every reveal in the cascade below. The post-run presentation plays a celebration
    /// over this content; without the offset the whole cascade would run — and finish — behind that
    /// beat, so the summary would already be sitting fully drawn the moment it lifted. History
    /// passes 0 and reveals immediately.
    var revealDelay: Double = 0
    /// Whether to read this run against the athlete's history and say what it meant.
    ///
    /// Off in history, deliberately. The verdict is written in the present tense — "that's 3 this
    /// week" — which is true the moment you finish and nonsense on a run from six months ago. It
    /// would also insert a row a beat after the screen appeared, shoving the content down; the
    /// post-workout surface hides that behind the celebration, a history screen has nowhere to put it.
    var showsVerdict: Bool = false

    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @State private var hits: [CardioAchievements.Hit] = []
    /// What this run MEANT, when it didn't set a record. Runs that did are carried by the badges.
    @State private var verdict: RunVerdict.Verdict?
    /// The run's relationship to the plan — credited a session, or left one honestly open.
    /// Post-run only (`showsVerdict`): "stays on the board" is true the moment you finish and
    /// nonsense on a run from six months ago.
    @State private var planLine: PlanConnection?
    private struct PlanConnection { let text: String; let credited: Bool }
    // The splits' cumulative-distance walk (a haversine per accepted sample) cached once — the
    // splits section re-ran it on every body pass through the reveal cascade.
    @State private var samplePts: [CardioMetrics.SamplePoint] = []
    /// HR series pulled from Apple Health for the run's window — populated only when we didn't capture
    /// a live series ourselves (Watch / imported runs), so the HR chart appears for every run.
    @State private var healthHR: [(date: Date, bpm: Double)] = []
    /// The run's seven-day window, fetched here (on this always-present task) and handed to the
    /// "This week" context card — the card can't fetch it itself while collapsed for want of data.
    @State private var weekWorkouts: [Workout] = []

    private var unitMeters: Double {
        distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000
    }

    var body: some View {
        if let gps = workout.gps {
            // Reveal-first: lead with the mastery payoff (hero distance + any "you got better" win),
            // then the route, the AI read, and the splits. Naming lives at the bottom of the save flow.
            VStack(spacing: Theme.Space.lg) {
                if showsHeader, !workout.title.isEmpty || !workout.note.isEmpty { titleHeader }
                headline(workout, gps)   // staggers its own children; no outer reveal
                // The plan connection, at the payoff moment: "Today's tempo run — checked off your
                // plan" when this run credited a session, or the honest partial when it didn't
                // ("Saturday's long run stays on the board — this covered about 40% of it").
                // The summary used to say nothing either way, so crediting felt like a coin flip.
                if let line = planLine {
                    EarnedLine(text: line.text, systemImage: line.credited ? "calendar.badge.checkmark" : "calendar",
                               earned: line.credited)
                        .reveal(revealDelay + 0.08)
                }
                if !hits.isEmpty { achievementsSection.reveal(revealDelay + 0.10) }
                // Sharing is not gated on a record. It used to sit inside the achievements branch, so
                // the ~90% of runs that set no PR offered no way to share at all — and the share card
                // is the growth loop for a solo app. The badge above is what's *earned*; the run
                // itself is always worth showing.
                EarnedShareButton(workout: workout, distanceUnit: distanceUnit,
                                  title: "Share your run").reveal(revealDelay + 0.16)
                WorkoutPhotoSection(workout: workout, canEdit: canEditPhoto).reveal(revealDelay + 0.20)
                routeMap(gps).reveal(revealDelay + 0.22)
                AIReadCard(workout: workout, distanceUnit: distanceUnit).reveal(revealDelay + 0.30)
                if workout.durationS >= FuelingGuide.carbsFromS { refuelNote.reveal(revealDelay + 0.32) }
                PlanProposalCard().reveal(revealDelay + 0.34)
                repsSection(gps).reveal(revealDelay + 0.35).id("paceReview")   // a structured run's headline: how each rep landed
                SessionPaceReviewCard(workout: workout, distanceUnit: distanceUnit).reveal(revealDelay + 0.36)
                RunAnalysisSection(gps: gps, type: workout.type, distanceUnit: distanceUnit,
                                   healthHRSeries: healthHR).reveal(revealDelay + 0.38)
                WeekContextCard(anchor: workout.startedAt, weekWorkouts: weekWorkouts, distanceUnit: distanceUnit).reveal(revealDelay + 0.385)
                TimeInZonesCard(workout: workout).reveal(revealDelay + 0.39)
                splitsSection(gps).reveal(revealDelay + 0.40)
            }
            .task {
                samplePts = samplePoints(gps)
                hits = CardioAchievements.detect(for: workout, distanceUnit: distanceUnit, in: context)
                // Only when no badge fired — a record run is already spoken for, and two readings of
                // the same run stacked on each other is noise, not generosity. The extra fetch is
                // skipped entirely in history, where the line isn't shown.
                if showsVerdict, hits.isEmpty { verdict = computeVerdict(gps) }
                if showsVerdict { planLine = computePlanConnection(gps) }
                // The "This week" card's seven-day window — fetched here so the load runs even while
                // that card is collapsed (a .task on the card itself wouldn't fire until it has data).
                if let desc = WeekContextCard.windowDescriptor(anchor: workout.startedAt) {
                    weekWorkouts = (try? context.fetch(desc)) ?? []
                }
                // Backfill the HR series from Health when we didn't record one live (Watch / imported
                // runs). Same window + threshold as the time-in-zones card, so the two agree.
                if (gps.hrSamples.filter { $0.bpm > 0 }).count < 4 {
                    let end = workout.startedAt.addingTimeInterval(max(workout.elapsedS, workout.durationS))
                    healthHR = await services.health.heartRateSeries(start: workout.startedAt, end: end)
                }
            }
        } else {
            Text("No GPS data").foregroundStyle(Theme.inkTertiary)
        }
    }

    /// Post-long-run refuel nudge — the recovery window is the one fueling moment the summary can
    /// still influence, so it appears only after runs long enough to have burned real glycogen
    /// (the engine's ≥1h carb threshold). General and quiet: fueling, not dieting.
    private var refuelNote: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.purple)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.purple.opacity(0.1)))
            VStack(alignment: .leading, spacing: 2) {
                Text("REFUEL").font(.rounded(Theme.FontSize.label, weight: .black)).tracking(1.2)
                    .foregroundStyle(Theme.inkTertiary)
                Text(FuelingGuide.guidance(durationS: workout.durationS).after)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
        .accessibilityElement(children: .combine)
    }

    /// The single self-relative line under the hero. When the run set a record the badges below
    /// carry it — this used to restate `hits.first`, printing the same sentence twice in a row. So
    /// the slot belongs to the verdict instead, and every run gets a reading rather than just the
    /// one in ten that PRs.
    private var competenceLine: RunVerdict.Verdict? { hits.isEmpty ? verdict : nil }

    /// Each tone gets a glyph that matches what it's claiming — a rosette over "that's 3 this week"
    /// reads as an award for turning up, which devalues the badge that means something.
    private func glyph(_ tone: RunVerdict.Tone) -> String {
        switch tone {
        case .earned: return "rosette"
        case .gain: return "arrow.up.right"
        case .beginning: return "flag"
        case .steady: return "calendar"
        }
    }

    /// Read this run against the athlete's own history.
    ///
    /// Deliberately UNBOUNDED. This carried `fetchLimit = 60`, but the limit applied before the
    /// in-memory type filter, so it was 60 workouts of every discipline: a lifter who trains four
    /// times a week buries their running history in about ten weeks. The engine would then rank
    /// today against a truncated past and announce "Your fastest at this distance" over a run two
    /// minutes off a real best — or, with 60 straight non-runs behind it, greet a veteran with
    /// "Your first one on the board". `RunVerdict`'s whole contract is that it never over-claims,
    /// and a window that silently hides the evidence breaks it.
    ///
    /// The cost is nil in practice: `CardioAchievements.detect` already fetches the entire table
    /// unbounded in this same `.task`, a beat earlier. Type filtering stays in memory — a
    /// `#Predicate` on the enum isn't worth the risk of silently matching nothing.
    private func computeVerdict(_ gps: GPSDetail) -> RunVerdict.Verdict? {
        let start = workout.startedAt
        var descriptor = FetchDescriptor<Workout>(predicate: #Predicate { $0.startedAt < start })
        descriptor.sortBy = [SortDescriptor(\.startedAt, order: .reverse)]
        let priors = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.type == workout.type }
            .compactMap { w -> RunVerdict.Run? in
                guard let g = w.gps, g.distanceM > 0 else { return nil }
                return RunVerdict.Run(date: w.startedAt, distanceM: g.distanceM, durationS: w.durationS)
            }
        let this = RunVerdict.Run(date: start, distanceM: gps.distanceM, durationS: workout.durationS)
        return RunVerdict.verdict(for: this, priors: priors, unit: distanceUnit)
    }

    private var achievementsSection: some View {
        VStack(spacing: Theme.Space.sm) {
            ForEach(hits) { hit in
                PRBadge(text: "\(hit.label) · \(hit.detail)", celebrate: true)
            }
        }
    }

    /// The plan connection for this run. Crediting already happened in `WorkoutRunner.finish`
    /// (before this view presents), so `workout.plannedSession` is authoritative: set → say which
    /// session got checked off; nil with an open same-discipline prescription today → say honestly
    /// how much of it this run covered and that it stays on the board. Plain words, never a
    /// failure state — the open session simply rolls forward as it always did.
    private func computePlanConnection(_ gps: GPSDetail) -> PlanConnection? {
        if let s = workout.plannedSession {
            return PlanConnection(text: "\(dayPrefix(s.date)) \(sessionKindText(s)) — checked off your plan.",
                                  credited: true)
        }
        var descriptor = FetchDescriptor<UserProfile>()
        descriptor.fetchLimit = 1
        guard let plan = (try? context.fetch(descriptor))?.first?.plan else { return nil }
        let open = PlanCoaching.todaySessions(plan, on: workout.startedAt).filter {
            ($0.status == .planned || $0.status == .moved)
                && $0.completedWorkout == nil && $0.discipline == workout.type.discipline
        }
        // The closest miss: the open session this run came nearest to fulfilling.
        let best = open.compactMap { s -> (PlannedSession, Double)? in
            let c = PlanCredit.Candidate(targetDistanceM: s.targetDistanceM, targetDurationS: s.targetDurationS)
            guard let f = PlanCredit.fulfillment(of: c, distanceM: gps.distanceM, durationS: workout.durationS),
                  f < PlanCredit.minFulfillment else { return nil }
            return (s, f)
        }.max { $0.1 < $1.1 }
        guard let (session, f) = best else { return nil }
        return PlanConnection(text: "\(dayPrefix(session.date)) \(sessionKindText(session)) stays on the board — this covered about \(Int((f * 100).rounded()))% of it.",
                              credited: false)
    }

    private func dayPrefix(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "Today’s" : "\(date.formatted(.dateTime.weekday(.wide)))’s"
    }

    private func sessionKindText(_ s: PlannedSession) -> String {
        if let wt = s.workoutType, wt != .run { return wt.title.lowercased() }
        if let rt = s.runType {
            switch rt {
            case .intervals: return "intervals"
            case .race: return "race"
            default: return "\(rt.rawValue) run"
            }
        }
        return "session"
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
        let style = mapStyleOverride ?? gps.mapStyle
        if coords.count > 1 {
            RouteMapView(coordinates: RouteSmoothing.smooth(coords), style: style,
                         milestoneUnitMeters: unitMeters)   // same unit as the splits below
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                // When the map-matched route lands post-finish (nil→present), the coordinates change
                // underneath RouteMapView. Its route line is added imperatively once on style-load (a
                // live gradient update crashes Mapbox), so a reframe would drop the line. Keying the
                // identity on match-presence (and the previewed style) forces one clean remount,
                // re-running style-load with the snapped route.
                .id("\(gps.matchedRouteData != nil)-\(style.rawValue)")
        } else if workout.type.isGPS {
            // A GPS-discipline run with no usable route (treadmill, or GPS never locked) — a quiet
            // card instead of a silent gap where the map belongs.
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                VStack(spacing: 6) {
                    Image(systemName: "mappin.slash").font(.system(size: 22, weight: .semibold))
                    Text("No route recorded").font(.rounded(Theme.FontSize.caption, weight: .semibold))
                }
                .foregroundStyle(Theme.inkTertiary)
            }
            .frame(height: 120)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        }
    }

    private func headline(_ workout: Workout, _ gps: GPSDetail) -> some View {
        let isImperial = distanceUnit.resolved() == .imperial
        let distanceTarget = isImperial ? gps.distanceM / Formatters.metersPerMile : gps.distanceM / 1000
        // Staggered internally rather than revealed as one block: the hero used to arrive with the
        // verdict and the final stat row already settled beside it, so the distance was still
        // tallying while everything it implies sat there finished. Now the number lands, then what
        // it meant, then the detail.
        return VStack(spacing: Theme.Space.lg) {
            // `steadyNumeral` picks its decimals from the final value and holds them, so a clean 5 km
            // reads "5" at rest instead of "5.00" — without the digit count shifting mid-tally.
            CountUpHero(target: distanceTarget,
                        format: Formatters.steadyNumeral(target: distanceTarget),
                        label: isImperial ? "Miles" : "Kilometers",
                        delay: revealDelay)
                .reveal(revealDelay)
            if let line = competenceLine {
                EarnedLine(text: line.text, systemImage: glyph(line.tone), earned: line.tone == .earned)
                    .reveal(revealDelay + 0.14)
            }
            // Equal-width stats so the row stays balanced whether it's 3 or 5 — Avg HR joins Time,
            // pace, and elevation whenever the run has heart-rate data (ours, or backfilled from Health).
            HStack(alignment: .top, spacing: Theme.Space.md) {
                stat(Formatters.duration(s: workout.durationS), "Time")
                stat(paceOrSpeed(workout, gps), workout.type == .ride ? "Avg speed" : "Avg pace")
                if let hr = avgHR(gps), hr > 0 { stat("\(hr)", "Avg HR") }
                stat("\(Int(gps.elevationGainM)) m", "Elevation")
                if let kcal = workout.calories, kcal > 0 { stat("\(Int(kcal))", "Calories") }
            }
            .reveal(revealDelay + 0.22)
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
        let splits = CardioMetrics.splits(samplePts, unitMeters: unitMeters)
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
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1).foregroundStyle(Theme.inkTertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    /// The run's average heart rate — our own captured average, else the mean of the Health series
    /// we backfilled for a Watch/imported run (nil until that async load lands, then it appears).
    private func avgHR(_ gps: GPSDetail) -> Int? {
        if let a = gps.avgHR, a > 0 { return a }
        guard !healthHR.isEmpty else { return nil }
        return Int((healthHR.map(\.bpm).reduce(0, +) / Double(healthHR.count)).rounded())
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
