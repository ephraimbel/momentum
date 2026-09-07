import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Moving planned work: the single move, the swap, the batch, and what a move is allowed to erase.
///
/// The load-bearing rule here is that rescheduling changes WHEN a session happens and nothing else.
/// A move used to blank `rationale` outright, which also destroyed the engines' adaptation
/// explanations — the eased-after-a-hard-day notes, the deload and injury-conversion notes — for no
/// reason beyond the athlete choosing a different day. Those reasons stay true after a move, and
/// the Plan board renders them exactly so the athlete can read them where they look.
@MainActor
struct PlanRescheduleTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func session(on day: Date, status: SessionStatus = .planned,
                         rationale: String? = nil) -> PlannedSession {
        let s = PlannedSession()
        s.date = Calendar.current.startOfDay(for: day)
        s.discipline = .running
        s.runType = .easy
        s.status = status
        s.rationale = rationale
        return s
    }

    private func day(_ offset: Int) -> Date {
        Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: offset, to: Date())!)
    }

    // MARK: What a move keeps

    @Test func aMoveKeepsTheCoachsReasonForTheSession() throws {
        let container = try makeContainer()   // retained: a released container dangles its context
        let ctx = container.mainContext
        let s = session(on: day(0), rationale: "Eased after your 8/10 day.")
        ctx.insert(s)

        PlanCoaching.reschedule(s, to: day(2), in: ctx)

        #expect(s.date == day(2))
        #expect(s.rationale == "Eased after your 8/10 day.",
                "changing a session's day must not delete why the session is what it is")
    }

    @Test func aMoveClearsTheSlippedForwardNote() throws {
        let container = try makeContainer()   // retained: a released container dangles its context
        let ctx = container.mainContext
        // A session the reconciler rolled forward wears `.moved` AND the auto note. Choosing a day
        // deliberately is what clears both: the week now reads as planned, not as slipped.
        let s = session(on: day(0), status: .moved, rationale: "Rolled forward from Monday.")
        ctx.insert(s)

        PlanCoaching.reschedule(s, to: day(1), in: ctx)

        #expect(s.status == .planned)
        #expect(s.rationale == nil)
    }

    // MARK: Swap

    @Test func swappingTradesTheTwoDays() throws {
        let container = try makeContainer()   // retained: a released container dangles its context
        let ctx = container.mainContext
        let a = session(on: day(0)), b = session(on: day(3))
        ctx.insert(a); ctx.insert(b)

        PlanCoaching.swapDays(a, b, in: ctx)

        #expect(a.date == day(3))
        #expect(b.date == day(0))
    }

    @Test func swappingWithinOneDayIsANoOp() throws {
        let container = try makeContainer()   // retained: a released container dangles its context
        let ctx = container.mainContext
        let a = session(on: day(2), rationale: "Deload week."), b = session(on: day(2))
        ctx.insert(a); ctx.insert(b)

        PlanCoaching.swapDays(a, b, in: ctx)

        #expect(a.date == day(2) && b.date == day(2))
        #expect(a.rationale == "Deload week.", "a no-op swap must not touch anything")
    }

    // MARK: Batch

    @Test func theBatchMovesEveryOneOfThem() throws {
        let container = try makeContainer()   // retained: a released container dangles its context
        let ctx = container.mainContext
        let all = [session(on: day(0)), session(on: day(1)), session(on: day(2))]
        for s in all { ctx.insert(s) }

        PlanCoaching.reschedule(all.map { ($0, Calendar.current.date(byAdding: .day, value: 1, to: $0.date)!) },
                                in: ctx)

        #expect(all[0].date == day(1))
        #expect(all[1].date == day(2))
        #expect(all[2].date == day(3))
    }

    @Test func anEmptyBatchDoesNothing() throws {
        let container = try makeContainer()   // retained: a released container dangles its context
        let ctx = container.mainContext
        PlanCoaching.reschedule([], in: ctx)   // must not crash or save
    }

    // MARK: Duplicate

    @Test func duplicatingCopiesThePrescriptionNotTheRecord() throws {
        let container = try makeContainer()   // retained: a released container dangles its context
        let ctx = container.mainContext
        let plan = TrainingPlan()
        ctx.insert(plan)
        let source = session(on: day(0), status: .completed, rationale: "Deload week.")
        source.targetDistanceM = 8_000
        source.intervals = "6×400m @ VO2"
        ctx.insert(source)
        plan.sessions = [source]

        let written = PlanCoaching.duplicate(source, onto: [day(7)], to: plan, in: ctx)

        #expect(written == 1)
        let copy = plan.sessions.first { $0 !== source }
        #expect(copy?.targetDistanceM == 8_000)
        #expect(copy?.intervals == "6×400m @ VO2")
        // A copy is a fresh prescription, never a record of work that happened.
        #expect(copy?.status == .planned)
        #expect(copy?.rationale == nil)
    }

    @Test func duplicatingTwiceDoesNotDoubleTheBlock() throws {
        let container = try makeContainer()   // retained: a released container dangles its context
        let ctx = container.mainContext
        let plan = TrainingPlan()
        ctx.insert(plan)
        let source = session(on: day(0))
        source.targetDistanceM = 5_000
        ctx.insert(source)
        plan.sessions = [source]

        let first = PlanCoaching.duplicate(source, onto: [day(7), day(14)], to: plan, in: ctx)
        let second = PlanCoaching.duplicate(source, onto: [day(7), day(14)], to: plan, in: ctx)

        #expect(first == 2)
        #expect(second == 0, "repeating the same session onto the same days must not stack copies")
        #expect(plan.sessions.count == 3)
    }

    @Test func duplicatingDeepCopiesStrengthTargets() throws {
        let container = try makeContainer()   // retained: a released container dangles its context
        let ctx = container.mainContext
        let plan = TrainingPlan()
        ctx.insert(plan)
        let source = session(on: day(0))
        source.discipline = .strength
        source.runType = nil
        let lift = PlannedExercise()
        lift.order = 0
        lift.targetSets = 4
        lift.targetRepLow = 6
        lift.targetRepHigh = 8
        ctx.insert(lift)
        source.strengthTargets = [lift]
        ctx.insert(source)
        plan.sessions = [source]

        #expect(PlanCoaching.duplicate(source, onto: [day(7)], to: plan, in: ctx) == 1)

        let copy = plan.sessions.first { $0 !== source }
        #expect(copy?.strengthTargets.count == 1)
        #expect(copy?.strengthTargets.first?.targetSets == 4)
        // The lift rows cascade-delete from their session, so a SHARED row would take the
        // original's lifts down with the copy.
        #expect(copy?.strengthTargets.first !== lift)
    }
}
