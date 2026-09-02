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
        "start.first-steps.3d": "5b2b7da57a0ee780f56343182c8238dcc73e2ad5252bb929ca9d143e7fb84aa3",
        "start.first-5k.12w": "61bb09eef6ebea2a062ee26fa251b65bf5c06a0b9924dac18b68ec2524e360d9",
        "start.first-5k.4w": "4888fa1bbb32884e798b9d551651e80f5e046da0dc2aedb186ab9efc71a8086e",
        "start.return-shins.4d": "1e4dceef25e984958b5bef97b2754802b2fb45bd53a0976a72de4dd5eac9dcd3",
        "start.masters-return.3d": "0c3e772d508ec9ac00846c106aaba716c292cd0a4d9cb8413f8f13b51a37c714",
        "start.bodyweight-support.4d": "2006c77f5f34d6114b2e009a84593cb304fff1cceb483d93e28ef58e4d08c6e8",
        "start.imperial-two-days": "bfea349fa1e5f8670cf3c9bec655dc81bdc5230d5822cb48d8dd67f0bac5eb6d",
        "start.sparse-baseline": "d2dfbf38af3a93b7ec0bd70573502ec123076aee21a7a8d8a4ff405c1d8d8014",
        "road.5k-recreational": "3102d8d0bdce5104b26c729e755ce1fef5df00cd8c074beb70e425d782c99336",
        "road.5k-22min": "2d6a167f164adc4c4b8129f141b0422e8adff501d645f966dc8644bf7fb0de0c",
        "road.5k-podium": "c5373f3ed18105f74d286574543a32c61e0e6c6323edb381c8476e30b5e34f95",
        "road.5k-history": "b864e929203642f78a49d7db2098be5e238a84ffca5feaddd4d72ad5fc8dd3f7",
        "road.10k-recreational": "9d94cb32e8c5b5008a9a2a51603129876815f37a658f3e7c13a8739dd0e27d2a",
        "road.10k-45min": "a3fa952caf9e565a31315a71ad93c32137f31d74603387db17cdb4486b2a6797",
        "road.10k-masters": "fd5a1c6e73eae3fb7101350e0763ba6f0f5411126b7ecc549dea523db70933e2",
        "road.10k-strength-support": "070a3446e7d5157bafc9cd800c14a863f7ea22d8317cc3b451b256a6c0d91588",
        "half.first-finish": "7b438e3113b3458ffe24af284db33b09f9c40ec0396efb9761ff5e93e0f427ad",
        "half.1h45": "eddf37c50e58afb34b5986e049a66d3106428361f143f8458bc96a7dfc7cea03",
        "half.1h25-podium": "19fdc1b68ea68fbb09837fcde2afad3169d2af95cea693c0bf0550ae6552ab29",
        "half.masters-2h": "aaaf3464e8368f3a0f956d69b8310c05f8e8aa51e060cec98bc9f3807fda44cc",
        "half.achilles-history": "470af299068e1d705379112aa77ffb3a74ae7590a5301d8202d56846e156686a",
        "half.short-runway": "c032ef56477c43bc4d2dcaac52e68249bd82aa20d30bab264866025004042efe",
        "half.imperial-hybrid": "aa6816e82acfb5acd1bc244037f5c78e03b6d7720c126fc945e8d218aee0afd0",
        "half.long-runway-cap": "438160e1003532aba8ea51505523195cd9a19ed91b5d1aa1b236b4d63b041b2d",
        "marathon.first-finish": "f5a9712318155b755cbef895715947eaaae511ea5bd7415bbbae802b15ce3a19",
        "marathon.4h": "20c32f9e2bb8ed0f48b7abaa2beb50bc8c2f3f50fd29e756c675abf0f28db804",
        "marathon.3h30": "f6e9043da27cdeeb5609d9129478051bea8bcaf15dafbe25ac3d114f446ede27",
        "marathon.2h50-podium": "39dfcff2598fffd51607a989ed17892a8be72ef8891e0bef2bb2c1bd76d998df",
        "marathon.masters-4h15": "88a3543604bda33288b82877ce934565c7d109ad66798d54126f1e86c0a1d3b6",
        "marathon.knee-history": "1e7dfc1921707db766d6e3742b97654fb099b836f37b03bc4996be393eb4edcf",
        "marathon.short-runway": "bb1218c8ee6af726ca87188f5c4561dd03df8a4b25b8a33aee8fce7948fd61d3",
        "marathon.foundation-horizon": "12133f3ddfaa9ced561cbd4db96f5dcfe4c4fdcafe0cb83c35dfb82789a94ce6",
    ]
}
