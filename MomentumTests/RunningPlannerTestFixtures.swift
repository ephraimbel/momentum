import Foundation
@testable import Momentum

enum RunningPlannerTestFixtures {
    enum Family: String, CaseIterable, Sendable {
        case startReturn
        case fiveKTenK
        case halfMarathon
        case marathon
    }

    struct GoldenPersona: Sendable {
        var id: String
        var family: Family
        var intent: String
        var inputs: PlanInputs
        var calibration: CalibrationSeed
        var expectedDigest: String
    }

    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        value.minimumDaysInFirstWeek = 4
        return value
    }

    static var startDate: Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
    }

    static func raceDate(weeks: Int, dayOffset: Int = 5) -> Date {
        calendar.date(
            byAdding: .day,
            value: (max(1, weeks) - 1) * 7 + min(6, max(0, dayOffset)),
            to: startDate
        )!
    }

    /// Full equipment coverage keeps evaluator failures about planning rather than a deliberately
    /// incomplete exercise catalog. Every automatic strength slot has a rep-countable fallback.
    static var catalog: [ExerciseCatalogItem] {
        func item(_ name: String,
                  _ muscle: MuscleGroup,
                  _ equipment: EquipmentType,
                  _ category: ExerciseCategory = .compound) -> ExerciseCatalogItem {
            ExerciseCatalogItem(
                name: name,
                primaryMuscles: [muscle],
                secondaryMuscles: [],
                equipment: equipment,
                category: category,
                defaultRestS: category == .compound ? 120 : 75,
                trackingMode: equipment == .bodyweight ? .repsOnly : .weightReps
            )
        }

        return [
            item("Back squat", .quads, .barbell), item("Goblet squat", .quads, .dumbbell),
            item("Split squat", .quads, .bodyweight), item("Band squat", .quads, .band),
            item("Bench press", .chest, .barbell), item("Dumbbell press", .chest, .dumbbell),
            item("Push-up", .chest, .bodyweight), item("Band press", .chest, .band),
            item("Barbell row", .back, .barbell), item("One-arm row", .back, .dumbbell),
            item("Inverted row", .back, .bodyweight), item("Band row", .back, .band),
            item("Overhead press", .shoulders, .barbell), item("Dumbbell overhead press", .shoulders, .dumbbell),
            item("Pike push-up", .shoulders, .bodyweight), item("Band overhead press", .shoulders, .band),
            item("Romanian deadlift", .hamstrings, .barbell), item("Dumbbell RDL", .hamstrings, .dumbbell),
            item("Hamstring walkout", .hamstrings, .bodyweight), item("Band leg curl", .hamstrings, .band, .isolation),
            item("Hip thrust", .glutes, .barbell), item("Dumbbell hip thrust", .glutes, .dumbbell),
            item("Single-leg bridge", .glutes, .bodyweight), item("Band hip extension", .glutes, .band, .isolation),
            item("Standing calf raise", .calves, .barbell, .isolation), item("Dumbbell calf raise", .calves, .dumbbell, .isolation),
            item("Single-leg calf raise", .calves, .bodyweight, .isolation), item("Band calf press", .calves, .band, .isolation),
            item("Barbell curl", .biceps, .barbell, .isolation), item("Dumbbell curl", .biceps, .dumbbell, .isolation),
            item("Chin-up", .biceps, .bodyweight), item("Band curl", .biceps, .band, .isolation),
            item("Close-grip press", .triceps, .barbell), item("Dumbbell extension", .triceps, .dumbbell, .isolation),
            item("Diamond push-up", .triceps, .bodyweight), item("Band pushdown", .triceps, .band, .isolation),
            item("Barbell rollout", .core, .barbell, .isolation), item("Dumbbell dead bug", .core, .dumbbell, .isolation),
            item("Dead bug", .core, .bodyweight, .isolation), item("Band anti-rotation press", .core, .band, .isolation),
        ]
    }

    static func base(goal: Goal,
                     days: Int,
                     experience: ExperienceLevel,
                     currentWeeklyM: Double?) -> PlanInputs {
        var value = PlanInputs(
            disciplines: [.running],
            goal: goal,
            daysPerWeek: days,
            equipment: .fullGym,
            sessionMinutes: 60,
            raceDate: nil,
            runningExperience: experience,
            liftingExperience: .some
        )
        value.currentWeeklyVolumeM = currentWeeklyM
        value.longestRunM = currentWeeklyM.map { min(32_000, $0 * 0.35) }
        value.distanceUnit = .metric
        return value
    }

    static var goldenPersonas: [GoldenPersona] {
        var result: [GoldenPersona] = []
        func add(_ id: String,
                 _ family: Family,
                 _ intent: String,
                 _ inputs: PlanInputs,
                 _ calibration: CalibrationSeed = .none) {
            guard let expectedDigest = expectedDigests[id] else {
                preconditionFailure("Missing semantic baseline for \(id)")
            }
            result.append(GoldenPersona(
                id: id,
                family: family,
                intent: intent,
                inputs: inputs,
                calibration: calibration,
                expectedDigest: expectedDigest
            ))
        }

        var p = base(goal: .stayConsistent, days: 3, experience: .new, currentWeeklyM: 6_000)
        p.intensity = .gentle
        add("start.first-steps.3d", .startReturn, "First repeatable three-day running block", p)

        p = base(goal: .raceDistance, days: 3, experience: .new, currentWeeklyM: 8_000)
        p.raceDistanceM = 5_000; p.raceDate = raceDate(weeks: 12, dayOffset: 5)
        add("start.first-5k.12w", .startReturn, "First 5K completion with adequate runway", p)

        p = base(goal: .raceDistance, days: 3, experience: .new, currentWeeklyM: 10_000)
        p.raceDistanceM = 5_000; p.raceDate = raceDate(weeks: 4, dayOffset: 6)
        add("start.first-5k.4w", .startReturn, "First 5K on a short runway", p)

        p = base(goal: .endurance, days: 4, experience: .new, currentWeeklyM: 12_000)
        p.intensity = .gentle; p.injuryHistory = [.shins]
        add("start.return-shins.4d", .startReturn, "Returning runner with historical shin modifier", p)

        p = base(goal: .generalFitness, days: 3, experience: .new, currentWeeklyM: 10_000)
        p.age = 62; p.intensity = .balanced
        add("start.masters-return.3d", .startReturn, "Masters return with more frequent absorption", p)

        p = base(goal: .buildMuscle, days: 4, experience: .new, currentWeeklyM: 9_000)
        p.disciplines = [.running, .strength]; p.equipment = .bodyweight; p.hybridPriority = .balanced
        add("start.bodyweight-support.4d", .startReturn, "Bodyweight strength supporting a first running block", p)

        p = base(goal: .stayConsistent, days: 2, experience: .new, currentWeeklyM: 7_000)
        p.distanceUnit = .imperial; p.sessionMinutes = 30
        add("start.imperial-two-days", .startReturn, "Two-day habit in imperial prescription units", p)

        p = base(goal: .generalFitness, days: 4, experience: .new, currentWeeklyM: nil)
        p.sessionMinutes = 40
        add("start.sparse-baseline", .startReturn, "No volume history; experience fallback only", p)

        p = raceBase(distanceM: 5_000, weeks: 10, days: 4, experience: .some, weeklyM: 25_000)
        add("road.5k-recreational", .fiveKTenK, "Recreational 5K build", p)

        p = raceBase(distanceM: 5_000, weeks: 12, days: 5, experience: .some, weeklyM: 35_000)
        p.goalFinishTimeS = 22 * 60
        add("road.5k-22min", .fiveKTenK, "5K finish-time pursuit with recent evidence", p,
            CalibrationSeed(recentRun: (5_000, 23 * 60), estimatedP5kSPerKm: nil, lifts: [:]))

        p = raceBase(distanceM: 5_000, weeks: 8, days: 6, experience: .experienced, weeklyM: 55_000)
        p.intensity = .podium; p.goalFinishTimeS = 17 * 60 + 30
        add("road.5k-podium", .fiveKTenK, "Experienced six-day 5K front-pack build", p,
            CalibrationSeed(recentRun: nil, estimatedP5kSPerKm: 215, lifts: [:]))

        p = raceBase(distanceM: 5_000, weeks: 10, days: 5, experience: .some, weeklyM: 32_000)
        p.intensity = .aggressive; p.injuryHistory = [.calf]
        add("road.5k-history", .fiveKTenK, "5K build with speed-sensitive history modifier", p)

        p = raceBase(distanceM: 10_000, weeks: 10, days: 4, experience: .some, weeklyM: 30_000)
        add("road.10k-recreational", .fiveKTenK, "Recreational 10K build", p)

        p = raceBase(distanceM: 10_000, weeks: 14, days: 5, experience: .some, weeklyM: 42_000)
        p.goalFinishTimeS = 45 * 60; p.intensity = .aggressive
        add("road.10k-45min", .fiveKTenK, "Ten-kilometer finish-time pursuit", p)

        p = raceBase(distanceM: 10_000, weeks: 12, days: 5, experience: .experienced, weeklyM: 50_000)
        p.age = 57; p.goalFinishTimeS = 48 * 60
        add("road.10k-masters", .fiveKTenK, "Experienced masters 10K build", p)

        p = raceBase(distanceM: 10_000, weeks: 16, days: 5, experience: .some, weeklyM: 36_000)
        p.disciplines = [.running, .strength]; p.equipment = .dumbbellsOnly
        p.hybridPriority = .running; p.strengthSplit = .upperLower
        add("road.10k-strength-support", .fiveKTenK, "10K plan with two runner-strength exposures", p,
            CalibrationSeed(recentRun: nil, estimatedP5kSPerKm: 285, lifts: ["Back squat": 95]))

        p = raceBase(distanceM: 21_097.5, weeks: 16, days: 4, experience: .some, weeklyM: 25_000)
        add("half.first-finish", .halfMarathon, "First half-marathon completion build", p)

        p = raceBase(distanceM: 21_097.5, weeks: 16, days: 5, experience: .some, weeklyM: 40_000)
        p.goalFinishTimeS = 105 * 60
        add("half.1h45", .halfMarathon, "One-hour-forty-five half-marathon pursuit", p)

        p = raceBase(distanceM: 21_097.5, weeks: 18, days: 6, experience: .experienced, weeklyM: 70_000)
        p.goalFinishTimeS = 85 * 60; p.intensity = .podium
        add("half.1h25-podium", .halfMarathon, "High-volume competitive half build", p)

        p = raceBase(distanceM: 21_097.5, weeks: 18, days: 5, experience: .some, weeklyM: 36_000)
        p.goalFinishTimeS = 120 * 60; p.age = 60
        add("half.masters-2h", .halfMarathon, "Masters half with two-hour target", p)

        p = raceBase(distanceM: 21_097.5, weeks: 20, days: 4, experience: .some, weeklyM: 30_000)
        p.injuryHistory = [.achilles]; p.intensity = .gentle
        add("half.achilles-history", .halfMarathon, "Half build with Achilles history modifier", p)

        p = raceBase(distanceM: 21_097.5, weeks: 6, days: 4, experience: .some, weeklyM: 30_000)
        add("half.short-runway", .halfMarathon, "Half marathon with limited runway", p)

        p = raceBase(distanceM: 21_097.5, weeks: 18, days: 5, experience: .some, weeklyM: 38_000)
        p.disciplines = [.running, .strength]; p.equipment = .homeMinimal; p.distanceUnit = .imperial
        p.hybridPriority = .running
        add("half.imperial-hybrid", .halfMarathon, "Imperial half build with home strength", p)

        p = raceBase(distanceM: 21_097.5, weeks: 30, days: 5, experience: .experienced, weeklyM: 55_000)
        p.targetWeeklyVolumeM = 72_000
        add("half.long-runway-cap", .halfMarathon, "Long runway with an explicit mileage ceiling", p)

        p = raceBase(distanceM: 42_195, weeks: 20, days: 5, experience: .some, weeklyM: 40_000)
        add("marathon.first-finish", .marathon, "First marathon completion build", p)

        p = raceBase(distanceM: 42_195, weeks: 20, days: 5, experience: .some, weeklyM: 45_000)
        p.goalFinishTimeS = 4 * 3600
        add("marathon.4h", .marathon, "Four-hour marathon pursuit", p)

        p = raceBase(distanceM: 42_195, weeks: 24, days: 6, experience: .experienced, weeklyM: 65_000)
        p.goalFinishTimeS = 3 * 3600 + 30 * 60; p.intensity = .aggressive
        add("marathon.3h30", .marathon, "Experienced 3:30 marathon build", p,
            CalibrationSeed(recentRun: (10_000, 45 * 60), estimatedP5kSPerKm: nil, lifts: [:]))

        p = raceBase(distanceM: 42_195, weeks: 24, days: 6, experience: .experienced, weeklyM: 100_000)
        p.goalFinishTimeS = 2 * 3600 + 50 * 60; p.intensity = .podium
        add("marathon.2h50-podium", .marathon, "High-volume competitive marathon build", p,
            CalibrationSeed(recentRun: (10_000, 36 * 60), estimatedP5kSPerKm: nil, lifts: [:]))

        p = raceBase(distanceM: 42_195, weeks: 22, days: 5, experience: .some, weeklyM: 42_000)
        p.goalFinishTimeS = 4 * 3600 + 15 * 60; p.age = 61
        add("marathon.masters-4h15", .marathon, "Masters marathon with recovery cadence", p)

        p = raceBase(distanceM: 42_195, weeks: 24, days: 5, experience: .some, weeklyM: 38_000)
        p.injuryHistory = [.knee]; p.intensity = .gentle
        add("marathon.knee-history", .marathon, "Marathon with conservative historical modifier", p)

        p = raceBase(distanceM: 42_195, weeks: 8, days: 5, experience: .some, weeklyM: 35_000)
        p.goalFinishTimeS = 4 * 3600
        add("marathon.short-runway", .marathon, "Marathon target with an eight-week runway", p)

        p = raceBase(distanceM: 42_195, weeks: 60, days: 5, experience: .experienced, weeklyM: 60_000)
        p.targetWeeklyVolumeM = 85_000; p.goalFinishTimeS = 3 * 3600 + 20 * 60
        add("marathon.foundation-horizon", .marathon, "Race beyond 52 weeks; foundation block only", p)

        precondition(result.count == 32)
        precondition(Set(result.map(\.id)) == Set(expectedDigests.keys))
        return result
    }

    private static func raceBase(distanceM: Double,
                                 weeks: Int,
                                 days: Int,
                                 experience: ExperienceLevel,
                                 weeklyM: Double) -> PlanInputs {
        var value = base(goal: .raceDistance, days: days, experience: experience, currentWeeklyM: weeklyM)
        value.raceDistanceM = distanceM
        value.raceDate = raceDate(weeks: weeks, dayOffset: weeks.isMultiple(of: 2) ? 5 : 6)
        return value
    }

    /// Filled from the shipping legacy engine once and reviewed as a single versioned baseline.
    /// Updating a digest requires inspecting the classified semantic diff, not blind regeneration.
    private static let expectedDigests: [String: String] = [
        "start.first-steps.3d": "330318c5e4ccea008678925a7219c8cb51edde9a6c48b47426b5c1e79ecf0bb5",
        "start.first-5k.12w": "8fdb3ceb332f8e4ba7face5f3fa2755582502ee052ed66cbd143723f94282155",
        "start.first-5k.4w": "4474d8dd7a6aa817ba2dd56bbc94d484069a71d38bab4cd89e7fdadacf7d8eed",
        "start.return-shins.4d": "1071d07d5ef5290758fe4448eb6a3cd402f39648708382faaf9303e2dbc1b35d",
        "start.masters-return.3d": "0642a9cc1d520980b343d1ea9511013d16c5360498c4006410292be6fdd32cae",
        "start.bodyweight-support.4d": "1b34f2a1f6a91df19f3ef153f85d24ac80743e1027c93f6022ebab5db33c88bf",
        "start.imperial-two-days": "741e46c9169aa2da58dbc0294df68773e5613a55aae0025da8d49e2195f00103",
        "start.sparse-baseline": "c468461c3fc5b569c9b8ee6bbc0e44a1606e123d82ba811b34c8ad8d6c89149e",
        "road.5k-recreational": "ead6db6ce5adc8d2ac872f9db4204abe50556ffbcf376c5586f1c5dd16b257ab",
        "road.5k-22min": "a0c882ab8f2ac0e77072ca301d2bd290ea652a5c9be50eec5a50185ed0fed63d",
        "road.5k-podium": "53643f9f8f2e4371fbf88883f75eb73c3e713889bddcba456b4e7bcbb95952b3",
        "road.5k-history": "d2dc5e54689abdc79883815396d664b172456fb7284dc342738acd943cd88760",
        "road.10k-recreational": "ac45aa48882c080056391b573fd20d81ae592079fcad3d801db9b57f62f07959",
        "road.10k-45min": "5db6c9ceb1317167409995d3ab3435f892db35bcdecf6970a3b3d8b453aef624",
        "road.10k-masters": "b28f4275eabb16fc1a45046c9af084d817ada68382d5b86a912c9c736860c9e5",
        "road.10k-strength-support": "e19a818ecff1df4f65522f7a7aca4c6df1fe58f76f32d40e01b06c610236c00c",
        "half.first-finish": "8b3eb9d8e59a36a05afcfe2d695d0d18202170c730b63c7ea4a318a1c173054f",
        "half.1h45": "7ed7ca878d035a17fbd9b6bd62c0143a29cc58931e8f7be8b3fd12981e4874ee",
        "half.1h25-podium": "2cfbcaa929edc2e1f03ebdead26889e756552497723e703299774cff3eb42fa7",
        "half.masters-2h": "b2d8208c44c1bd513103d21eb118d0c23f3fa61bc45bb3a17f00fd6e40c84b36",
        "half.achilles-history": "848ed7b0dad8be2389b341c8bdabc104c5d831bf1c93355aec54824b72cfa85a",
        "half.short-runway": "7227571217b18dfe72075cd621f7eafd7007885ed4c0080e7c568861da0f6138",
        "half.imperial-hybrid": "1bc389f628e039a7efcf5805cf38dd90610511a6a7b644bac6bbe42248155c31",
        "half.long-runway-cap": "c050942f7e6f4fe42a1b4e003495c0b63c3ffa9c9b33fbe1fcad67daaaedfdad",
        "marathon.first-finish": "e3f6c76baec9515c54d0061be47c32939d38abbd88c965ce7020a65640dd476a",
        "marathon.4h": "3c9e1c4db91a501248a65cc3e34f7952aa05feb0f77be97edc08d50ef86b5053",
        "marathon.3h30": "34915e6ecc5ed0c6eda6dfb1f0962307131c690fe66f41375a17a56c71004a69",
        "marathon.2h50-podium": "a13731a359fa36923e47c15ff5f6ef5459ee1f13a5402470256e244f6a5564cc",
        "marathon.masters-4h15": "31a0a13fe07a0f3a123efb3fb98bbd60547ac467baa1be3f6b4d5791381f6b34",
        "marathon.knee-history": "414f6fc9abcbc700b876ce701edcb653bd4f3ae20ef54cbdeeeec1ea550369c6",
        "marathon.short-runway": "6a877a2468d6457a39f9c1bc9cb2b28b7b5b5a3f76b26c08bdfa34dfc4ffd4ba",
        "marathon.foundation-horizon": "2a36666194f4c3d9cb3a3a150c7e5d579fb669f8cdc2400990e022264dbd213a",
    ]
}
