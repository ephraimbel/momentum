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
    /// backward — the built number is always ≤ today's.
    static func raceProjection(raceDistanceM: Double, p5kSPerKm: Double, goalFinishTimeS: Double?,
                               experience: ExperienceLevel, weeks: Int) -> (nowS: Double, builtS: Double)? {
        guard raceDistanceM > 0, p5kSPerKm > 0, weeks > 0 else { return nil }
        let now = PlanFeasibility.predictedFinishS(distanceM: raceDistanceM, p5kSPerKm: p5kSPerKm)
        let achievable = now * (1 - PlanFeasibility.achievableImprovement(experience: experience, weeks: weeks))
        let built = goalFinishTimeS.map { max($0, achievable) } ?? achievable
        return (nowS: now, builtS: min(built, now))
    }

    /// No-race path ("become great"): the same model pointed at the athlete's own 5K — the number
    /// every other pace in the plan derives from, so moving it IS becoming a faster runner.
    static func fiveKProjection(p5kSPerKm: Double, experience: ExperienceLevel,
                                weeks: Int) -> (nowS: Double, builtS: Double)? {
        guard p5kSPerKm > 0, weeks > 0 else { return nil }
        let now = p5kSPerKm * 5
        return (nowS: now,
                builtS: now * (1 - PlanFeasibility.achievableImprovement(experience: experience, weeks: weeks)))
    }
}
