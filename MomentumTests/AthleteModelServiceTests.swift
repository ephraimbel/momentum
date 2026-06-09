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
}
