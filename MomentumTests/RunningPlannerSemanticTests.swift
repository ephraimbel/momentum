import Foundation
import SwiftData
import Testing
@testable import Momentum

@MainActor
struct RunningPlannerSemanticTests {
    private var fixture: RunningPlannerTestFixtures.GoldenPersona {
        RunningPlannerTestFixtures.goldenPersonas.first { $0.id == "half.1h45" }!
    }

    @Test func semanticDigestIsDeterministicAndIgnoresNarrative() throws {
        let persona = fixture
        let plan = PlanEngine.generate(
            profile: persona.inputs,
            catalog: RunningPlannerTestFixtures.catalog,
            calibration: persona.calibration,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar
        )
        var copy = plan
        for week in copy.weeks.indices {
            for session in copy.weeks[week].sessions.indices {
                copy.weeks[week].sessions[session].rationale = "Different prose that cannot move the plan."
            }
            copy.weeks[week].sessions.reverse()
        }
        copy.weeks.reverse()

        #expect(try plan.semanticDigest() == copy.semanticDigest())
        #expect(try plan.semanticSnapshot().canonicalData() == copy.semanticSnapshot().canonicalData())
    }

    @Test func numericPrescriptionChangeProducesAClassifiedDiff() throws {
        let persona = fixture
        let baseline = PlanEngine.generate(
            profile: persona.inputs,
            catalog: RunningPlannerTestFixtures.catalog,
            calibration: persona.calibration,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar
        )
        var changed = baseline
        let week = try #require(changed.weeks.firstIndex { week in
            week.sessions.contains { $0.discipline == .running && $0.runType != .race }
        })
        let session = try #require(changed.weeks[week].sessions.firstIndex {
            $0.discipline == .running && $0.runType != .race
        })
        changed.weeks[week].sessions[session].targetDistanceM =
            (changed.weeks[week].sessions[session].targetDistanceM ?? 0) + 500

        let diff = try PlanSemanticDiffer.compare(baseline, changed)
        #expect(!diff.isEquivalent)
        #expect(diff.categories == [.enduranceDose])
        #expect(diff.changes.count == 1)
        #expect(diff.changes[0].field == "targetDistanceMeters")
        #expect(diff.oldDigest != diff.newDigest)
    }

    @Test func everySemanticChangeFamilyIsClassified() throws {
        let persona = try #require(
            RunningPlannerTestFixtures.goldenPersonas.first {
                $0.id == "road.10k-strength-support"
            }
        )
        let baseline = PlanEngine.generate(
            profile: persona.inputs,
            catalog: RunningPlannerTestFixtures.catalog,
            calibration: persona.calibration,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar
        )
        var changed = baseline
        changed.p5kSPerKm += 1
        changed.goalRacePaceSPerKm = (changed.goalRacePaceSPerKm ?? 300) + 1
        changed.weeks[0].phase = changed.weeks[0].phase == .base ? .build : .base

        let run = try #require(changed.weeks[0].sessions.firstIndex { $0.discipline == .running })
        changed.weeks[0].sessions[run].runType = .fartlek
        changed.weeks[0].sessions[run].targetPaceSPerKm =
            (changed.weeks[0].sessions[run].targetPaceSPerKm ?? 300) + 5

        let strength = try #require(changed.weeks[0].sessions.firstIndex { $0.discipline == .strength })
        let exercise = try #require(changed.weeks[0].sessions[strength].strengthTargets.indices.first)
        changed.weeks[0].sessions[strength].strengthTargets[exercise].repHigh += 1
        changed.weeks[0].sessions.append(
            GeneratedSession(
                dayOffset: 99,
                discipline: .running,
                runType: .easy,
                targetDistanceM: 1_000,
                targetDurationS: nil,
                targetPaceSPerKm: 360,
                intervals: nil,
                strengthLabel: nil,
                rationale: "Narrative is intentionally outside the semantic diff."
            )
        )

        let diff = try PlanSemanticDiffer.compare(baseline, changed)
        let categories = Set(diff.categories)

        #expect(categories.contains(.calibration))
        #expect(categories.contains(.goalTarget))
        #expect(categories.contains(.phase))
        #expect(categories.contains(.schedule))
        #expect(categories.contains(.sessionIntent))
        #expect(categories.contains(.paceTarget))
        #expect(categories.contains(.strengthPrescription))
        #expect(!categories.contains(.enduranceDose))
    }

    @Test func malformedNumbersRemainDigestibleForValidation() throws {
        let session = GeneratedSession(
            dayOffset: 0,
            discipline: .running,
            runType: .easy,
            targetDistanceM: .infinity,
            targetDurationS: nil,
            targetPaceSPerKm: .nan,
            intervals: nil,
            strengthLabel: nil,
            rationale: nil
        )
        let plan = GeneratedPlan(
            p5kSPerKm: .nan,
            weeks: [GeneratedWeek(index: 0, isDeload: false, isTaper: false, sessions: [session])]
        )

        let snapshot = plan.semanticSnapshot()
        #expect(snapshot.p5kMillisecondsPerKm.rawValue == "nan")
        #expect(snapshot.weeks[0].sessions[0].targetDistanceMeters?.rawValue == "+infinity")
        #expect(try snapshot.digest().value.count == 64)
    }

    @Test func replayRoundTripReproducesTheSemanticPlan() throws {
        let persona = fixture
        let first = try LegacyPlanShadowEvaluator.evaluate(
            inputs: persona.inputs,
            catalog: RunningPlannerTestFixtures.catalog,
            calibration: persona.calibration,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar
        )
        let bytes = try first.replay.canonicalData()
        let decoded = try JSONDecoder().decode(LegacyPlanReplay.self, from: bytes)
        let replayed = try LegacyPlanShadowEvaluator.evaluate(replay: decoded)

        #expect(replayed.digest == first.digest)
        #expect(replayed.snapshot == first.snapshot)
        #expect(replayed.expectedDigestMatches == true)
        #expect(replayed.validation.isValid)
        #expect(try decoded.canonicalData() == bytes)

        let payload = String(decoding: bytes, as: UTF8.self).lowercased()
        for forbidden in ["rationale", "displayname", "route", "gps", "healthsample", "medicalnote"] {
            #expect(!payload.contains(forbidden))
        }
    }

    @Test func replayPreservesSemanticCatalogOrderForStrengthPlans() throws {
        let persona = try #require(
            RunningPlannerTestFixtures.goldenPersonas.first {
                $0.id == "road.10k-strength-support"
            }
        )
        let deliberatelyOrderedCatalog = Array(RunningPlannerTestFixtures.catalog.reversed())
        let first = try LegacyPlanShadowEvaluator.evaluate(
            inputs: persona.inputs,
            catalog: deliberatelyOrderedCatalog,
            calibration: persona.calibration,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar
        )
        let replayed = try LegacyPlanShadowEvaluator.evaluate(replay: first.replay)

        #expect(replayed.digest == first.digest)
        #expect(first.replay.catalog.map(\.name) == deliberatelyOrderedCatalog.map(\.name))
    }

    @Test func replayPreservesCalendarIdentityAndConfiguration() throws {
        var calendar = Calendar(identifier: .buddhist)
        calendar.locale = Locale(identifier: "th_TH")
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let replay = LegacyPlanReplay(
            inputs: fixture.inputs,
            catalog: RunningPlannerTestFixtures.catalog,
            calibration: fixture.calibration,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: calendar
        )
        let restored = try replay.replayCalendar()

        #expect(restored.identifier == calendar.identifier)
        #expect(restored.locale?.identifier == calendar.locale?.identifier)
        #expect(restored.timeZone.identifier == calendar.timeZone.identifier)
        #expect(restored.firstWeekday == calendar.firstWeekday)
        #expect(restored.minimumDaysInFirstWeek == calendar.minimumDaysInFirstWeek)
    }

    @Test func replayRejectsUnknownDomainValues() throws {
        let persona = fixture
        var replay = LegacyPlanReplay(
            inputs: persona.inputs,
            catalog: RunningPlannerTestFixtures.catalog,
            calibration: persona.calibration,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar
        )
        replay.request.goal = "not-a-goal"
        #expect(throws: LegacyPlanReplayError.invalidEnum(field: "goal", value: "not-a-goal")) {
            _ = try replay.replayInputs()
        }
    }

    @Test func shadowEvaluationCannotMutateTheSwiftDataStore() throws {
        let controller = PersistenceController.inMemory()
        let context = controller.container.mainContext
        let stored = TrainingPlan()
        stored.name = "Untouched live plan"
        stored.goal = .stayConsistent
        let storedSession = PlannedSession()
        storedSession.date = RunningPlannerTestFixtures.startDate
        storedSession.discipline = .running
        storedSession.runType = .easy
        storedSession.targetDistanceM = 4_000
        stored.sessions = [storedSession]
        context.insert(stored)
        try context.save()

        let beforePlans = try context.fetch(FetchDescriptor<TrainingPlan>()).map(\.id)
        let beforeSessions = try context.fetch(FetchDescriptor<PlannedSession>()).map(\.id)
        let persona = fixture
        let result = try LegacyPlanShadowEvaluator.evaluate(
            inputs: persona.inputs,
            catalog: RunningPlannerTestFixtures.catalog,
            calibration: persona.calibration,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar
        )
        let afterPlans = try context.fetch(FetchDescriptor<TrainingPlan>()).map(\.id)
        let afterSessions = try context.fetch(FetchDescriptor<PlannedSession>()).map(\.id)

        #expect(result.validation.isValid)
        #expect(afterPlans == beforePlans)
        #expect(afterSessions == beforeSessions)
        #expect(stored.name == "Untouched live plan")
        #expect(stored.sessions.first?.targetDistanceM == 4_000)
    }
}
