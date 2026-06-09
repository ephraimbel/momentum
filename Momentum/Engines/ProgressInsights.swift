import Foundation

/// Deterministic training-progress analytics (PRD §4.8, §9 — rules compute, AI narrates). Uses the
/// sports-science **acute:chronic workload ratio (ACWR)**: 7-day load vs the 28-day weekly average.
/// The ratio drives a training status and a plan recommendation (increase / hold / ease / rest).
@MainActor
struct ProgressInsights {
    enum Status: String, Sendable {
        case starting = "Getting started"
        case underloaded = "Recovered"
        case building = "Building"
        case pushing = "Pushing"
        case overreaching = "Ease off"
    }
    enum Recommendation: Sendable { case start, increase, hold, ease, rest }

    struct WeekPoint: Identifiable, Sendable {
        let id = UUID()
        let weekStart: Date
        let load: Double
        let distanceM: Double
    }

    let acute: Double
    let chronic: Double
    let acwr: Double
    let status: Status
    let recommendation: Recommendation
    let weeks: [WeekPoint]            // last 8 weeks, oldest → newest
    let loadTrendPct: Double          // this week vs prior 3-week average
    let distanceTrendPct: Double
    let hasData: Bool

    init(workouts: [Workout], now: Date = Date(), calendar: Calendar = .current) {
        func load(_ w: Workout) -> Double {
            let minutes = w.durationS / 60
            let intensity = Double(w.perceivedEffort ?? Self.defaultIntensity(w.type))
            if minutes > 0 { return minutes * intensity }
            // Fallback when duration is missing: rough distance-based load for cardio.
            if let d = w.gps?.distanceM, d > 0 { return (d / 1000) * 6 }
            return 0
        }

        let acuteCut = calendar.date(byAdding: .day, value: -7, to: now)!
        let chronicCut = calendar.date(byAdding: .day, value: -28, to: now)!
        acute = workouts.filter { $0.startedAt >= acuteCut }.reduce(0) { $0 + load($1) }
        let chronic28 = workouts.filter { $0.startedAt >= chronicCut }.reduce(0) { $0 + load($1) }
        chronic = chronic28 / 4

        hasData = !workouts.isEmpty
        if chronic < 1 {
            acwr = 0
            status = .starting
            recommendation = .start
        } else {
            let ratio = acute / chronic
            acwr = ratio
            switch ratio {
            case ..<0.8: status = .underloaded; recommendation = .increase
            case 0.8..<1.3: status = .building; recommendation = .hold
            case 1.3..<1.5: status = .pushing; recommendation = .hold
            case 1.5..<1.8: status = .overreaching; recommendation = .ease
            default: status = .overreaching; recommendation = .rest
            }
        }

        // Weekly series (last 8 weeks).
        let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        var series: [WeekPoint] = []
        for i in stride(from: 7, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .weekOfYear, value: -i, to: thisWeekStart),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { continue }
            let inWeek = workouts.filter { $0.startedAt >= start && $0.startedAt < end }
            let wkLoad = inWeek.reduce(0) { $0 + load($1) }
            let wkDist = inWeek.reduce(0) { $0 + ($1.gps?.distanceM ?? 0) }
            series.append(WeekPoint(weekStart: start, load: wkLoad, distanceM: wkDist))
        }
        weeks = series

        // Trends: current week vs the prior 3 weeks' average.
        func trend(_ values: (WeekPoint) -> Double) -> Double {
            guard series.count >= 4 else { return 0 }
            let current = values(series[series.count - 1])
            let prior = series[(series.count - 4)..<(series.count - 1)].map(values)
            let avg = prior.reduce(0, +) / Double(prior.count)
            guard avg > 0 else { return current > 0 ? 100 : 0 }
            return (current - avg) / avg * 100
        }
        loadTrendPct = trend { $0.load }
        distanceTrendPct = trend { $0.distanceM }
    }

    private static func defaultIntensity(_ type: WorkoutType) -> Int {
        switch type { case .run: 7; case .ride: 6; case .hike: 6; case .strength: 6; case .walk: 4 }
    }
}
