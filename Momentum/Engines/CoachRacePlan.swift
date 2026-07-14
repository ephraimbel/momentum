import Foundation

/// The race plan card — pacing, splits strategy, warmup, and fueling for the athlete's actual race,
/// derived from their calibrated fitness (Daniels/VDOT) and the plan's honesty check. Deterministic:
/// every number comes from the engines; the coach only presents it.
@MainActor
enum CoachRacePlan {

    static func sections(profile: UserProfile, today: Date = Date(),
                         calendar: Calendar = .current) -> [CoachSection] {
        guard let raceDate = profile.raceDate,
              let distanceM = profile.raceDistanceM, distanceM > 0,
              let plan = profile.plan, plan.p5kSPerKm > 0 else { return [] }
        var out: [CoachSection] = []
        let unit = DistanceUnit(rawValue: profile.distanceUnit) ?? .auto
        let race = RaceDistance.nearest(toMeters: distanceM)
        let daysOut = max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: today),
                                                     to: calendar.startOfDay(for: raceDate)).day ?? 0)

        // 1. The honest read — what's realistic from current fitness, vs the stated goal.
        let racePace = DanielsPaces.racePaceSPerKm(distanceM: distanceM, p5kSPerKm: plan.p5kSPerKm)
        let projectedS = racePace * distanceM / 1000
        var verdict = "From your current fitness, \(race.label) pace is \(Formatters.pace(secPerKm: racePace, unit: unit)) — about \(PlanFeasibility.hms(projectedS)) on race day."
        if let goalS = profile.goalFinishTimeS {
            let delta = goalS - projectedS
            if abs(delta) <= 60 {
                verdict += " That's right on your \(PlanFeasibility.hms(goalS)) goal."
            } else if delta > 0 {
                verdict += " Your \(PlanFeasibility.hms(goalS)) goal has \(PlanFeasibility.hms(delta)) of headroom. Bank it."
            } else {
                verdict += " Your \(PlanFeasibility.hms(goalS)) goal asks for \(PlanFeasibility.hms(-delta)) more — honest truth: run the fitness you have on the day."
            }
        }
        out.append(CoachSection(icon: "gauge.with.needle", title: "The number", detail: verdict))

        // 2. How to spend it — even-to-negative splits, framed by distance.
        let split: String = distanceM >= RaceDistance.half.meters
            ? "First third comfortable and controlled, middle third locked on pace, last third is where the race happens. Going out \(seconds(10)) fast costs minutes late — even splits win."
            : "Settle into pace inside the first \(distanceM >= RaceDistance.tenK.meters ? "kilometer" : "half kilometer"), hold steady through the middle, and empty the tank over the final quarter."
        out.append(CoachSection(icon: "chart.line.flattrend.xyaxis", title: "How to run it", detail: split))

        // 3. Warmup — sized to the distance (short races need more, marathons need almost none).
        let warmup = distanceM <= RaceDistance.tenK.meters
            ? "10–15 minutes easy jogging, then 4 strides at race effort, finishing about 10 minutes before the gun."
            : "5–10 minutes easy at most — the first kilometers are the warmup. Save every match for after halfway."
        out.append(CoachSection(icon: "figure.walk", title: "Warmup", detail: warmup))

        // 4. Fueling — from the projected duration, race rules (practiced in training, never new).
        let fueling = FuelingGuide.guidance(durationS: projectedS, isRace: true)
        var fuelLine = fueling.headline
        if let carbs = fueling.carbsPerHour {
            fuelLine += " Aim for \(carbs.lowerBound)–\(carbs.upperBound) g of carbs per hour, starting early. Nothing new on race day."
        }
        out.append(CoachSection(icon: "takeoutbag.and.cup.and.straw", title: "Fueling", detail: fuelLine))

        // 5. The runway — where they are relative to the day.
        let runway: String
        switch daysOut {
        case 0: runway = "Race day. Trust the block — the work is already in your legs."
        case 1...3: runway = "\(daysOut) day\(daysOut == 1 ? "" : "s") out: short, easy movement only. Sleep is training now."
        case 4...14: runway = "\(daysOut) days out — taper territory. Volume drops, fitness doesn't. Feeling twitchy is normal and good."
        default: runway = "\(daysOut) days out. Keep stacking the plan; the taper will handle the rest."
        }
        out.append(CoachSection(icon: "calendar", title: "Where you are", detail: runway))

        return out
    }

    private static func seconds(_ n: Int) -> String { "\(n) seconds per kilometer" }
}
