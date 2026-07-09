import Foundation

/// The plan-generation safety governor (ENDURANCE-FOCUS §6.2): a generated plan physically cannot
/// ramp weekly running volume into the acute:chronic injury-risk zone. ACWR compares a week's load to
/// the rolling 4-week average behind it; sustained ratios above ~1.5 correlate with injury spikes, so
/// we cap planned weeks at a conservative 1.3× their own trailing average.
///
/// The governor only ever *reduces* — deloads, tapers, and sane ramps pass through untouched. In
/// normal operation it stays dormant (the intensity ramps are well inside the zone); it exists to
/// catch the dangerous edges — a base seeded far above the athlete's reported current volume, or any
/// future engine change that accidentally spikes a week. Pure + deterministic.
enum ACWRGovernor {
    /// Conservative planned-ACWR ceiling (research danger zone starts ~1.5; plans shouldn't flirt with it).
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
