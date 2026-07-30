import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Undo for coach-applied changes: a full plan-state snapshot restores everything exactly —
/// session fields, deleted sessions, the adaptation throttle, and profile inputs.
@MainActor
struct CoachUndoTests {

    func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private let cal = Calendar.current
    private var today: Date { cal.startOfDay(for: Date()) }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    private func makeProfile(in ctx: ModelContext) -> UserProfile {
        let profile = UserProfile()
        profile.disciplines = [Discipline.running.rawValue]
        let plan = TrainingPlan()
        plan.p5kSPerKm = 330
        ctx.insert(profile)
        ctx.insert(plan)
        var sessions: [PlannedSession] = []
        for i in 1...3 {
            let s = PlannedSession()
            s.date = day(i * 3)
            s.discipline = .running
            s.runType = i == 2 ? .tempo : .easy
            s.status = .planned
            s.targetDistanceM = 8_000
            s.targetPaceSPerKm = 360
            s.intervals = i == 2 ? "3x1600m @ T" : nil
            ctx.insert(s)
            sessions.append(s)
        }
        plan.sessions = sessions
        profile.plan = plan
        try? ctx.save()
        return profile
    }

    @Test func undoRestoresEasedWeekExactlyIncludingThrottle() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)

        let snapshot = try #require(CoachUndo.capture(profile))
        CoachActions.apply(.easeWeek, profile: profile, workouts: [], today: today, in: ctx)
        // The ease was real: tempo softened, distances trimmed, throttle burned.
        #expect(profile.plan?.lastAdaptedAt != nil)
        #expect(profile.plan?.sessions.allSatisfy { $0.runType == .easy } == true)

        #expect(CoachUndo.restore(snapshot, profile: profile, in: ctx))
        let restored = try #require(profile.plan)
        #expect(restored.lastAdaptedAt == nil)                        // change budget returned
        #expect(restored.sessions.count == 3)
        let tempo = restored.sessions.first { $0.runType == .tempo }
        #expect(tempo != nil)
        #expect(tempo?.intervals == "3x1600m @ T")                    // lossy soften fully recovered
        #expect(restored.sessions.allSatisfy { $0.targetDistanceM == 8_000 })
        #expect(restored.p5kSPerKm == 330)
    }

    @Test func undoResurrectsSkippedSession() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        let victim = profile.plan!.sessions.sorted { $0.date < $1.date }[0]
        let victimID = victim.id

        let snapshot = try #require(CoachUndo.capture(profile))
        CoachActions.apply(.skipSession(id: victimID), profile: profile, workouts: [], today: today, in: ctx)
        #expect(profile.plan?.sessions.count == 2)

        #expect(CoachUndo.restore(snapshot, profile: profile, in: ctx))
        #expect(profile.plan?.sessions.count == 3)
        #expect(profile.plan?.sessions.contains { $0.id == victimID } == true)
    }

    @Test func undoRestoresProfileInputsAfterRebuild() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        profile.weeklyRunVolumeM = 20_000
        let originalDates = profile.plan!.sessions.map(\.date).sorted()

        let snapshot = try #require(CoachUndo.capture(profile))
        CoachActions.apply(.changeDays(daysPerWeek: 6, preferredDays: nil),
                           profile: profile, workouts: [], today: today, in: ctx)
        #expect(profile.daysPerWeek == 6)

        #expect(CoachUndo.restore(snapshot, profile: profile, in: ctx))
        #expect(profile.daysPerWeek == 3)                              // the default before the change
        #expect(profile.plan?.sessions.map(\.date).sorted() == originalDates)
    }

    @Test func undoRelinksCompletedWorkouts() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        let session = profile.plan!.sessions.sorted { $0.date < $1.date }[0]
        let workout = Workout()
        workout.type = .run
        workout.startedAt = Date()
        ctx.insert(workout)
        PlanCoaching.markComplete(session, with: workout, in: ctx)

        let snapshot = try #require(CoachUndo.capture(profile))
        CoachActions.apply(.easeWeek, profile: profile, workouts: [], today: today, in: ctx)
        #expect(CoachUndo.restore(snapshot, profile: profile, in: ctx))

        let restored = profile.plan?.sessions.first { $0.status == .completed }
        #expect(restored?.completedWorkout?.id == workout.id)
        #expect(restored.flatMap { $0.completedWorkout?.plannedSession?.id } == restored?.id)
    }

    @Test func explainerSpeaksFromTheAthletesNumbers() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = makeProfile(in: ctx)
        profile.raceDate = day(10 * 7)
        profile.raceDistanceM = 21_097.5
        profile.plan?.weekPhases = ["base", "build", "build", "recovery", "build", "taper"]
        try? ctx.save()

        let sections = CoachPlanExplainer.sections(profile: profile, workouts: [])
        #expect(!sections.isEmpty)
        let all = sections.map { "\($0.title) \($0.detail)" }.joined(separator: " ")
        #expect(all.contains("Half marathon"))                        // their race
        #expect(all.contains("3 build week"))                         // their phases
        #expect(all.contains("3 training days"))                      // their schedule
        // No plan → nothing to explain (never invents).
        let empty = UserProfile()
        ctx.insert(empty)
        #expect(CoachPlanExplainer.sections(profile: empty, workouts: []).isEmpty)
    }
}
