import Foundation

/// Race-day Form (TSB) projection — docs/RECOVERY-HUB-PLAN.md §11.1.2 (committed scope). The taper
/// is open-loop today: `taperMultipliers` are fixed at generation and nothing ever reads how the
/// block actually landed. This engine closes it — the feasibility verdict's missing final act.
///
/// Composition: the athlete's **actual** daily loads (each workout's `TrainingLoad.session`,
/// day-bucketed by `calendar.startOfDay` — the exact buckets `TrendAnalytics.fitnessFreshness`
/// charts, so the projection extends the live Trends curve seamlessly) concatenated with
/// `PlannedLoad.estimate` for each remaining planned session on its date, run through the ONE
/// impulse-response model — `FitnessFreshness.series`, the same function the live curve calls, so
/// the CTL 42-day / ATL 7-day constants can never diverge by construction. The race-day point is
/// the verdict: "projected +12 — arriving fresh" / "projected −6 — this taper isn't tapering yet".
///
/// Pure + deterministic: injected `now`/`calendar`, recompute-from-source (a rescheduled taper or
/// a late-syncing Garmin week self-heals on the next build). `nil` whenever a projection would be
/// dishonest — no plan, no dated race, or the race under 3 days out (by then the taper is already
/// written; a "projection" is just today's number wearing a costume).
enum RaceProjection {

    /// A dated race must be at least this many whole days out to project.
    static let minDaysOut = 3

    // MARK: Output

    struct Projection: Equatable, Sendable {
        /// Local start-of-day of the race.
        let raceDay: Date
        /// Whole days from today to race day (≥ `minDaysOut`).
        let daysToRace: Int
        /// Projected race-morning fitness (CTL).
        let ctl: Double
        /// Projected race-morning fatigue (ATL).
        let atl: Double
        /// Projected race-morning Form: fitness minus fatigue.
        var tsb: Double { ctl - atl }
        let band: Band
        /// Projected daily points, today → race day inclusive — the dotted extension of the live
        /// CTL/TSB curve (today's point is the anchor where dotted meets solid).
        let series: [TrendAnalytics.DayPoint]
    }

    /// The race-morning verdict over projected TSB. Deliberately tighter than the generic
    /// `FitnessFreshness.formLabel` bands (where "Balanced" spans −5…+5 and "Fresh" starts above
    /// +5): mid-block a mildly negative Form is a build working, but a race morning wants real
    /// freshness — so here anything below zero reads heavy and "fresh" is earned at +10.
    enum Band: String, Equatable, Sendable {
        case fresh    // ≥ +10 — arriving fresh
        case ready    // 0 ..< 10 — form has surfaced, more still lifting
        case heavy    // < 0 — this taper isn't tapering yet
    }

    static func band(_ tsb: Double) -> Band {
        switch tsb {
        case ..<0:  .heavy
        case ..<10: .ready
        default:    .fresh
        }
    }

    // MARK: Build (model convenience)

    /// Snapshot the plan's dated race + remaining prescriptions and project. "Remaining" mirrors
    /// the BalanceCard ghost-bar rule: still `.planned` and not yet backed by a completed workout.
    static func build(workouts: [Workout],
                      plan: TrainingPlan?,
                      now: Date = Date(),
                      calendar: Calendar = .current) -> Projection? {
        guard let plan else { return nil }
        let remaining = plan.sessions
            .filter { $0.status == .planned && $0.completedWorkout == nil }
            .map { (date: $0.date, estLoad: PlannedLoad.estimate($0)) }
        return build(workouts: workouts, raceDate: plan.raceDate, plannedLoads: remaining,
                     now: now, calendar: calendar)
    }

    // MARK: Build (pure core)

    /// The pure projection over plain values — what the fixtures pin down.
    /// - Parameters:
    ///   - plannedLoads: remaining planned sessions as `PlannedLoad.estimate` outputs. Only days
    ///     strictly after today and strictly before race day count: past prescriptions aren't
    ///     data (history is real workouts only), and the race itself never counts against its own
    ///     morning's form — TSB is a race-*morning* read, so race day projects as a zero-load day.
    ///   - historyDays: how much actual history seeds the model — `TrendAnalytics.fitnessFreshness`'s
    ///     default window, long enough for CTL(42d) to be honest.
    static func build(workouts: [Workout],
                      raceDate: Date?,
                      plannedLoads: [(date: Date, estLoad: Double)],
                      historyDays: Int = 120,
                      now: Date = Date(),
                      calendar: Calendar = .current) -> Projection? {
        guard let raceDate, historyDays > 0 else { return nil }
        let today = calendar.startOfDay(for: now)
        let raceDay = calendar.startOfDay(for: raceDate)
        guard let daysToRace = calendar.dateComponents([.day], from: today, to: raceDay).day,
              daysToRace >= minDaysOut,
              let start = calendar.date(byAdding: .day, value: -(historyDays - 1), to: today)
        else { return nil }

        // Actual history — the exact bucketing TrendAnalytics.fitnessFreshness (:49) charts.
        // Actuals own today and earlier; planned estimates own the future, so a stray
        // future-dated workout can never double-count with its own prescription.
        var actualByDay: [Date: Double] = [:]
        for w in workouts where w.startedAt >= start {
            actualByDay[calendar.startOfDay(for: w.startedAt), default: 0] += TrainingLoad.session(w)
        }
        var plannedByDay: [Date: Double] = [:]
        for p in plannedLoads {
            let d = calendar.startOfDay(for: p.date)
            guard d > today, d < raceDay, p.estLoad > 0 else { continue }
            plannedByDay[d, default: 0] += p.estLoad
        }

        // start … raceDay inclusive: `historyDays` of history (ending today) + the days to race.
        let dayList = (0..<(historyDays + daysToRace)).compactMap {
            calendar.date(byAdding: .day, value: $0, to: start)
        }
        let loads = dayList.map { d in
            d <= today ? (actualByDay[d] ?? 0) : (plannedByDay[d] ?? 0)
        }

        // The one impulse-response model — same CTL(42d)/ATL(7d) constants as the live curve,
        // guaranteed: this is the very function TrendAnalytics.fitnessFreshness runs.
        let points = FitnessFreshness.series(dailyLoads: loads)
        guard let race = points.last else { return nil }

        let series = zip(dayList, points).suffix(daysToRace + 1)
            .map { TrendAnalytics.DayPoint(date: $0.0, ctl: $0.1.ctl, atl: $0.1.atl) }

        return Projection(raceDay: raceDay,
                          daysToRace: daysToRace,
                          ctl: race.ctl,
                          atl: race.atl,
                          band: band(race.tsb),
                          series: series)
    }
}
