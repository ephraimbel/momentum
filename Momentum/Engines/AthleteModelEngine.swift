import Foundation

/// Tier A of the Athlete Model (see `docs/ATHLETE-MODEL.md` §4): the **deterministic** distillation
/// of workout history into structured facts. Pure and fully recomputed each workout — never
/// incremental — so it is always reconstructable and unit-testable (PRD §9: rules compute, AI
/// narrates). `AthleteModelService` copies the produced `AthleteFacts` onto the persisted
/// `AthleteModel`; nothing here touches SwiftData beyond reading the passed-in objects.
@MainActor
struct AthleteModelEngine {

    /// The signals whose evidence volume drives confidence on the You surface.
    enum Signal: String, CaseIterable, Sendable {
        case rhythm, sessionLength, adherence, disciplineMix
        case paceAtEffort, strengthProgress, volumeTrend, load, prCadence, frequency
    }

    /// Confidence thresholds per signal: `(growingAt, confidentAt)` evidence counts (§4).
    static func confidence(_ signal: Signal, count: Int) -> Confidence {
        let (growing, confident): (Int, Int)
        switch signal {
        case .rhythm:           (growing, confident) = (4, 8)
        case .sessionLength:    (growing, confident) = (3, 6)
        case .adherence:        (growing, confident) = (4, 8)
        case .disciplineMix:    (growing, confident) = (5, 10)
        case .paceAtEffort:     (growing, confident) = (3, 6)
        case .strengthProgress: (growing, confident) = (2, 4)
        case .volumeTrend:      (growing, confident) = (3, 6)
        case .load:             (growing, confident) = (8, 18)  // ~6 weeks of training
        case .prCadence:        (growing, confident) = (1, 3)
        case .frequency:        (growing, confident) = (4, 8)
        }
        if count >= confident { return .confident }
        if count >= growing { return .growing }
        return .emerging
    }

    let facts: AthleteFacts

    init(workouts: [Workout], plan: TrainingPlan?, now: Date = Date(), calendar: Calendar = .current) {
        facts = Self.compute(workouts: workouts, plan: plan, now: now, calendar: calendar)
    }

    // MARK: - Distillation

    static func compute(workouts: [Workout], plan: TrainingPlan?,
                        now: Date, calendar: Calendar) -> AthleteFacts {
        var f = AthleteFacts()
        guard !workouts.isEmpty else { return f }
        let sorted = workouts.sorted { $0.startedAt < $1.startedAt }

        // ── Rhythm ────────────────────────────────────────────────────────────
        var hours = Array(repeating: 0, count: 24)
        var weekdays = Array(repeating: 0, count: 7)
        for w in sorted {
            hours[calendar.component(.hour, from: w.startedAt)] += 1
            weekdays[calendar.component(.weekday, from: w.startedAt) - 1] += 1
        }
        f.trainingHourHistogram = hours
        f.weekdayHistogram = weekdays
        let minutes = sorted.map { $0.durationS / 60 }.filter { $0 > 0 }
        f.medianSessionMinutes = median(minutes)
        f.preferredSessionMinutes = modeBinned(minutes, bin: 15)

        // ── Adherence (needs a plan) ──────────────────────────────────────────
        if let plan {
            let cut = calendar.date(byAdding: .day, value: -28, to: now)!
            let past = plan.sessions.filter { $0.date >= cut && $0.date <= now }
            let completed = past.filter { $0.status == .completed }.count
            let missed = past.filter { $0.status == .missed }.count
            let moved = past.filter { $0.status == .moved }.count
            let decided = completed + missed
            if decided > 0 { f.planAdherence28d = Double(completed) / Double(decided) }
            let universe = decided + moved
            if universe > 0 { f.movedSessionRate28d = Double(moved) / Double(universe) }
            f.signalSampleCounts[Signal.adherence.rawValue] = universe

            // Consecutive missed among the most recent past sessions (no-shame: used only to soften).
            var streak = 0
            for s in past.sorted(by: { $0.date > $1.date }) {
                if s.status == .missed { streak += 1 }
                else if s.status == .completed { break }
            }
            f.consecutiveMissed = streak
        }

        // ── Discipline mix (trailing 56d vs prior 56d) ────────────────────────
        let recentShare = disciplineShare(sorted, from: -56, to: 0, now: now, calendar: calendar)
        let priorShare = disciplineShare(sorted, from: -112, to: -56, now: now, calendar: calendar)
        f.disciplineShare = recentShare
        var trend: [String: Double] = [:]
        for k in Set(recentShare.keys).union(priorShare.keys) {
            trend[k] = (recentShare[k] ?? 0) - (priorShare[k] ?? 0)
        }
        f.disciplineTrend = trend
        let recent56 = inWindow(sorted, from: -56, to: 0, now: now, calendar: calendar)
        f.signalSampleCounts[Signal.disciplineMix.rawValue] = recent56.count

        // ── Fitness trajectory ────────────────────────────────────────────────
        // Easy-run pace at matched effort over 8 weeks. Negative pct = getting fitter.
        let easyRuns = inWindow(sorted, from: -56, to: 0, now: now, calendar: calendar)
            .filter { isEasyRun($0) }
            .compactMap { w -> Double? in
                guard let p = w.gps?.avgPaceSPerKm, p > 0 else { return nil }
                return p
            }
        f.paceAtEffortTrendPct = halfSplitTrendPct(easyRuns)  // already oldest→newest
        f.signalSampleCounts[Signal.paceAtEffort.rawValue] = easyRuns.count

        // Per-lift e1RM trend over 8 weeks.
        f.e1rmTrendByExercise = e1rmTrends(inWindow(sorted, from: -56, to: 0, now: now, calendar: calendar))
        let strengthSessions56 = inWindow(sorted, from: -56, to: 0, now: now, calendar: calendar)
            .filter { $0.type.isStrengthStyle }.count
        f.signalSampleCounts[Signal.strengthProgress.rawValue] = strengthSessions56

        // Weekly strength volume: last 28d vs prior 28d.
        let volLast = totalVolume(inWindow(sorted, from: -28, to: 0, now: now, calendar: calendar))
        let volPrior = totalVolume(inWindow(sorted, from: -56, to: -28, now: now, calendar: calendar))
        f.weeklyVolumeTrendPct = pctChange(current: volLast, prior: volPrior)
        f.signalSampleCounts[Signal.volumeTrend.rawValue] = strengthSessions56

        // ── Load / recovery ───────────────────────────────────────────────────
        f.currentACWR = ProgressInsights(workouts: workouts, now: now, calendar: calendar).acwr
        let weeksOfData = weeksSpanned(sorted, now: now, calendar: calendar)
        f.signalSampleCounts[Signal.load.rawValue] = min(workouts.count, weeksOfData * 3)
        f.overreachThresholdACWR = overreachThreshold(sorted, now: now, calendar: calendar)
        f.typicalRecoveryDays = typicalRecoveryDays(sorted, calendar: calendar)

        // ── Achievement (PR cadence) ──────────────────────────────────────────
        let prs = personalRecords(sorted, calendar: calendar)
        var byMonth: [String: Int] = [:]
        for date in prs { byMonth[monthKey(date, calendar: calendar), default: 0] += 1 }
        f.prCountByMonth = byMonth
        f.lastPRAt = prs.max()
        f.signalSampleCounts[Signal.prCadence.rawValue] = prs.count

        // ── Frequency trend (churn early-warning) ─────────────────────────────
        let freqLast = Double(inWindow(sorted, from: -28, to: 0, now: now, calendar: calendar).count) / 4
        let freqPrior = Double(inWindow(sorted, from: -56, to: -28, now: now, calendar: calendar).count) / 4
        f.frequencyTrend28d = freqLast - freqPrior
        f.signalSampleCounts[Signal.frequency.rawValue] = inWindow(sorted, from: -56, to: 0, now: now, calendar: calendar).count

        // Rhythm evidence = total workouts.
        f.signalSampleCounts[Signal.rhythm.rawValue] = workouts.count
        f.signalSampleCounts[Signal.sessionLength.rawValue] = minutes.count

        return f
    }

    // MARK: - Windowing helpers

    private static func inWindow(_ ws: [Workout], from dayLo: Int, to dayHi: Int,
                                 now: Date, calendar: Calendar) -> [Workout] {
        let lo = calendar.date(byAdding: .day, value: dayLo, to: now)!
        let hi = calendar.date(byAdding: .day, value: dayHi, to: now)!
        return ws.filter { $0.startedAt >= lo && $0.startedAt < hi }
    }

    private static func disciplineShare(_ ws: [Workout], from: Int, to: Int,
                                        now: Date, calendar: Calendar) -> [String: Double] {
        let window = inWindow(ws, from: from, to: to, now: now, calendar: calendar)
        guard !window.isEmpty else { return [:] }
        var counts: [String: Int] = [:]
        for w in window { counts[w.type.rawValue, default: 0] += 1 }
        let total = Double(window.count)
        return counts.mapValues { Double($0) / total }
    }

    private static func weeksSpanned(_ sorted: [Workout], now: Date, calendar: Calendar) -> Int {
        guard let first = sorted.first?.startedAt else { return 0 }
        let days = calendar.dateComponents([.day], from: first, to: now).day ?? 0
        return max(0, days / 7)
    }

    // MARK: - Signal math

    /// Easy run = a run the athlete took easy: low reported effort, or a planned easy/recovery run.
    static func isEasyRun(_ w: Workout) -> Bool {
        guard w.type == .run else { return false }
        if let rpe = w.perceivedEffort, rpe <= 4 { return true }
        if let rt = w.plannedSession?.runType, rt == .easy || rt == .recovery { return true }
        return false
    }

    /// Per-exercise % change in best e1RM, oldest→newest half-split, over the given workouts.
    private static func e1rmTrends(_ ws: [Workout]) -> [String: Double] {
        var series: [String: [(date: Date, e1rm: Double)]] = [:]
        for w in ws where w.type.isStrengthStyle {
            guard let s = w.strength else { continue }
            for row in s.exercises {
                guard let name = row.exercise?.name else { continue }
                let working = row.sets.filter { $0.isComplete && $0.type == .working }
                    .compactMap { set -> StrengthMath.WorkingSet? in
                        guard let kg = set.weightKg, let reps = set.reps else { return nil }
                        return .init(weightKg: kg, reps: reps)
                    }
                let best = StrengthMath.bestE1RM(working)
                if best > 0 { series[name, default: []].append((w.startedAt, best)) }
            }
        }
        var out: [String: Double] = [:]
        for (name, points) in series {
            let ordered = points.sorted { $0.date < $1.date }.map(\.e1rm)
            let t = halfSplitTrendPct(ordered)
            if t != 0 || ordered.count >= 2 { out[name] = t }
        }
        return out
    }

    private static func totalVolume(_ ws: [Workout]) -> Double {
        ws.reduce(0) { $0 + ($1.strength?.totalVolumeKg ?? 0) }
    }


    /// **v1 heuristic** (gated to low confidence): the lowest ACWR preceding a "strain event" —
    /// a missed session or an easy run that felt hard (RPE ≥ 7). Clamped to a sane band; defaults
    /// to 1.5 until ≥3 events exist. Refined in a later pass.
    private static func overreachThreshold(_ sorted: [Workout], now: Date, calendar: Calendar) -> Double {
        var acwrs: [Double] = []
        for w in sorted where w.type == .run {
            let feltHard = (w.perceivedEffort ?? 0) >= 7 && isEasyRunPlanned(w)
            guard feltHard else { continue }
            let prior = sorted.filter { $0.startedAt < w.startedAt }
            let acwr = ProgressInsights(workouts: prior, now: w.startedAt, calendar: calendar).acwr
            if acwr > 0 { acwrs.append(acwr) }
        }
        guard acwrs.count >= 3, let lowest = acwrs.min() else { return 1.5 }
        return min(1.8, max(1.2, lowest))
    }

    private static func isEasyRunPlanned(_ w: Workout) -> Bool {
        if let rt = w.plannedSession?.runType { return rt == .easy || rt == .recovery }
        return false
    }

    /// **v1 heuristic** (gated): mean days from a hard (top-tertile load) session to the next
    /// easy run back near baseline pace. Clamped [1, 4]; defaults to 1. Refined in a later pass.
    private static func typicalRecoveryDays(_ sorted: [Workout], calendar: Calendar) -> Double {
        let easyPaces = sorted.filter { isEasyRun($0) }.compactMap { $0.gps?.avgPaceSPerKm }.filter { $0 > 0 }
        guard !easyPaces.isEmpty else { return 1 }
        let baseline = median(easyPaces)
        let loads = sorted.map { TrainingLoad.session($0) }.filter { $0 > 0 }.sorted()
        guard loads.count >= 3 else { return 1 }
        let tertile = loads[Int(Double(loads.count) * 2 / 3)]
        var gaps: [Double] = []
        for (i, w) in sorted.enumerated() where TrainingLoad.session(w) >= tertile {
            for next in sorted[(i + 1)...] where isEasyRun(next) {
                guard let p = next.gps?.avgPaceSPerKm, p > 0 else { continue }
                let days = (next.startedAt.timeIntervalSince(w.startedAt)) / 86_400
                if days > 7 { break }
                if p <= baseline * 1.02 { gaps.append(days); break }
            }
        }
        guard !gaps.isEmpty else { return 1 }
        return min(4, max(1, gaps.reduce(0, +) / Double(gaps.count)))
    }

    /// Dates at which a new personal record was set, walking history chronologically:
    /// per-lift best e1RM, and longest run distance. Used for PR cadence.
    private static func personalRecords(_ sorted: [Workout], calendar: Calendar) -> [Date] {
        var dates: [Date] = []
        var bestE1RM: [String: Double] = [:]
        var longestRun = 0.0
        for w in sorted {
            if w.type.isStrengthStyle, let s = w.strength {
                for row in s.exercises {
                    guard let name = row.exercise?.name else { continue }
                    let working = row.sets.filter { $0.isComplete && $0.type == .working }
                        .compactMap { set -> StrengthMath.WorkingSet? in
                            guard let kg = set.weightKg, let reps = set.reps else { return nil }
                            return .init(weightKg: kg, reps: reps)
                        }
                    let best = StrengthMath.bestE1RM(working)
                    if best > (bestE1RM[name] ?? 0) + 0.01 {
                        if bestE1RM[name] != nil { dates.append(w.startedAt) }  // not the first-ever
                        bestE1RM[name] = best
                    }
                }
            } else if w.type == .run, let d = w.gps?.distanceM, d > 0 {
                if d > longestRun + 0.01 {
                    if longestRun > 0 { dates.append(w.startedAt) }
                    longestRun = d
                }
            }
        }
        return dates
    }

    // MARK: - Pure numeric helpers

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    /// Mode of values binned to the nearest `bin` (e.g. session minutes → 15-min bins).
    static func modeBinned(_ values: [Double], bin: Double) -> Double {
        guard !values.isEmpty, bin > 0 else { return 0 }
        var counts: [Double: Int] = [:]
        for v in values { counts[(v / bin).rounded() * bin, default: 0] += 1 }
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key ?? 0
    }

    /// % change between the mean of the older half and the newer half of an oldest→newest series.
    /// Requires ≥2 points; 0 otherwise. Negative means the later values are smaller.
    static func halfSplitTrendPct(_ orderedOldestToNewest: [Double]) -> Double {
        let n = orderedOldestToNewest.count
        guard n >= 2 else { return 0 }
        let split = n / 2
        let earlier = Array(orderedOldestToNewest.prefix(split))
        let later = Array(orderedOldestToNewest.suffix(n - split))
        let ea = earlier.reduce(0, +) / Double(earlier.count)
        let la = later.reduce(0, +) / Double(later.count)
        guard ea > 0 else { return 0 }
        return (la - ea) / ea * 100
    }

    static func pctChange(current: Double, prior: Double) -> Double {
        guard prior > 0 else { return current > 0 ? 100 : 0 }
        return (current - prior) / prior * 100
    }

    static func monthKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return "\(c.year ?? 0)-\(String(format: "%02d", c.month ?? 0))"
    }
}

/// The value produced by `AthleteModelEngine` — Tier A facts, mirroring the persisted
/// `AthleteModel`'s stored fields. `AthleteModelService` copies these across; tests assert on it.
struct AthleteFacts: Sendable, Equatable {
    var trainingHourHistogram: [Int] = Array(repeating: 0, count: 24)
    var weekdayHistogram: [Int] = Array(repeating: 0, count: 7)
    var medianSessionMinutes: Double = 0
    var preferredSessionMinutes: Double = 0
    var planAdherence28d: Double = 0
    var movedSessionRate28d: Double = 0
    var disciplineShare: [String: Double] = [:]
    var disciplineTrend: [String: Double] = [:]
    var paceAtEffortTrendPct: Double = 0
    var e1rmTrendByExercise: [String: Double] = [:]
    var weeklyVolumeTrendPct: Double = 0
    var currentACWR: Double = 0
    var overreachThresholdACWR: Double = 1.5
    var typicalRecoveryDays: Double = 1
    var prCountByMonth: [String: Int] = [:]
    var lastPRAt: Date?
    var frequencyTrend28d: Double = 0
    var consecutiveMissed: Int = 0
    var signalSampleCounts: [String: Int] = [:]
}
