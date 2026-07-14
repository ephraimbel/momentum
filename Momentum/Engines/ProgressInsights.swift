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
        let avgPaceSPerKm: Double   // distance-weighted, running only; 0 = no runs that week
    }

    let acute: Double
    let chronic: Double
    let acwr: Double
    let status: Status
    let recommendation: Recommendation
    let weeks: [WeekPoint]            // last `weeksBack` weeks, oldest → newest
    let loadTrendPct: Double          // this week vs prior 3-week average
    let distanceTrendPct: Double
    let paceTrendPct: Double          // running pace: negative = faster (improving)
    let hasData: Bool

    /// `weeksBack` sizes the weekly series window (the Trends range picker: 1M ≈ 5, 3M ≈ 13,
    /// later 6M ≈ 26 and 1Y ≈ 52). ACWR and the trend percentages are window-independent — they
    /// always read the most recent weeks — so switching ranges never changes the coaching verdict.
    init(workouts: [Workout], now: Date = Date(), calendar: Calendar = .current, weeksBack: Int = 8) {
        let load = TrainingLoad.session   // canonical session-RPE load (PRD §4.8)

        let acuteCut = calendar.date(byAdding: .day, value: -7, to: now)!
        let chronicCut = calendar.date(byAdding: .day, value: -28, to: now)!
        acute = workouts.filter { $0.startedAt >= acuteCut }.reduce(0) { $0 + load($1) }
        let chronic28 = workouts.filter { $0.startedAt >= chronicCut }.reduce(0) { $0 + load($1) }
        // Normalize the chronic divisor to the history that actually exists (weeks, capped at 4).
        // A flat ÷4 understates chronic for new athletes — a keen first week reads as ratio ≈ 4
        // and tells exactly the person we should be encouraging to "ease off / rest". With one
        // week of data chronic == acute (ratio 1); by four weeks this is the classic ACWR.
        let historyDays = workouts.map(\.startedAt).min()
            .flatMap { calendar.dateComponents([.day], from: $0, to: now).day } ?? 0
        chronic = chronic28 / min(4, max(1, Double(historyDays) / 7))

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

        // Weekly series — `weeksBack` rolling 7-day windows ending at `now`, oldest → newest. Rolling
        // (not calendar) windows keep the most-recent bar aligned with the ACWR acute window, so a
        // recent workout always shows up in the latest bar. A fixed calendar "this week" can be
        // near-empty early in the week (e.g. a Sunday) and disagree with the acute load headline.
        var series: [WeekPoint] = []
        for i in stride(from: max(1, weeksBack) - 1, through: 0, by: -1) {
            guard let end = calendar.date(byAdding: .day, value: -7 * i, to: now),
                  let start = calendar.date(byAdding: .day, value: -7, to: end) else { continue }
            let inWeek = workouts.filter { $0.startedAt > start && $0.startedAt <= end }
            let wkLoad = inWeek.reduce(0) { $0 + load($1) }
            let wkDist = inWeek.reduce(0) { $0 + ($1.gps?.distanceM ?? 0) }
            // Distance-weighted average running pace for the week (running only).
            let runs = inWeek.filter { $0.type.discipline == .running }
            let runDist = runs.reduce(0) { $0 + ($1.gps?.distanceM ?? 0) }
            let runDur = runs.reduce(0) { $0 + $1.durationS }
            let wkPace = runDist > 0 ? runDur / (runDist / 1000) : 0
            series.append(WeekPoint(weekStart: start, load: wkLoad, distanceM: wkDist, avgPaceSPerKm: wkPace))
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

        // Pace trend over weeks that actually had runs (zero-run weeks would skew it). Latest paced
        // week vs the average of the prior (≤3) paced weeks; negative ⇒ faster.
        let paced = series.filter { $0.avgPaceSPerKm > 0 }
        if paced.count >= 2 {
            let current = paced.last!.avgPaceSPerKm
            let prior = paced.dropLast().suffix(3).map(\.avgPaceSPerKm)
            let avg = prior.reduce(0, +) / Double(prior.count)
            paceTrendPct = avg > 0 ? (current - avg) / avg * 100 : 0
        } else {
            paceTrendPct = 0
        }
    }
}
