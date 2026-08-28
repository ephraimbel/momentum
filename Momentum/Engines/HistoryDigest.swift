import Foundation

/// The numbers behind the History page's summary card (2026-08-28). Pure and deterministic so the
/// page can render a month's story — how far, how long, how many, and whether that's more or less
/// than last month — without walking the store on every body pass. All SI (meters, seconds).
struct HistoryDigest: Equatable, Sendable {
    var sessions: Int = 0
    var meters: Double = 0
    var seconds: Double = 0
    var prs: Int = 0
    /// Change in distance against the previous calendar month, as a fraction (0.12 = +12%).
    /// nil when last month has nothing to compare against — we never invent a "+100%".
    var distanceDeltaFraction: Double?
    /// Sessions in the previous month — powers the fallback comparison for a strength-only month.
    var previousSessions: Int = 0

    static let empty = HistoryDigest()

    /// Build the current month's digest from a workout list already narrowed to one sport filter.
    /// `prDates` are the athlete's record dates; only this month's are counted (a two-year athlete
    /// must never read their lifetime PR count as "this month").
    static func build(workouts: [Workout], prDates: [Date],
                      now: Date = Date(), calendar: Calendar = .current) -> HistoryDigest {
        guard let month = calendar.dateInterval(of: .month, for: now) else { return .empty }
        let previousStart = calendar.date(byAdding: .month, value: -1, to: month.start)
        let previous = previousStart.flatMap { calendar.dateInterval(of: .month, for: $0) }

        var d = HistoryDigest()
        var previousMeters = 0.0
        for w in workouts {
            if month.contains(w.startedAt) {
                d.sessions += 1
                d.meters += w.gps?.distanceM ?? 0
                d.seconds += w.durationS
            } else if let previous, previous.contains(w.startedAt) {
                d.previousSessions += 1
                previousMeters += w.gps?.distanceM ?? 0
            }
        }
        d.prs = prDates.filter { month.contains($0) }.count
        // A delta needs a real baseline on BOTH sides: no distance last month (or none this month)
        // means there is nothing honest to compare, so the card simply doesn't show a chip.
        if previousMeters > 0, d.meters > 0 {
            d.distanceDeltaFraction = (d.meters - previousMeters) / previousMeters
        }
        return d
    }
}

/// The sports History can filter by. Deliberately four buckets, not twenty workout types: the
/// filter answers "show me my runs" and shouldn't become a taxonomy. `.all` is always offered;
/// the rest appear only when the athlete actually has one (`available(in:)`).
enum HistoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all, runs, rides, strength, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .runs: "Runs"
        case .rides: "Rides"
        case .strength: "Strength"
        case .other: "Other"
        }
    }

    /// The empty-state line when this filter has nothing in it.
    var emptyLine: String {
        switch self {
        case .all: "Your sessions land here as you train."
        case .runs: "No runs logged yet."
        case .rides: "No rides logged yet."
        case .strength: "No strength sessions logged yet."
        case .other: "Nothing else logged yet."
        }
    }

    func matches(_ w: Workout) -> Bool {
        switch self {
        case .all: true
        case .runs: w.type.discipline == .running
        case .rides: w.type.isCycling
        case .strength: w.type.isStrengthStyle
        case .other: !(w.type.discipline == .running || w.type.isCycling || w.type.isStrengthStyle)
        }
    }

    /// The chips worth showing, with their counts — `.all` first, then every bucket the athlete
    /// actually has, in a fixed order. A single-sport athlete sees no chips at all (one filter
    /// that filters nothing is furniture), which the caller checks via `count <= 1`.
    static func available(in workouts: [Workout]) -> [(filter: HistoryFilter, count: Int)] {
        guard !workouts.isEmpty else { return [] }
        var out: [(HistoryFilter, Int)] = [(.all, workouts.count)]
        for f in [HistoryFilter.runs, .rides, .strength, .other] {
            let n = workouts.filter(f.matches).count
            if n > 0 { out.append((f, n)) }
        }
        return out
    }
}
