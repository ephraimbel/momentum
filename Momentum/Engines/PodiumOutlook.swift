import Foundation

/// The Podium reveal's honest numbers (user call 2026-07-23: "subtle stuff for the race they're
/// signing up for — or just them wanting to overall become great"). Pure + testable.
///
/// Projections reuse the SAME improvement model the feasibility verdict runs on
/// (`PlanFeasibility.achievableImprovement`) — one source of truth for how much faster a block can
/// honestly make someone. This is presentation depth for the athletes training to win, never a
/// marketing curve: the outlook can't promise what the verdict engine would refuse.
enum PodiumOutlook {

    /// Race path: today's predicted finish vs. what the block points at. The target honors the
    /// athlete's goal when it's within honest reach; a fantasy goal gets the capped achievable
    /// instead, and a sandbagged goal (slower than today's fitness) never drags the outlook
    /// backward — the built number is always ≤ today's. `intensity` defaults to `.podium` because
    /// this outlook only ever shows for the Podium tier — so the achievable ceiling reflects the
    /// harder push the athlete actually signed up for, not a balanced prediction that undersells it.
    static func raceProjection(raceDistanceM: Double, p5kSPerKm: Double, goalFinishTimeS: Double?,
                               experience: ExperienceLevel, weeks: Int,
                               intensity: PlanIntensity = .podium,
                               currentRaceTimeS: Double? = nil) -> (nowS: Double, builtS: Double)? {
        guard raceDistanceM > 0, p5kSPerKm > 0, weeks > 0 else { return nil }
        // Their own time AT the race distance is the truest "now"; otherwise project from 5K fitness.
        // (The same anti-double-tax the feasibility verdict uses — so the reveal and the banner agree
        // on what "today" runs instead of the outlook quietly painting the athlete slower.)
        let now = currentRaceTimeS ?? PlanFeasibility.predictedFinishS(distanceM: raceDistanceM, p5kSPerKm: p5kSPerKm)
        let achievable = now * (1 - PlanFeasibility.achievableImprovement(experience: experience, weeks: weeks, intensity: intensity))
        let built = goalFinishTimeS.map { max($0, achievable) } ?? achievable
        return (nowS: now, builtS: min(built, now))
    }

    /// No-race path ("become great"): the same model pointed at the athlete's own 5K — the number
    /// every other pace in the plan derives from, so moving it IS becoming a faster runner.
    static func fiveKProjection(p5kSPerKm: Double, experience: ExperienceLevel, weeks: Int,
                                intensity: PlanIntensity = .podium) -> (nowS: Double, builtS: Double)? {
        guard p5kSPerKm > 0, weeks > 0 else { return nil }
        let now = p5kSPerKm * 5
        return (nowS: now,
                builtS: now * (1 - PlanFeasibility.achievableImprovement(experience: experience, weeks: weeks, intensity: intensity)))
    }
}
