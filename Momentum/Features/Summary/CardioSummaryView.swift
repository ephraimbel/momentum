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
    /// Whether this is the finish-line moment, where a line may speak in the present tense.
    ///
    /// It used to mean "show the verdict at all", and history passed `false` — so a run lost its
    /// meaning the second time you opened it, arriving at bare numbers and a share button. The
    /// reason for that was sound but too broad: only *some* verdicts expire. "That's 3 this week"
    /// is true at the finish and nonsense in December; "Ninth time on this loop, 12s/mi faster than
    /// last time" is true forever. So history now shows the timeless ones (`Verdict.isTimeless`)
    /// and this flag governs only the perishable extras: the present-tense consistency line and the
    /// plan connection ("stays on the board").
    var showsVerdict: Bool = false

    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @State private var hits: [CardioAchievements.Hit] = []
    /// Which rep GROUPS are opened to their rep-by-rep detail (collapsed by default).
    @State private var expandedRepGroups: Set<Int> = []
    /// What this run MEANT, when it didn't set a record. Runs that did are carried by the badges.
    @State private var verdict: RunVerdict.Verdict?
    /// The run's relationship to the plan — credited a session, or left one honestly open.
    /// Post-run only (`showsVerdict`): "stays on the board" is true the moment you finish and
    /// nonsense on a run from six months ago.
    @State private var planLine: PlanConnection?
    private struct PlanConnection { let text: String; let credited: Bool }
    // (The route map lives in `ActivityHero` now — the full-bleed faded hero the HOSTS render
    // above this content, 2026-08-14. The coordinate replay, remount keying, and full-screen
    // zoom all moved with it.)
    /// HR series pulled from Apple Health for the run's window — populated only when we didn't capture
    /// a live series ourselves (Watch / imported runs), so the HR chart appears for every run.
    @State private var healthHR: [(date: Date, bpm: Double)] = []
    /// The run's seven-day window, fetched here (on this always-present task) and handed to the
    /// "This week" context card — the card can't fetch it itself while collapsed for want of data.
    @State private var weekWorkouts: [Workout] = []

    var body: some View {
        if let gps = workout.gps {
            // Reveal-first: lead with the mastery payoff (hero distance + any "you got better" win),
            // then the route, the AI read, and the splits. Naming lives at the bottom of the save flow.
            VStack(spacing: Theme.Space.lg) {
                if showsHeader { titleHeader }   // always has content now (type-title fallback + date)
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
                // (The map moved above this content — `ActivityHero`, 2026-08-14.)
                if !hits.isEmpty { achievementsSection.reveal(revealDelay + 0.16) }
                // Sharing is not gated on a record. It used to sit inside the achievements branch, so
                // the ~90% of runs that set no PR offered no way to share at all — and the share card
                // is the growth loop for a solo app. The badge above is what's *earned*; the run
                // itself is always worth showing.
                // The CTA names the sport it's sharing — "Share your run" on a ride reads as a
                // template leak (caught on the seeded ride, 2026-08-13).
                EarnedShareButton(workout: workout, distanceUnit: distanceUnit,
                                  title: "Share your \(workout.type.title.lowercased())").reveal(revealDelay + 0.20)
                WorkoutPhotoSection(workout: workout, canEdit: canEditPhoto).reveal(revealDelay + 0.24)
                AIReadCard(workout: workout, distanceUnit: distanceUnit).reveal(revealDelay + 0.30)
                if workout.durationS >= FuelingGuide.carbsFromS { refuelNote.reveal(revealDelay + 0.32) }
                PlanProposalCard().reveal(revealDelay + 0.34)
                repsSection(gps).reveal(revealDelay + 0.35).id("paceReview")   // a structured run's headline: how each rep landed
                SessionPaceReviewCard(workout: workout, distanceUnit: distanceUnit).reveal(revealDelay + 0.36)
                RunAnalysisSection(gps: gps, type: workout.type, distanceUnit: distanceUnit,
                                   healthHRSeries: healthHR).reveal(revealDelay + 0.38)
                // Zones sit WITH the analysis charts (they are one) — the week card closes the page.
                TimeInZonesCard(workout: workout).reveal(revealDelay + 0.385)
                WeekContextCard(anchor: workout.startedAt, weekWorkouts: weekWorkouts, distanceUnit: distanceUnit).reveal(revealDelay + 0.39)
                // The text splits list is gone (2026-08-06): RunAnalysisSection's splits card is now
                // the Strava-style row list — ordinal + exact pace + speed bar — so a second textual
                // rendering of the same numbers directly below it was noise.
            }
            .task {
                if showsVerdict { planLine = computePlanConnection(gps) }
                // The "This week" card's seven-day window — fetched here so the load runs even while
                // that card is collapsed (a .task on the card itself wouldn't fire until it has data).
                if let desc = WeekContextCard.windowDescriptor(anchor: workout.startedAt) {
                    weekWorkouts = (try? context.fetch(desc)) ?? []
                }
                // The record scan + verdict, OFF the main actor (2026-08-06): `detect` replays
                // every prior run's samples through the Kalman filter, and running it here on the
                // main context froze the summary right after first paint — the page appeared, then
                // wouldn't scroll. A detached task with its own background context does the same
                // work invisibly; only the value results hop back.
                let container = context.container
                let workoutId = workout.id
                let unit = distanceUnit
                let analysis: (hits: [CardioAchievements.Hit], verdict: RunVerdict.Verdict?) =
                    await Task.detached(priority: .userInitiated) {
                        let ctx = ModelContext(container)
                        var d = FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutId })
                        d.fetchLimit = 1
                        guard let w = (try? ctx.fetch(d))?.first, let g = w.gps else { return ([], nil) }
                        let hits = CardioAchievements.detect(for: w, distanceUnit: unit, in: ctx)
                        // Verdict only when no badge fired — a record run is already spoken for, and
                        // two readings of the same run stacked on each other is noise.
                        let verdict = hits.isEmpty ? Self.verdict(for: w, gps: g, unit: unit, in: ctx) : nil
                        return (hits, verdict)
                    }.value
                hits = analysis.hits
                verdict = analysis.verdict
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
    private var competenceLine: RunVerdict.Verdict? {
        guard hits.isEmpty, let verdict else { return nil }
        // History keeps everything that stays true; only the finish line gets the perishable ones.
        return showsVerdict || verdict.isTimeless ? verdict : nil
    }

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
    ///
    /// Static + nonisolated: runs inside the same detached analysis task as `detect`, against the
    /// same background context, so the whole history walk stays off the main actor.
    nonisolated private static func verdict(for workout: Workout, gps: GPSDetail,
                                            unit: DistanceUnit, in context: ModelContext) -> RunVerdict.Verdict? {
        let start = workout.startedAt
        var descriptor = FetchDescriptor<Workout>(predicate: #Predicate { $0.startedAt < start })
        descriptor.sortBy = [SortDescriptor(\.startedAt, order: .reverse)]
        let earlier = (try? context.fetch(descriptor)) ?? []
        let priors = earlier
            .filter { $0.type == workout.type }
            .compactMap { w -> RunVerdict.Run? in
                guard let g = w.gps, g.distanceM > 0 else { return nil }
                return RunVerdict.Run(date: w.startedAt, distanceM: g.distanceM,
                                      durationS: w.durationS, avgHR: g.avgHR)
            }
        // Same ground beats same distance, so the engine gets the route history when this run
        // retraces one. `RouteMatch` walks the same already-fetched array (no second query) and
        // rejects on distance before touching any geometry, so the common case where nothing
        // matches costs a comparison per prior run and nothing else.
        let route = RouteMatch.context(for: workout, gps: gps, priors: earlier)
        let this = RunVerdict.Run(date: start, distanceM: gps.distanceM,
                                  durationS: workout.durationS, avgHR: gps.avgHR)
        return RunVerdict.verdict(for: this, priors: priors, route: route, unit: unit)
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
            // A colon, not the em dash this used to carry (`CoachVoiceTests` bans the dash outright)
            // and not a comma (the same suite bans conclusions bolted onto one). It also keeps
            // `dayPrefix` sentence-initial, which its capital "Today's" assumes.
            return PlanConnection(text: "\(dayPrefix(s.date)) \(sessionKindText(s)): checked off your plan.",
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
        return PlanConnection(text: "\(dayPrefix(session.date)) \(sessionKindText(session)) stays on the board. This covered about \(Int((f * 100).rounded()))% of it.",
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
            // The eyebrow names the sport and the moment; the title sets the page's voice —
            // the same block the save screens print under the hero's fade (2026-08-14).
            ActivityEyebrow(type: workout.type, date: workout.startedAt)
            Text(workout.title.isEmpty ? workout.type.title : workout.title)
                .font(.display(30, weight: .black)).foregroundStyle(Theme.ink)
            if !workout.note.isEmpty {
                Text(workout.note).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            // The organized reading (2026-08-14): a labelled two-column grid instead of five
            // stats squeezed shoulder to shoulder. Avg HR joins whenever the run has heart-rate
            // data (ours, or backfilled from Health).
            KeyStatsGrid(stats: keyStats(workout, gps)).reveal(revealDelay + 0.22)
        }
        .padding(.vertical, Theme.Space.md)
    }

    private func paceOrSpeed(_ workout: Workout, _ gps: GPSDetail) -> String {
        if workout.type.isCycling {
            let speed = workout.durationS > 0 ? gps.distanceM / workout.durationS : 0
            return Formatters.speed(ms: speed, unit: distanceUnit)
        }
        let pace = gps.distanceM > 0 ? workout.durationS / (gps.distanceM / 1000) : 0
        return Formatters.pace(secPerKm: pace, unit: distanceUnit)
    }

    /// Per-rep adherence breakdown for a guided structured run — how each rep landed vs its target
    /// pace. A rep GROUP collapses to one summary row ("10 × 400m · 8:21 /mi · 8/10 on") that
    /// expands on tap — a 12-rep session must never read as a 12-row wall. Unnumbered blocks
    /// (tempo, progression thirds, the long run's two halves) stay flat: they ARE the summary.
    @ViewBuilder
    private func repsSection(_ gps: GPSDetail) -> some View {
        let reps = gps.structuredReps
        if !reps.isEmpty {
            let paced = reps.filter { $0.verdict != .noTarget }
            let onPace = paced.filter { $0.verdict == .onPace }.count
            let segments = RepGrouping.segments(reps)
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
                ForEach(segments) { segment in
                    if segment.reps.count > 1 {
                        repGroupRow(segment)
                        if expandedRepGroups.contains(segment.id) {
                            ForEach(Array(segment.reps.enumerated()), id: \.offset) { _, rep in
                                repRow(rep)
                                    .padding(.leading, Theme.Space.md)
                                    .transition(.opacity)
                            }
                        }
                    } else if let rep = segment.reps.first {
                        repRow(rep)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func repRow(_ rep: RepResult) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Text(rep.label).foregroundStyle(Theme.ink).frame(width: 92, alignment: .leading)
            Spacer()
            Text(Formatters.pace(secPerKm: rep.achievedPaceSPerKm, unit: distanceUnit))
                .monospacedDigit().foregroundStyle(Theme.ink)
            repVerdictChip(rep.verdict)
        }
        .font(.rounded(Theme.FontSize.body, weight: .medium))
    }

    /// The collapsed face of a rep group: shape, average, tally — tap to open the rep-by-rep story.
    private func repGroupRow(_ segment: RepGrouping.Segment) -> some View {
        let expanded = expandedRepGroups.contains(segment.id)
        let avg = segment.averagePaceSPerKm
        return Button {
            Haptics.selection()
            withAnimation(Motion.standard) {
                if expanded { expandedRepGroups.remove(segment.id) }
                else { expandedRepGroups.insert(segment.id) }
            }
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Text(segment.headline)
                    .foregroundStyle(Theme.ink)
                Spacer()
                if let avg {
                    Text(Formatters.pace(secPerKm: avg, unit: distanceUnit))
                        .monospacedDigit().foregroundStyle(Theme.ink)
                }
                if segment.pacedCount > 0 {
                    Text("\(segment.onPaceCount)/\(segment.pacedCount) on")
                        .font(.rounded(Theme.FontSize.label, weight: .bold))
                        .foregroundStyle(Theme.inkTertiary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.inkTertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .font(.rounded(Theme.FontSize.body, weight: .semibold))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(segment.headline)
        .accessibilityValue(avg.map { "average \(Formatters.pace(secPerKm: $0, unit: distanceUnit)), \(segment.onPaceCount) of \(segment.pacedCount) on pace" } ?? "")
        .accessibilityHint(expanded ? "Hides each rep" : "Shows each rep")
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

    private func keyStats(_ workout: Workout, _ gps: GPSDetail) -> [KeyStat] {
        var stats = [KeyStat(Formatters.duration(s: workout.durationS), "Time"),
                     KeyStat(paceOrSpeed(workout, gps), workout.type.isCycling ? "Avg speed" : "Avg pace")]
        if let hr = avgHR(gps), hr > 0 { stats.append(KeyStat("\(hr) bpm", "Avg HR")) }
        stats.append(KeyStat(Formatters.elevation(meters: gps.elevationGainM, unit: distanceUnit), "Elevation"))
        if let kcal = workout.calories, kcal > 0 { stats.append(KeyStat("\(Int(kcal))", "Calories")) }
        return stats
    }

    /// The run's average heart rate — our own captured average, else the mean of the Health series
    /// we backfilled for a Watch/imported run (nil until that async load lands, then it appears).
    private func avgHR(_ gps: GPSDetail) -> Int? {
        if let a = gps.avgHR, a > 0 { return a }
        guard !healthHR.isEmpty else { return nil }
        return Int((healthHR.map(\.bpm).reduce(0, +) / Double(healthHR.count)).rounded())
    }

}

// MARK: - Rep grouping (pure — unit-tested)

/// Chunks a structured run's rep results into displayable segments: consecutive NUMBERED reps of
/// the same kind form a collapsible group; unnumbered blocks stand alone. Pure math, no UI.
enum RepGrouping {
    struct Segment: Identifiable {
        let id: Int              // stable position index within the workout
        let reps: [RepResult]

        /// "10 × 400m" · "8 × 30s hills" · "12 × 30s surges" — the group's shape in the same
        /// language every other surface speaks. Distance reps read the median achieved distance
        /// snapped to 50 m (GPS crossings land a few meters past the line); timed efforts
        /// (hills, surges, strides, run/walk runs) read the median duration.
        var headline: String {
            let count = reps.count
            let noun = reps.first?.title.map { " \($0.lowercased())s" } ?? ""
            if let title = reps.first?.title, ["Hill", "Surge", "Stride", "Run"].contains(title) {
                let d = RepGrouping.median(reps.map(\.durationS))
                let rounded = (d / 5).rounded() * 5
                return "\(count) × \(StructuredWorkoutBuilder.secLabel(rounded))\(noun)"
            }
            let m = RepGrouping.median(reps.map(\.distanceM))
            let snapped = max(50, (m / 50).rounded() * 50)
            return "\(count) × \(StructuredWorkoutBuilder.repDistanceLabel(snapped))\(noun)"
        }

        var pacedCount: Int { reps.filter { $0.verdict != .noTarget }.count }
        var onPaceCount: Int { reps.filter { $0.verdict == .onPace }.count }

        /// Mean achieved pace across paced reps; nil for pure-effort groups (hills, strides).
        var averagePaceSPerKm: Double? {
            let paced = reps.filter { $0.verdict != .noTarget && $0.achievedPaceSPerKm > 0 }
            guard !paced.isEmpty else { return nil }
            return paced.map(\.achievedPaceSPerKm).reduce(0, +) / Double(paced.count)
        }
    }

    /// Consecutive reps sharing a noun and a rep count chunk together; anything unnumbered is
    /// its own segment (a tempo block, a progression third, the long run's race-pace finish).
    static func segments(_ reps: [RepResult]) -> [Segment] {
        var out: [Segment] = []
        var current: [RepResult] = []
        func flush() {
            if !current.isEmpty { out.append(Segment(id: out.count, reps: current)); current = [] }
        }
        for rep in reps {
            if rep.repTotal == nil {
                flush()
                out.append(Segment(id: out.count, reps: [rep]))
            } else if let last = current.last, last.title == rep.title, last.repTotal == rep.repTotal {
                current.append(rep)
            } else {
                flush()
                current = [rep]
            }
        }
        flush()
        return out
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

