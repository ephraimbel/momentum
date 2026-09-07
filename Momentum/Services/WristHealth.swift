import Foundation

/// Builds and caches the wrist's health snapshot on the phone (2026-09-06).
///
/// `ReadinessToday.compute` is the ONE full-blend readiness assembly, and it already holds every
/// input the wrist needs — the recovery feed, the nights, the workouts, the check-in — so the
/// snapshot is built right there and cached; `PhoneWatchSync.push` adds the week's training (which
/// needs the plan) and sends it. Nothing here re-reads Health on its own.
/// Main-actor bound, like the SwiftData workouts and the readiness copy it reads.
@MainActor
enum WristHealth {
    static let cacheKey = "wrist.health.snapshot"

    struct Inputs {
        var readiness: MorningReadiness?
        var signals: RecoverySignals
        var hrvHist: [(day: Date, value: Double)]
        var rhrHist: [(day: Date, value: Double)]
        var nights: [SleepReport.Night]
        var workouts: [Workout]
        var checkin: DailyCheckin?
        var dailySteps: [(day: Date, steps: Double)]
        var healthConnected: Bool
    }

    // MARK: Build (pure)

    static func build(_ i: Inputs, now: Date = Date(), calendar: Calendar = .current) -> WristHealthSnapshot {
        let today = calendar.startOfDay(for: now)
        func day(_ ago: Int) -> Date { calendar.date(byAdding: .day, value: -ago, to: today) ?? today }
        func key(_ d: Date) -> String { WristHealthSnapshot.dayKey(d, calendar: calendar) }
        let weekDays = (0..<7).reversed().map(day)

        var snapshot = WristHealthSnapshot(dayKey: key(today), generatedAt: now, healthConnected: i.healthConnected)

        // ── Readiness
        if let r = i.readiness {
            snapshot.readiness = .init(
                score: r.score,
                band: bandKey(r.band),
                word: r.band.displayName,
                driver: r.displayDriverWithConfidence,
                guidance: r.guidance,
                confidence: r.confidence.rawValue,
                pillars: r.pillars.map { pillar($0, signals: i.signals, nights: i.nights, checkin: i.checkin, now: now, calendar: calendar) },
                modifiers: r.modifiers.map { modifier($0, signals: i.signals) })
        }

        // ── Sleep: last night against the athlete's own need, plus the week's nights.
        if let report = SleepReport.build(from: i.nights, now: now, calendar: calendar) {
            let byKey = Dictionary(i.nights.map { (key(calendar.startOfDay(for: $0.date)), $0.asleepH) },
                                   uniquingKeysWith: { a, _ in a })
            snapshot.sleep = .init(
                asleepH: report.asleepH, needH: report.needH, debt14H: report.debt14H,
                efficiencyPct: report.efficiencyPct, deepPct: report.deepPct, remPct: report.remPct,
                band: report.durationBand.rawValue,
                nightDayKey: key(calendar.startOfDay(for: report.date)),
                note: i.signals.sleepNote,
                week: weekDays.map { byKey[key($0)] })
        }

        // ── Overnight vitals against the athlete's own norm.
        if let hrv = i.signals.hrvMs {
            snapshot.hrv = .init(value: hrv, baseline: i.signals.hrvBaselineMs,
                                 trend: i.signals.hrvTrend?.rawValue, note: i.signals.hrvNote,
                                 week: weekSeries(i.hrvHist, days: weekDays, calendar: calendar))
        }
        if let rhr = i.signals.restingHR {
            snapshot.restingHR = .init(value: Double(rhr), baseline: i.signals.restingHRBaseline,
                                       trend: i.signals.restingHRTrend?.rawValue, note: i.signals.restingHRNote,
                                       week: weekSeries(i.rhrHist, days: weekDays, calendar: calendar))
        }
        snapshot.respiratoryZ = i.signals.respiratoryZ
        snapshot.wristTempDeltaC = i.signals.wristTempDeltaC

        // ── Strain: today so far, and the week — workouts plus the day's ambient steps, against
        // the athlete's own chronic load, exactly as `DayStrain` defines it. Chronic load is the
        // same fitness-fatigue CTL the phone's Health hub seeds it with, so the two never disagree.
        let chronic = chronicLoad(i.workouts, through: today, calendar: calendar)
        let stepsByKey = Dictionary(i.dailySteps.map { (key(calendar.startOfDay(for: $0.day)), $0.steps) },
                                    uniquingKeysWith: { a, _ in a })
        var week: [Int?] = []
        var todayStrain: DayStrain?
        for d in weekDays {
            let dayWorkouts = i.workouts.filter { calendar.startOfDay(for: $0.startedAt) == d }
            let steps = stepsByKey[key(d)]
            guard !dayWorkouts.isEmpty || steps != nil else { week.append(nil); continue }
            let strain = DayStrain(workoutsToday: dayWorkouts, ambientSteps: steps,
                                   chronicLoad: chronic, now: d, calendar: calendar)
            week.append(strain.score)
            if d == today { todayStrain = strain }
        }
        if let s = todayStrain {
            snapshot.strain = .init(score: s.score, band: s.band.rawValue,
                                    workoutLoad: s.workoutLoad, ambientLoad: s.ambientLoad, week: week)
        } else if week.contains(where: { $0 != nil }) {
            snapshot.strain = .init(score: 0, band: DayStrain.Band.light.rawValue,
                                    workoutLoad: 0, ambientLoad: 0, week: week)
        }
        return snapshot
    }

    /// The week's training, added at send time because it needs the plan: the planned-versus-done
    /// ledger the Plan board shows, the streak, and the acute:chronic load word.
    static func training(plan: TrainingPlan?, workouts: [Workout],
                         now: Date = Date(), calendar: Calendar = .current) -> WristHealthSnapshot.Training? {
        let today = calendar.startOfDay(for: now)
        guard let week = calendar.dateInterval(of: .weekOfYear, for: today) else { return nil }
        let sessions = (plan?.sessions ?? []).filter { week.contains($0.date) }
        let doneM = workouts
            .filter { week.contains($0.startedAt) && $0.type.discipline != .strength }
            .reduce(0.0) { $0 + ($1.gps?.distanceM ?? 0) }
        let ledger = PlanWeekLedger.ledger(
            sessions: sessions.map { .init(targetDistanceM: $0.targetDistanceM, completed: $0.status == .completed) },
            actualCardioM: doneM)
        let stats = ProfileStats(workouts: workouts, plan: plan, calendar: calendar)
        let loads = dailyLoads(workouts, through: today, days: 28, calendar: calendar)
        let acute = (0..<7).reduce(0.0) { sum, ago in
            sum + (loads[calendar.date(byAdding: .day, value: -ago, to: today) ?? today] ?? 0)
        }
        let chronicWeekly = loads.values.reduce(0, +) / 4
        var loadWord: String?
        var loadLine: String?
        if chronicWeekly > 0 {
            let ratio = acute / chronicWeekly
            loadWord = TrainingLoadContext.band(ratio: ratio).displayName
            loadLine = TrainingLoadContext.summary(ratio: ratio)
        }
        return .init(weekDoneM: ledger.doneM, weekPlannedM: ledger.plannedM,
                     doneSessions: ledger.doneSessions, totalSessions: ledger.totalSessions,
                     streakDays: stats.currentStreak, loadWord: loadWord, loadLine: loadLine)
    }

    // MARK: Cache

    static func store(_ snapshot: WristHealthSnapshot, defaults: UserDefaults = .standard) {
        guard let data = snapshot.encoded() else { return }
        defaults.set(data, forKey: cacheKey)
    }

    static func cached(defaults: UserDefaults = .standard) -> WristHealthSnapshot? {
        defaults.data(forKey: cacheKey).flatMap(WristHealthSnapshot.decode)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: cacheKey)
    }

    // MARK: Pieces

    static func bandKey(_ band: RecoveryModel.Readiness) -> String {
        switch band {
        case .primed: "primed"
        case .ready: "ready"
        case .moderate: "moderate"
        case .strained: "strained"
        case .depleted: "depleted"
        }
    }

    private static func pillar(_ p: MorningReadiness.Pillar, signals: RecoverySignals,
                               nights: [SleepReport.Night], checkin: DailyCheckin?,
                               now: Date, calendar: Calendar) -> WristHealthSnapshot.Pillar {
        let title: String
        let detail: String
        switch p.kind {
        case .load:
            title = "Load"
            detail = "Recent training"
        case .hrv:
            title = "HRV"
            let value = signals.hrvMs.map { "\(Int($0.rounded())) ms" } ?? "—"
            detail = signals.hrvBaselineMs.map { "\(value) · norm \(Int($0.rounded()))" } ?? value
        case .sleep:
            title = "Sleep"
            if let report = SleepReport.build(from: nights, now: now, calendar: calendar) {
                detail = "\(hours(report.asleepH)) of \(hours(report.needH))"
            } else if let h = signals.sleepHours {
                detail = hours(h)
            } else {
                detail = "—"
            }
        case .restingHR:
            title = "Resting HR"
            let value = signals.restingHR.map { "\($0) bpm" } ?? "—"
            detail = signals.restingHRBaseline.map { "\(value) · norm \(Int($0.rounded()))" } ?? value
        case .checkin:
            title = "Check-in"
            detail = checkin.map { "\($0.energy.label) · \($0.legs.label)" } ?? "Not yet today"
        }
        return .init(kind: p.kind.rawValue, title: title, detail: detail, points: p.points)
    }

    private static func modifier(_ m: MorningReadiness.Modifier, signals: RecoverySignals) -> WristHealthSnapshot.Modifier {
        switch m.kind {
        case .respiratory:
            let z = signals.respiratoryZ.map { String(format: "%.1f SD above your norm", $0) } ?? "Above your norm"
            return .init(kind: m.kind.rawValue, title: "Breathing rate up", detail: z, points: m.points)
        case .wristTemperature:
            let d = signals.wristTempDeltaC.map { String(format: "+%.1f °C vs your norm", $0) } ?? "Above your norm"
            return .init(kind: m.kind.rawValue, title: "Wrist temperature up", detail: d, points: m.points)
        }
    }

    static func hours(_ h: Double) -> String {
        let total = Int((h * 60).rounded())
        return "\(total / 60)h \(String(format: "%02d", total % 60))m"
    }

    private static func weekSeries(_ hist: [(day: Date, value: Double)], days: [Date], calendar: Calendar) -> [Double?] {
        let byKey = Dictionary(hist.map { (WristHealthSnapshot.dayKey(calendar.startOfDay(for: $0.day), calendar: calendar), $0.value) },
                               uniquingKeysWith: { _, b in b })
        return days.map { byKey[WristHealthSnapshot.dayKey($0, calendar: calendar)] }
    }

    /// The athlete's chronic training load today: `FitnessFreshness` CTL over the trailing 90
    /// days of daily loads (the 42-day constant has decayed anything older below a tenth).
    static func chronicLoad(_ workouts: [Workout], through today: Date, calendar: Calendar) -> Double {
        let loads = dailyLoads(workouts, through: today, days: 90, calendar: calendar)
        let ordered = loads.keys.sorted().map { loads[$0] ?? 0 }
        return FitnessFreshness.series(dailyLoads: ordered).last?.ctl ?? 0
    }

    /// Σ `TrainingLoad.session` per day over the trailing window, zero-filled.
    private static func dailyLoads(_ workouts: [Workout], through today: Date, days: Int,
                                   calendar: Calendar) -> [Date: Double] {
        var loads: [Date: Double] = [:]
        for ago in 0..<days {
            if let d = calendar.date(byAdding: .day, value: -ago, to: today) { loads[d] = 0 }
        }
        for w in workouts {
            let d = calendar.startOfDay(for: w.startedAt)
            guard loads[d] != nil else { continue }
            loads[d, default: 0] += TrainingLoad.session(w)
        }
        return loads
    }
}
