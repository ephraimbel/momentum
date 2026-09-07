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
        "start.first-steps.3d": "f02048150ac3782ae5b048cf5649983d5059431d4791b28f72104d604ecdd5de",
        "start.first-5k.12w": "113b22202875a45f8287bb856d28fa6e4317d58358103be3d4a8f71a4620ebca",
        "start.first-5k.4w": "e474bd9bd2590ef9d5b218b599ec3590648a724dfb1a17058d3dee89d1d95013",
        "start.return-shins.4d": "ebdc45a59033904bee1b8d7072ac2ca90d130bebd07f96b9f1d51be5cd81ccc1",
        "start.masters-return.3d": "ef7621dc6ece9ab4fc3f4f33eb93d9dadb64efea9a5303e306aca0d80576cbe9",
        "start.bodyweight-support.4d": "96aeece308eaeab18134814a90091ae1e988ef48ceb6a79ba6ed029255038f9e",
        "start.imperial-two-days": "77fa6dd208e3615aaccae6cb933fc2572998a5154cc25935fbd33b893d9a7524",
        "start.sparse-baseline": "f0e98bc2ac7fb4b16d96e4c057a376c23b6cacbb25a6a78294cc852e3bd14d21",
        "road.5k-recreational": "08857702a55796351fcfa22f44014008fed6b679a40fe599488e5bf57a8df089",
        "road.5k-22min": "8a0cf109b34082763fd69be89846e3a62ce66bbe401e8094f210739e3bc66993",
        "road.5k-podium": "53643f9f8f2e4371fbf88883f75eb73c3e713889bddcba456b4e7bcbb95952b3",
        "road.5k-history": "da7360f054bb32d8823057d438cd2ebf8ea32e1f31a7422bb2476250a630ed93",
        "road.10k-recreational": "dbb7df87f60f4cc828fd59f8993bcc4c2af72bc8f6ff5cafe231b383cda20683",
        "road.10k-45min": "dd13c0e0ef56f13fbe771b6d9a279505772211eafd372e1915a77b1354535a58",
        "road.10k-masters": "91d2d23b1dbb4a4213c81b87649df7e3e324bc527d82cee412849a67f32dd17d",
        "road.10k-strength-support": "9b1ad2b920f2c9d860dcdb76954ab80651fcb0fbbc602adaf2214970c71dc6ab",
        "half.first-finish": "f2b1008b6e210e3a451e5241754468b029b7d53fc9c5235adcac03c36ba2564d",
        "half.1h45": "65bf32f4bb0de160ee4c0080b235a3c92dc770aeba4575ec14e27e666b6a9788",
        "half.1h25-podium": "e2003337094afb2ea64b61730c791c82052781d5a47f3d49ef3159a4ae2ec9cf",
        "half.masters-2h": "223e47e12c22cd317cd093e51937f6f5fc1dde6876b91eda21b37ccf5490614e",
        "half.achilles-history": "ead0e1c2cc090f9cd3e490f41f20bd1e17405bb4badf2e3c98370efb7c7fb58f",
        "half.short-runway": "746667daba44ebeb0e7004079471337bb25ec8977fa873eac44d1b4ba322b80c",
        "half.imperial-hybrid": "84d6696bc4d691ad1e18ddf622a1e0d34f165c22c88e341719871c28cdfc4c41",
        "half.long-runway-cap": "5962f2b4404855b1e9d911cc076208cd2b4cea6fbb22bf32de1c7830ef53d005",
        "marathon.first-finish": "b6e877b1f2da6a655ec2d4a69eeb2c285bd7bc27ddb1a7af71a22d657f473c6c",
        "marathon.4h": "0e50e429ecbc6a9b58546511b60b18619b9642258a9c57bdbf41ba12d672c951",
        "marathon.3h30": "a2e6b98aa01d7e5fcc48ebf04135b6844ed9e808bfd3993d9bff2c6a7802ec46",
        "marathon.2h50-podium": "6286f989292c190476dbde367975b47d569ea286bcc26719ba9e82b1a15a3136",
        "marathon.masters-4h15": "85683f3f42cb260c4bb3592923dd1f877990f30cb5c06261e76e829880881bae",
        "marathon.knee-history": "83a2f0b219695ca3cda61fdd667bae4dfab8b24d9483740715b984fb378f3efd",
        "marathon.short-runway": "f43e2abcc5fb78124a4fba93ea05d3a1c1d5fe1ed6e0694d3add3fda277bb10d",
        "marathon.foundation-horizon": "fcc4c5592435ac30697cbde664cc343e1e52c9e724f6b15536e1b72c611ae017",
    ]
}
