import Foundation

/// The pre-race briefing (ENDURANCE-FOCUS §12.1) — as race day approaches, the coach shows up in the
/// inbox with the things that actually matter: taper discipline, carb-loading, kit, and the fueling
/// plan sized to *their* predicted finish. Deterministic; nothing new on race week.
enum RaceBriefing {
    struct Briefing: Sendable, Equatable {
        let title: String
        let body: String
    }

    /// A briefing for `daysOut` (0 = race day, 1 = eve, 2–3 = final approach); nil outside the window.
    /// The fueling plan is sized from the *predicted* finish (Riegel off current fitness), in race mode.
    static func build(distanceM: Double, p5kSPerKm: Double, daysOut: Int) -> Briefing? {
        guard (0...3).contains(daysOut), distanceM > 0, p5kSPerKm > 0 else { return nil }
        let label = RaceDistance.nearest(toMeters: distanceM).label
        let predicted = PlanFeasibility.predictedFinishS(distanceM: distanceM, p5kSPerKm: p5kSPerKm)
        let fuel = FuelingGuide.guidance(durationS: predicted, isRace: true)

        switch daysOut {
        case 0:
            return Briefing(
                title: "Race day — go get your \(label)",
                body: "The work is banked; trust it. Start controlled — the first miles should feel too easy. \(fuel.during)")
        case 1:
            return Briefing(
                title: "Tomorrow is race day",
                body: "\(fuel.before) Lay out your kit tonight, plan your morning backwards from the start gun — and nothing new tomorrow: no new shoes, foods, or pace plans.")
        default:
            return Briefing(
                title: "\(daysOut) days to your \(label)",
                body: "Taper means taper: short, easy, and done. Sleep is training now. Start leaning your meals toward carbs — arrive topped up, not stuffed.")
        }
    }
}
