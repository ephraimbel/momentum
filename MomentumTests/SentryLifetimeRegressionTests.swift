import Foundation
import SwiftData
import Testing
@testable import Momentum

@MainActor
struct SentryLifetimeRegressionTests {
    private func store() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func run(in context: ModelContext) throws -> Workout {
        let run = Workout(), gps = GPSDetail()
        run.gps = gps
        gps.matchedRouteData = try JSONEncoder().encode([[30.0, -97.0], [30.01, -97.01]])
        context.insert(run)
        try context.save()
        return run
    }

    @Test func removedSessionIsSafeBeforeAndAfterSave() throws {
        let store = try store(), context = store.mainContext
        let plan = TrainingPlan(), session = PlannedSession()
        session.discipline = .running; session.runType = .long
        plan.sessions = [session]; context.insert(plan); try context.save()
        let retained = plan.sessions
        #expect(PlanSessionPresentation.neighbor(session) == .long)
        plan.sessions = []; context.delete(session)
        #expect(retained.filter(PlanSessionPresentation.isLive).isEmpty)
        #expect(PlanSessionPresentation.neighbor(session) == .none)
        try context.save()
        #expect(retained.filter(PlanSessionPresentation.isLive).isEmpty)
        #expect(PlanSessionPresentation.neighbor(session) == .none)
    }

    @Test func deletingWorkoutDuringSnapshotDoesNotWriteOrResurrectIt() async throws {
        let store = try store(), context = store.mainContext
        let run = try run(in: context), id = run.id
        var rendered = false
        await WorkoutSnapshotHealer.repair(workoutID: id, in: context) { _, _ in
            rendered = true
            context.delete(run); try? context.save()
            return Data([1, 2, 3])
        }
        #expect(rendered)
        #expect(try context.fetchCount(FetchDescriptor<Workout>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<GPSDetail>()) == 0)
    }

    @Test func replacingDetailDuringSnapshotDiscardsOldResult() async throws {
        let store = try store(), context = store.mainContext
        let run = try run(in: context)
        let replacement = GPSDetail()
        await WorkoutSnapshotHealer.repair(workoutID: run.id, in: context) { _, _ in
            let old = run.gps
            context.insert(replacement); run.gps = replacement
            if let old { context.delete(old) }
            try? context.save()
            return Data([1, 2, 3])
        }
        #expect(replacement.mapSnapshotData == nil)
        #expect(run.gps?.persistentModelID == replacement.persistentModelID)
    }

    @Test func newerImageWinsOverSuspendedRepair() async throws {
        let store = try store(), context = store.mainContext
        let run = try run(in: context)
        let newer = Data([9, 9, 9])
        await WorkoutSnapshotHealer.repair(workoutID: run.id, in: context) { _, _ in
            run.gps?.mapSnapshotData = newer
            try? context.save()
            return Data([1, 2, 3])
        }
        #expect(run.gps?.mapSnapshotData == newer)
    }

    @Test func ordinaryRepairPersistsAndThenDoesNotRepeat() async throws {
        let store = try store(), context = store.mainContext
        let run = try run(in: context)
        var calls = 0
        for _ in 0..<2 {
            await WorkoutSnapshotHealer.repair(workoutID: run.id, in: context) { _, _ in
                calls += 1; return Data([1, 2, 3])
            }
        }
        #expect(calls == 1)
        #expect(run.gps?.mapSnapshotData == Data([1, 2, 3]))
        #expect(run.gps?.mapSnapshotVersion == RouteSnapshotter.renderVersion)
    }

    @Test func disclosureSnapshotSurvivesSidecarDeletionAndKeepsWeekBoundary() throws {
        let store = try store(), context = store.mainContext
        let plan = TrainingPlan(); context.insert(plan)
        let now = Date(), calendar = Calendar.current
        AdaptivePlanService.initialize(plan, profileID: UUID(), now: now, in: context, calendar: calendar)
        let state = try #require(plan.adaptiveState)
        let disclosure = AdaptivePlanService.Disclosure(plan: plan, now: now, calendar: calendar)
        context.delete(state); try context.save()
        let session = PlannedSession(); session.date = now
        #expect(disclosure.showsDetails(session))
        session.date = disclosure.current.end
        #expect(!disclosure.showsDetails(session))
        session.status = .completed
        #expect(disclosure.showsDetails(session))
    }
}
