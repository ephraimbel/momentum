import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Export + delete (PRD §13.3): a full JSON snapshot, and a wipe that removes every personal record
/// while preserving the bundled exercise catalog.
@MainActor
struct DataManagementTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    @Test func exportsProfileAndWorkoutsAsJSON() throws {
        let container = try makeContainer()   // retain it — a temporary would dealloc the context
        let ctx = container.mainContext
        let profile = UserProfile(); profile.displayName = "Sam"; ctx.insert(profile)
        let run = Workout(); run.type = .run; run.startedAt = Date(); run.durationS = 1800
        let g = GPSDetail(); g.distanceM = 5000; run.gps = g
        ctx.insert(run)
        try ctx.save()

        let data = DataManager.exportJSON(in: ctx, now: Date(timeIntervalSinceReferenceDate: 0))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(DataManager.Snapshot.self, from: data)

        #expect(snapshot.app == "momentum")
        #expect(snapshot.profile?.displayName == "Sam")
        #expect(snapshot.workouts.count == 1)
        #expect(snapshot.workouts.first?.distanceM == 5000)
    }

    @Test func deleteWipesUserDataButKeepsTheCatalog() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = UserProfile(); ctx.insert(profile)
        let workout = Workout(); ctx.insert(workout)
        let plan = TrainingPlan(); ctx.insert(plan)
        let exercise = Exercise(name: "Bench", primaryMuscles: [.chest], equipment: .barbell, category: .compound)
        ctx.insert(exercise)
        try ctx.save()

        DataManager.deleteAllUserData(in: ctx)

        #expect((try ctx.fetch(FetchDescriptor<UserProfile>())).isEmpty)
        #expect((try ctx.fetch(FetchDescriptor<Workout>())).isEmpty)
        #expect((try ctx.fetch(FetchDescriptor<TrainingPlan>())).isEmpty)
        #expect((try ctx.fetch(FetchDescriptor<Exercise>())).count == 1)   // catalog preserved
    }
}
