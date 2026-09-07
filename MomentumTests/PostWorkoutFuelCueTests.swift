import Foundation
import SwiftData
import Testing
@testable import Momentum

/// The post-workout refuel cue (fuel integration 2026-09-06): only an exerting session earns one,
/// the words never name an amount or a food, and the cue fires inside the recovery window or not
/// at all.
@MainActor
struct PostWorkoutFuelCueTests {

    private typealias E = PostWorkoutFuelCue

    private func emphasis(_ type: WorkoutType, minutes: Double, rpe: Int? = nil,
                          runType: RunType? = nil, sets: Int = 0) -> E.Emphasis? {
        E.emphasis(type: type, durationS: minutes * 60, rpe: rpe, runType: runType, workingSets: sets)
    }

    // MARK: The decision

    @Test func aPlannedLongRunOrARaceAlwaysEarnsOne() {
        #expect(emphasis(.run, minutes: 45, runType: .long) == .longRun)
        #expect(emphasis(.run, minutes: 20, runType: .race) == .race)     // a 5K race is still a race
        #expect(emphasis(.trailRun, minutes: 50, runType: .long) == .longRun)
    }

    @Test func anEasyJogEarnsNothing() {
        #expect(emphasis(.run, minutes: 30) == nil)
        #expect(emphasis(.run, minutes: 45, rpe: 5, runType: .easy) == nil)
        #expect(emphasis(.run, minutes: 59, runType: .recovery) == nil)
    }

    @Test func anHourOfAnyCardioIsALongEffort() {
        #expect(emphasis(.run, minutes: 60) == .longEffort)
        #expect(emphasis(.ride, minutes: 75) == .longEffort)
        #expect(emphasis(.swimming, minutes: 60) == .longEffort)
        #expect(emphasis(.rowing, minutes: 90) == .longEffort)
        #expect(emphasis(.ride, minutes: 45) == nil)
    }

    @Test func aQualityRunOrAHardRatedSessionIsAHardSession() {
        #expect(emphasis(.run, minutes: 35, runType: .tempo) == .hardSession)
        #expect(emphasis(.run, minutes: 40, runType: .intervals) == .hardSession)
        #expect(emphasis(.run, minutes: 40, rpe: 8) == .hardSession)
        #expect(emphasis(.ride, minutes: 40, rpe: 7) == .hardSession)
        // Too short to be a real session, whatever it was called.
        #expect(emphasis(.run, minutes: 20, runType: .intervals) == nil)
        #expect(emphasis(.run, minutes: 25, rpe: 9) == nil)
        // Strides on an easy day are still an easy day.
        #expect(emphasis(.run, minutes: 40, runType: .strides) == nil)
    }

    @Test func aLiftEarnsOneByTimeOrByWork() {
        #expect(emphasis(.strength, minutes: 40) == .lift)
        #expect(emphasis(.strength, minutes: 25, sets: 12) == .lift)
        #expect(emphasis(.crossfit, minutes: 45) == .lift)
        #expect(emphasis(.strength, minutes: 25, sets: 6) == nil)
        // A lift is a lift even when the athlete called it hard or the plan said "long".
        #expect(emphasis(.strength, minutes: 25, rpe: 9, runType: .long, sets: 3) == nil)
    }

    @Test func aWalkNeedsNinetyMinutes() {
        #expect(emphasis(.walk, minutes: 60) == nil)
        #expect(emphasis(.hike, minutes: 90) == .longEffort)
    }

    // MARK: The words

    private static let foods = ["banana", "gel", "chew", "rice", "egg", "toast", "shake", "bar ",
                                "chicken", "oat", "milk", "pasta", "potato", "bread", "yogurt"]

    @Test func wordsNeverNameAnAmountOrAFood() {
        for e in E.Emphasis.allCases {
            for noun in ["run", "ride", "walk", "session"] {
                let w = E.words(e, noun: noun)
                for s in [w.title, w.body] {
                    #expect(!s.contains { $0.isNumber }, "\(s)")            // no amounts, no grams
                    #expect(!s.contains("%") && !s.lowercased().contains(" g "), "\(s)")
                    for food in Self.foods { #expect(!s.lowercased().contains(food), "\(s) names \(food)") }
                    #expect(NotificationCopy.isClean(s), "\(s)")            // no dash marks
                    #expect(!s.contains("!"), "\(s)")                        // no cheerleading
                }
                #expect(w.body.contains("your call"), "\(w.body)")           // the athlete decides
                #expect(w.body.contains("Fuel"), "\(w.body)")                // and Fuel is where it lands
            }
        }
        #expect(E.words(.longEffort, noun: "ride").title == "Refuel after that ride")
        #expect(E.words(.lift, noun: "session").title == "Protein after your lift")
    }

    @Test func nounsFollowTheSport() {
        #expect(E.noun(for: .run) == "run")
        #expect(E.noun(for: .trailRun) == "run")
        #expect(E.noun(for: .ride) == "ride")
        #expect(E.noun(for: .gravelRide) == "ride")
        #expect(E.noun(for: .hike) == "walk")
        #expect(E.noun(for: .swimming) == "session")
        #expect(E.noun(for: .yoga) == "session")
    }

    // MARK: The window

    @Test func firesTwentyFiveMinutesAfterTheFinishInsideTheWindow() {
        let now = Date()
        let justFinished = now.addingTimeInterval(-60)
        let fire = E.fireDate(endedAt: justFinished, now: now)!
        #expect(abs(fire.timeIntervalSince(justFinished) - E.delayS) < 1)
        // Saved 40 minutes after the finish: still inside the window, so it fires a minute from now.
        let aWhileAgo = now.addingTimeInterval(-40 * 60)
        let soon = E.fireDate(endedAt: aWhileAgo, now: now)!
        #expect(abs(soon.timeIntervalSince(now) - 60) < 1)
        // Logged two hours later: the window is gone.
        #expect(E.fireDate(endedAt: now.addingTimeInterval(-2 * 3600), now: now) == nil)
    }

    // MARK: Through the service's payload builder (a real Workout)

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    @Test func aLongPlannedRunBuildsARoutedPayload() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let now = Date()
        let session = PlannedSession(); session.runType = .long; session.discipline = .running
        let w = Workout(); w.type = .run; w.durationS = 50 * 60; w.elapsedS = 52 * 60
        w.startedAt = now.addingTimeInterval(-53 * 60)
        ctx.insert(session); ctx.insert(w); w.plannedSession = session
        let p = try #require(NotificationService.refuelPayload(for: w, now: now))
        #expect(p.id == NotificationService.refuelID)
        #expect(p.family == .refuel)
        #expect(p.route == .fuel)
        #expect(p.title == "Refuel after your long run")
        let fire = try #require(Calendar.current.date(from: p.fire))
        // Ended a minute ago → fires 24 minutes from now (25 after the finish).
        #expect(abs(fire.timeIntervalSince(now) - 24 * 60) < 2)
        #expect(NotificationCopy.isClean(p.body))
    }

    @Test func aLiftCountsItsCompletedWorkingSets() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let w = Workout(); w.type = .strength; w.durationS = 20 * 60; w.elapsedS = 20 * 60
        w.startedAt = Date().addingTimeInterval(-21 * 60)
        let strength = StrengthSession()
        let ex = WorkoutExercise()
        for i in 0..<14 {
            let set = SetEntry(); set.index = i; set.isComplete = i < 12; set.type = i < 13 ? .working : .warmup
            ex.sets.append(set)
        }
        strength.exercises = [ex]
        ctx.insert(w); w.strength = strength
        let p = try #require(NotificationService.refuelPayload(for: w))
        #expect(p.title == "Protein after your lift")
    }

    @Test func anEasyRunOrAStaleSaveBuildsNothing() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let easy = Workout(); easy.type = .run; easy.durationS = 30 * 60; easy.elapsedS = 30 * 60
        easy.startedAt = Date().addingTimeInterval(-31 * 60)
        ctx.insert(easy)
        #expect(NotificationService.refuelPayload(for: easy) == nil)
        let stale = Workout(); stale.type = .run; stale.durationS = 90 * 60; stale.elapsedS = 90 * 60
        stale.startedAt = Date().addingTimeInterval(-5 * 3600)   // logged hours after the fact
        ctx.insert(stale)
        #expect(NotificationService.refuelPayload(for: stale) == nil)
    }
}
