import Foundation

/// The plan-generation workload progression governor (ENDURANCE-FOCUS §6.2). It compares each
/// planned week's volume with the rolling four-week average behind it, then caps abrupt increases at
/// a conservative product limit. The ratio is exposure context—not an injury prediction or a
/// universal safe zone—and the 1.3 limit is an operational planning choice, not a medical threshold.
///
/// The governor only ever *reduces* — deloads, tapers, and ordinary ramps pass through untouched. In
/// normal operation it stays dormant (the intensity ramps are well inside the limit); it exists to
/// catch abrupt edges — a base seeded far above the athlete's reported current volume, or any
/// future engine change that accidentally spikes a week. Pure + deterministic.
enum ACWRGovernor {
    /// Conservative internal progression ceiling. This is not an injury-risk or safety threshold.
    static let maxRatio = 1.3

    /// Per-week scale factors (0…1] that bring each week under the ceiling.
    /// - weeklyMeters: planned running volume per week, in order.
    /// - currentWeeklyM: the athlete's reported current weekly volume (chronic seed). Pass 0/nil-like
    ///   when unknown — the first planned week then seeds the history and only *acceleration* is governed.
    static func capFactors(weeklyMeters: [Double], currentWeeklyM: Double) -> [Double] {
        guard !weeklyMeters.isEmpty else { return [] }
        // Chronic history seed: their actual current load when we know it, else week 1's plan (which
        // then passes by definition — we can't judge week 1 against an unknown history).
        let seed = currentWeeklyM > 0 ? currentWeeklyM : (weeklyMeters.first ?? 0)
        var history: [Double] = [seed, seed, seed, seed]
        var factors: [Double] = []
        for planned in weeklyMeters {
            let chronic = history.suffix(4).reduce(0, +) / 4
            let allowed = chronic > 0 ? chronic * maxRatio : planned
            let capped = min(planned, allowed)
            factors.append(planned > 0 ? capped / planned : 1)
            history.append(capped)          // future weeks build on the governed volume, not the wish
        }
        return factors
    }
}
