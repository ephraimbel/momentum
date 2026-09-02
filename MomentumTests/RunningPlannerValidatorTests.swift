import Foundation
import Testing
@testable import Momentum

struct RunningPlannerValidatorTests {
    private var start: Date { RunningPlannerTestFixtures.startDate }
    private var calendar: Calendar { RunningPlannerTestFixtures.calendar }

    @Test func shippingPlanPassesTheApplicableHardInvariants() throws {
        let persona = try #require(
            RunningPlannerTestFixtures.goldenPersonas.first { $0.id == "half.1h45" }
        )
        let plan = PlanEngine.generate(
            profile: persona.inputs,
            catalog: RunningPlannerTestFixtures.catalog,
            calibration: persona.calibration,
            startDate: start,
            calendar: calendar
        )

        let report = LegacyPlanInvariantValidator.validate(
            plan,
            inputs: persona.inputs,
            calibration: persona.calibration,
            startDate: start,
            calendar: calendar
        )

        if !report.isValid {
            let details = report.hardViolations.map(\.detail).joined(separator: " | ")
            Issue.record("Validator issues: \(details)")
        }
        #expect(report.isValid)
    }

    @Test func validatorRejectsNonFinitePrescriptions() {
        var inputs = RunningPlannerTestFixtures.base(
            goal: .stayConsistent,
            days: 1,
            experience: .some,
            currentWeeklyM: 5_000
        )
        inputs.distanceUnit = .metric
        let malformed = GeneratedPlan(
            p5kSPerKm: .nan,
            weeks: [
                GeneratedWeek(
                    index: 0,
                    isDeload: false,
                    isTaper: false,
                    sessions: [
                        GeneratedSession(
                            dayOffset: 0,
                            discipline: .running,
                            runType: .easy,
                            targetDistanceM: .infinity,
                            targetDurationS: nil,
                            targetPaceSPerKm: .nan,
                            intervals: nil,
                            strengthLabel: nil,
                            rationale: nil
                        ),
                    ]
                ),
            ]
        )

        let codes = Set(LegacyPlanInvariantValidator.validate(
            malformed,
            inputs: inputs,
            startDate: start,
            calendar: calendar
        ).hardViolations.map(\.code))

        #expect(codes.contains(.invalidPlanPace))
        #expect(codes.contains(.invalidDistance))
        #expect(codes.contains(.invalidSessionPace))
        #expect(codes.contains(.invalidWeeklyVolume))
    }

    @Test func validatorRejectsDuplicateDaysAndMixedModalities() throws {
        let persona = try #require(
            RunningPlannerTestFixtures.goldenPersonas.first { $0.id == "road.5k-recreational" }
        )
        var corrupted = PlanEngine.generate(
            profile: persona.inputs,
            catalog: RunningPlannerTestFixtures.catalog,
            calibration: persona.calibration,
            startDate: start,
            calendar: calendar
        )
        let first = try #require(corrupted.weeks[0].sessions.first)
        corrupted.weeks[0].sessions.append(first)
        corrupted.weeks[0].sessions[0].strengthTargets = [
            GeneratedExercise(
                exerciseName: "Unexpected squat",
                targetSets: 3,
                repLow: 5,
                repHigh: 5,
                targetRPE: 7,
                targetPctRM: nil,
                progression: "rpe"
            ),
        ]

        let codes = Set(LegacyPlanInvariantValidator.validate(
            corrupted,
            inputs: persona.inputs,
            calibration: persona.calibration,
            startDate: start,
            calendar: calendar
        ).hardViolations.map(\.code))

        #expect(codes.contains(.duplicateTrainingDay))
        #expect(codes.contains(.mixedSessionModalities))
    }

    @Test func validatorRejectsTrainingAfterTheTerminalRace() throws {
        let persona = try #require(
            RunningPlannerTestFixtures.goldenPersonas.first { $0.id == "marathon.4h" }
        )
        var corrupted = PlanEngine.generate(
            profile: persona.inputs,
            catalog: RunningPlannerTestFixtures.catalog,
            calibration: persona.calibration,
            startDate: start,
            calendar: calendar
        )
        let lastWeek = try #require(corrupted.weeks.indices.last)
        let race = try #require(corrupted.weeks[lastWeek].sessions.first { $0.runType == .race })
        corrupted.weeks[lastWeek].sessions.append(
            GeneratedSession(
                dayOffset: race.dayOffset,
                discipline: .running,
                runType: .easy,
                targetDistanceM: 1_000,
                targetDurationS: nil,
                targetPaceSPerKm: corrupted.p5kSPerKm + 60,
                intervals: nil,
                strengthLabel: nil,
                rationale: nil
            )
        )

        let codes = Set(LegacyPlanInvariantValidator.validate(
            corrupted,
            inputs: persona.inputs,
            calibration: persona.calibration,
            startDate: start,
            calendar: calendar
        ).hardViolations.map(\.code))

        #expect(codes.contains(.trainingAfterTerminalRace))
    }

    @Test func knownLegacyGapsAreTypedInsteadOfSilentlyBlessed() {
        var inputs = RunningPlannerTestFixtures.base(
            goal: .raceDistance,
            days: 9,
            experience: .new,
            currentWeeklyM: 8_000
        )
        inputs.intensity = .podium
        inputs.raceDate = calendar.date(byAdding: .day, value: -2, to: start)
        inputs.distanceUnit = .auto
        let calibration = CalibrationSeed(
            recentRun: nil,
            estimatedP5kSPerKm: 360,
            lifts: ["Back squat": 60]
        )
        let plan = PlanEngine.generate(
            profile: inputs,
            catalog: RunningPlannerTestFixtures.catalog,
            calibration: calibration,
            startDate: start,
            calendar: calendar
        )
        var exceptions = Set(LegacyPlanInvariantValidator.validate(
            plan,
            inputs: inputs,
            calibration: calibration,
            startDate: start,
            calendar: calendar
        ).legacyExceptions.map(\.code))

        var podiumInputs = RunningPlannerTestFixtures.base(
            goal: .stayConsistent,
            days: 3,
            experience: .experienced,
            currentWeeklyM: 30_000
        )
        podiumInputs.intensity = .podium
        let podiumPlan = PlanEngine.generate(
            profile: podiumInputs,
            catalog: RunningPlannerTestFixtures.catalog,
            startDate: start,
            calendar: calendar
        )
        exceptions.formUnion(LegacyPlanInvariantValidator.validate(
            podiumPlan,
            inputs: podiumInputs,
            startDate: start,
            calendar: calendar
        ).legacyExceptions.map(\.code))

        #expect(exceptions.contains(.startReturnContinuityGateUnavailable))
        #expect(exceptions.contains(.strengthCalibrationUnused))
        #expect(exceptions.contains(.automaticUnitUsesProcessLocale))
        #expect(exceptions.contains(.dayBudgetIsSilentlyClamped))
        #expect(exceptions.contains(.podiumFloorIsNotATypedConflict))
        #expect(exceptions.contains(.raceGoalMissingDistanceIsNotATypedConflict))
        #expect(exceptions.contains(.pastRaceDateIsClamped))
    }

    @Test func finalLoadCapCannotEraseADownWeek() {
        // Seeded adversarial regression: low volume plus five imperial run prescriptions used to
        // snap every loading and deload week to the same 4,828 m total.
        let request = LegacyAdversarialPlanRequestGenerator.make(
            seed: 0x4D4F_4D45_4E54_554D,
            index: 244,
            startDate: start,
            calendar: calendar
        )
        let plan = PlanEngine.generate(
            profile: request.inputs,
            catalog: RunningPlannerTestFixtures.catalog,
            calibration: request.calibration,
            startDate: start,
            calendar: calendar
        )
        var lastLoadingVolume: Double?

        for week in plan.weeks {
            if week.isDeload || week.isTaper {
                if let previous = lastLoadingVolume, previous > 0 {
                    #expect(week.runVolumeM < previous, "Week \(week.index) did not reduce after final load capping")
                }
            } else if week.runVolumeM > 0 {
                lastLoadingVolume = week.runVolumeM
            }
        }
    }
}
