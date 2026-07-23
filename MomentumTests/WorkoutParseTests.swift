import Testing
import Foundation
@testable import Momentum

/// The server rung of the offline-log ladder — the parts that run on-device and must be exact:
/// response→result mapping (every number clamped; the model proposes, these clamps dispose),
/// the field-wise merge with the local grammar, and the `looksRicher` trigger heuristic.
struct WorkoutParseTests {

    private func payloadJSON(type: String = "strength", indoor: Bool = false, durationS: Double = 2700,
                             distanceM: Double = 0, effort: Int = 0, dayOffset: Int = 0,
                             timeOfDay: String = "",
                             exercises: [WorkoutParseService.Response.WorkoutPayload.Exercise] = []) -> String {
        let ex = exercises.map {
            "{\"name\":\"\($0.name)\",\"sets\":\($0.sets),\"reps\":\($0.reps),\"weight_kg\":\($0.weight_kg)}"
        }.joined(separator: ",")
        return """
        {"type":"\(type)","indoor":\(indoor),"duration_s":\(durationS),"distance_m":\(distanceM),
         "effort":\(effort),"day_offset":\(dayOffset),"time_of_day":"\(timeOfDay)",
         "exercises":[\(ex)]}
        """
    }

    private func response(type: String = "strength", indoor: Bool = false, durationS: Double = 2700,
                          distanceM: Double = 0, effort: Int = 0, dayOffset: Int = 0,
                          timeOfDay: String = "",
                          exercises: [WorkoutParseService.Response.WorkoutPayload.Exercise] = []) -> WorkoutParseService.Response.WorkoutPayload {
        let json = payloadJSON(type: type, indoor: indoor, durationS: durationS, distanceM: distanceM,
                               effort: effort, dayOffset: dayOffset, timeOfDay: timeOfDay, exercises: exercises)
        return try! JSONDecoder().decode(WorkoutParseService.Response.WorkoutPayload.self, from: Data(json.utf8))
    }

    // MARK: Mapping + clamps

    @Test @MainActor func mapsHappyPath() {
        let r = WorkoutParseService.result(from: response(
            type: "strength", durationS: 3600, effort: 8, dayOffset: -1, timeOfDay: "evening",
            exercises: [.init(name: "Bench Press", sets: 4, reps: 8, weight_kg: 83.9),
                        .init(name: "Pushups", sets: 3, reps: 15, weight_kg: 0)]))
        #expect(r.type == .strength)
        #expect(r.durationS == 3600)
        #expect(r.effort == 8)
        #expect(r.dayOffset == -1)
        #expect(r.timeHint == .evening)
        #expect(r.exercises.count == 2)
        #expect(r.exercises[0].weightKg == 83.9)
        #expect(r.exercises[1].weightKg == nil)   // bodyweight: 0 → nil
    }

    @Test @MainActor func clampsAbsurdNumbers() {
        let r = WorkoutParseService.result(from: response(
            type: "run", durationS: 30, distanceM: 50, effort: 14, dayOffset: -30,
            exercises: [.init(name: "Bench", sets: 99, reps: 8, weight_kg: 5000)]))
        #expect(r.durationS == nil)        // sub-minute "workout" is a mis-read
        #expect(r.distanceM == nil)        // 50 m run is a mis-read
        #expect(r.effort == nil)           // out of 1–10
        #expect(r.dayOffset == -7)         // capped at a week back
        #expect(r.exercises[0].sets == 20) // set count capped
        #expect(r.exercises[0].weightKg == nil)   // absurd weight DROPS, never clamps to a lie
    }

    @Test @MainActor func dropsNumberlessExercisesAndUnknownType() {
        let r = WorkoutParseService.result(from: response(
            type: "zumba",   // not a WorkoutType — but the set line below still implies the gym
            exercises: [.init(name: "Squats", sets: 1, reps: 0, weight_kg: 0),   // named, no numbers
                        .init(name: "  ", sets: 3, reps: 10, weight_kg: 0),      // no name
                        .init(name: "Curls", sets: 3, reps: 12, weight_kg: 14)]))
        #expect(r.exercises.count == 1)
        #expect(r.exercises[0].name == "Curls")
        #expect(r.type == .strength)   // exercises imply the gym even when the type string is junk
    }

    @Test @MainActor func distanceImpliesRunWhenTypeUnknown() {
        let r = WorkoutParseService.result(from: response(type: "", durationS: 0, distanceM: 8000))
        #expect(r.type == .run)
        #expect(r.distanceM == 8000)
        #expect(r.durationS == nil)
    }

    @Test @MainActor func multiWorkoutResponseMapsToCards() {
        let json = """
        {"workouts":[\(payloadJSON(type: "strength", durationS: 2700,
                                   exercises: [.init(name: "Bench Press", sets: 4, reps: 8, weight_kg: 84)])),
                     \(payloadJSON(type: "run", durationS: 2252, distanceM: 6437))],
         "confidence":0.9}
        """
        let r = try! JSONDecoder().decode(WorkoutParseService.Response.self, from: Data(json.utf8))
        let cards = WorkoutParseService.results(from: r)
        #expect(cards.count == 2)
        #expect(cards[0].type == .strength)
        #expect(cards[1].type == .run)
        #expect(cards[1].distanceM == 6437)
    }

    @Test @MainActor func mergeKeepsAICardCount() {
        var lift = WorkoutLogParser.Result()
        lift.type = .strength
        lift.durationS = 2700
        var run = WorkoutLogParser.Result()
        run.type = .run
        run.durationS = 2252
        run.distanceM = 6437
        // Grammar read the whole thing as one thin lift; the server split it properly.
        var grammar = WorkoutLogParser.Result()
        grammar.type = .strength
        grammar.effort = 8
        let merged = WorkoutParseService.merge(ai: [lift, run], grammar: [grammar])
        #expect(merged.count == 2)
        #expect(merged[0].effort == 8)   // grammar backfills the primary card's gaps
        #expect(merged[1].distanceM == 6437)
    }

    // MARK: Merge — the server read the whole text, the grammar keeps what it left empty

    @Test @MainActor func mergePrefersAIWherePresent() {
        var ai = WorkoutLogParser.Result()
        ai.type = .strength
        ai.durationS = 3600
        ai.exercises = [.init(name: "Bench Press", sets: 4, reps: 8, weightKg: 84)]
        var grammar = WorkoutLogParser.Result()
        grammar.type = .run
        grammar.durationS = 2700
        grammar.distanceM = 8047
        grammar.effort = 8
        grammar.dayOffset = -1
        let m = WorkoutParseService.merge(ai: ai, grammar: grammar)
        #expect(m.type == .strength)          // AI wins where it spoke
        #expect(m.durationS == 3600)
        #expect(m.distanceM == 8047)          // grammar fills what AI left empty
        #expect(m.effort == 8)
        #expect(m.dayOffset == -1)
        #expect(m.exercises.count == 1)
    }

    // MARK: looksRicher — when the composer sends text to the server rung

    @Test func plainSentencesStayLocal() {
        let a = "Ran 6 easy miles this morning in 1:09:30"
        #expect(!WorkoutLogParser.looksRicher(a, than: WorkoutLogParser.parse(a)))
        let b = "45 min upper body, bench 4x8 at 185, rows 3x10 at 135"
        #expect(!WorkoutLogParser.looksRicher(b, than: WorkoutLogParser.parse(b, weightUnit: .lb)))
        #expect(!WorkoutLogParser.looksRicher("ran", than: WorkoutLogParser.parse("ran")))
    }

    @Test func richProseGoesToTheServer() {
        // Numbers the grammar couldn't place → ask.
        let a = "Did chest and tris, worked up to 225 on bench for 3, then some incline dumbbells"
        #expect(WorkoutLogParser.looksRicher(a, than: WorkoutLogParser.parse(a)))
        // No discernible sport in a real sentence → ask.
        let b = "big session with the crew out at the lake this morning"
        #expect(WorkoutLogParser.looksRicher(b, than: WorkoutLogParser.parse(b)))
        // Long prose, thin receipt → ask.
        let c = "went out with the group and did the usual loop around the reservoir, legs felt heavy the whole way but finished strong with a solid kick at the end of the run"
        #expect(WorkoutLogParser.looksRicher(c, than: WorkoutLogParser.parse(c)))
    }
}
