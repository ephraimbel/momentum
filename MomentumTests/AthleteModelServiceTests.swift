import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Verifies the Athlete Model service persists Tier A facts and seeds onboarding notes idempotently.
@MainActor
struct AthleteModelServiceTests {

    func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    @Test func ingestPersistsFactsOntoProfile() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = UserProfile()
        profile.disciplines = [Discipline.running.rawValue]
        ctx.insert(profile)

        for daysAgo in [1, 4, 7] {
            let w = Workout(); w.type = .run
            w.startedAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
            w.durationS = 30 * 60
            let gps = GPSDetail(); gps.distanceM = 5000; w.gps = gps
            ctx.insert(w)
            profile.workouts.append(w)
        }
        try ctx.save()

        AthleteModelService().ingest(profile: profile, in: ctx, now: Date())

        let model = try #require(profile.athlete)
        #expect(model.signalSampleCounts["rhythm"] == 3)
        #expect(abs((model.disciplineShare["run"] ?? 0) - 1.0) < 0.001)
        #expect(model.snapshots.count == 1)            // one weekly snapshot upserted
    }

    @Test func seedOnboardingIsIdempotent() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = UserProfile()
        profile.disciplines = [Discipline.running.rawValue, Discipline.strength.rawValue]
        profile.experience = [Discipline.running.rawValue: ExperienceLevel.new.rawValue]
        profile.reason = "clear head"
        ctx.insert(profile)
        try ctx.save()

        let svc = AthleteModelService()
        svc.seedOnboarding(for: profile, in: ctx)
        let firstCount = profile.athlete?.notes.count ?? 0
        svc.seedOnboarding(for: profile, in: ctx)   // second call must not duplicate

        let model = try #require(profile.athlete)
        #expect(firstCount == 2)
        #expect(model.notes.count == 2)
        #expect(model.notes.contains { $0.category == MemoryCategory.identity.rawValue })
        #expect(model.notes.contains { $0.text == "You train to clear your head." })
    }

    @Test func identitySeedCapturesGoalRaceCommitmentAndInjuries() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = UserProfile()
        profile.disciplines = [Discipline.running.rawValue]
        profile.experience = [Discipline.running.rawValue: ExperienceLevel.experienced.rawValue]
        profile.goal = .raceDistance
        profile.raceDistanceM = RaceDistance.marathon.meters
        profile.raceDate = Date(timeIntervalSinceReferenceDate: 0)
        profile.goalFinishTimeS = 3 * 3600 + 30 * 60          // 3:30
        profile.daysPerWeek = 5
        profile.planIntensity = PlanIntensity.podium.rawValue
        profile.injuryHistory = [InjuryArea.knee.rawValue, InjuryArea.hamstring.rawValue]
        profile.reason = "compete"
        ctx.insert(profile); try ctx.save()

        AthleteModelService().seedOnboarding(for: profile, in: ctx)
        let model = try #require(profile.athlete)

        // The coach knows, from message one, exactly who it's coaching.
        let identity = try #require(model.notes.first { $0.category == MemoryCategory.identity.rawValue }?.text)
        #expect(identity.contains("seasoned runner"))
        #expect(identity.contains("marathon"))
        #expect(identity.contains("3:30"))                    // goal time
        #expect(identity.contains("5 days a week"))
        #expect(identity.localizedCaseInsensitiveContains("all in"))   // podium tell

        // And it knows what to protect — a distinct risk note, only because injuries were reported.
        let risk = try #require(model.notes.first { $0.category == MemoryCategory.risk.rawValue }?.text)
        #expect(risk.localizedCaseInsensitiveContains("knee"))
        #expect(risk.localizedCaseInsensitiveContains("hamstring"))
        #expect(model.notes.count == 3)                        // identity + motivation + risk
    }

    @Test func nonRacerIdentityNamesTheirGoalAndNoInjuryNoteWithoutInjuries() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = UserProfile()
        profile.disciplines = [Discipline.strength.rawValue]
        profile.experience = [Discipline.strength.rawValue: ExperienceLevel.some.rawValue]
        profile.goal = .buildMuscle
        profile.daysPerWeek = 4
        ctx.insert(profile); try ctx.save()

        AthleteModelService().seedOnboarding(for: profile, in: ctx)
        let model = try #require(profile.athlete)
        let identity = try #require(model.notes.first { $0.category == MemoryCategory.identity.rawValue }?.text)
        #expect(identity.localizedCaseInsensitiveContains("building muscle"))
        #expect(identity.contains("4 days a week"))
        #expect(!identity.contains("all in"))                  // not podium
        #expect(!model.notes.contains { $0.category == MemoryCategory.risk.rawValue })  // no injuries → no risk note
    }
}
