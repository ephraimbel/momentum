import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The wiring, not the wording: does the coach actually get CALLED on every capture surface?
///
/// A simulator can't play speech, so the only honest verification is to stand a spy in the
/// synthesizer's place and read back the exact utterances each live surface hands it. Every case
/// below is a surface that recorded in silence at some point: the stopwatch sports had no coach at
/// all, and the gym said one generic line at the end of a rest and nothing else.
@Suite(.serialized)
@MainActor
struct VoiceCoachWiringTests {

    /// Stands where `VoiceCoachService` stands. Records instead of speaking.
    final class SpyVoice: VoiceCoachServing {
        var isEnabled = true
        private(set) var spoken: [String] = []
        private(set) var prepared = 0
        private(set) var stops = 0
        func announce(_ text: String) { spoken.append(text) }
        func stop() { stops += 1 }
        func prepare() { prepared += 1 }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    // MARK: Stopwatch sports

    /// A tennis match used to record in total silence: `TimedTrackingViewModel` never held a voice.
    @Test func aStopwatchSportIsCoachedFromTheFirstSecondToTheLast() throws {
        ActiveWorkoutMarker.clear()
        let voice = SpyVoice()
        let vm = TimedTrackingViewModel(type: .tennis, container: try makeContainer(), voice: voice)
        vm.start()
        #expect(voice.prepared == 1)            // the speech stack is warmed off the first cue's path
        #expect(voice.spoken == ["Tennis. Recording."])
        vm.togglePause()
        vm.togglePause()
        #expect(voice.spoken == ["Tennis. Recording.", "Paused.", "Resumed."])
        vm.finish()
        #expect(voice.spoken.last?.hasPrefix("Done.") == true)
        ActiveWorkoutMarker.clear()
    }

    /// Not entitled (or muted) means nil, and nil means the capture runs exactly as before.
    @Test func anUnentitledStopwatchSportIsSilentAndStillRecords() throws {
        ActiveWorkoutMarker.clear()
        let vm = TimedTrackingViewModel(type: .yoga, container: try makeContainer(), voice: nil)
        vm.start()
        #expect(vm.workoutId != nil)
        vm.togglePause()
        #expect(vm.finish() != nil)
        ActiveWorkoutMarker.clear()
    }

    // MARK: The gym

    @Test func theGymCoachNamesTheRestAndTheSetThatFollowsIt() async throws {
        ActiveWorkoutMarker.clear()
        let container = try makeContainer()
        let bench = Exercise(name: "Bench press", primaryMuscles: [.chest], equipment: .barbell,
                             category: .compound, defaultRestS: 120)
        container.mainContext.insert(bench)
        try container.mainContext.save()

        let voice = SpyVoice()
        let vm = StrengthViewModel(container: container, weightUnit: .kg, voice: voice)
        await vm.start()
        #expect(voice.prepared == 1)

        await vm.addExercise(bench)
        let row = try #require(vm.exercises.first)
        await vm.addSet(rowId: row.id)
        await vm.addSet(rowId: row.id)
        let sets = try #require(vm.exercises.first).sets
        #expect(sets.count == 3)

        vm.drafts[sets[0].id] = .init(weight: "80", reps: "5", rpe: "8")
        await vm.completeSet(rowId: row.id, setId: sets[0].id)
        #expect(vm.restEndsAt != nil)

        // The ring drives the clock; the wording and the Pro gate live in the view model.
        vm.announceRestStart()
        #expect(voice.spoken == ["Rest 2 minutes."])
        #expect(vm.restCompleteCue == "Rest complete. Bench press, set 2.")
        vm.announceRestComplete()
        #expect(voice.spoken.last == "Rest complete. Bench press, set 2.")

        // A short rest is not worth a sentence — it would still be talking when the ring ran out.
        vm.startRest(seconds: 30, exerciseName: "Bench press", rowId: row.id)
        let before = voice.spoken.count
        vm.announceRestStart()
        #expect(voice.spoken.count == before)

        // Finish the exercise: with nothing owed, the cue falls back rather than naming a ghost set.
        for set in try #require(vm.exercises.first).sets where !set.isComplete {
            vm.drafts[set.id] = .init(weight: "80", reps: "5", rpe: "8")
            await vm.completeSet(rowId: row.id, setId: set.id)
        }
        #expect(vm.restNextUp == nil)
        #expect(vm.restCompleteCue == "Rest complete. Time for your next set.")

        vm.announceSessionComplete()
        #expect(voice.spoken.last == "Session complete. 3 sets logged.")
        ActiveWorkoutMarker.clear()
    }

    /// A superset rests between ROUNDS, and the next round opens on the pair's FIRST exercise —
    /// naming the one just put down sends the athlete back to the wrong bar.
    @Test func aSupersetRestNamesTheExerciseTheNextRoundOpensOn() async throws {
        ActiveWorkoutMarker.clear()
        let container = try makeContainer()
        let press = Exercise(name: "Overhead press", primaryMuscles: [.shoulders], equipment: .barbell,
                             category: .compound, defaultRestS: 90)
        let row = Exercise(name: "Barbell row", primaryMuscles: [.back], equipment: .barbell,
                           category: .compound, defaultRestS: 90)
        container.mainContext.insert(press)
        container.mainContext.insert(row)
        try container.mainContext.save()

        let voice = SpyVoice()
        let vm = StrengthViewModel(container: container, weightUnit: .kg, voice: voice)
        await vm.start()
        await vm.addExercise(press)
        await vm.addExercise(row)
        let pressRow = try #require(vm.exercises.first)
        let rowRow = try #require(vm.exercises.last)
        await vm.addSet(rowId: pressRow.id)
        await vm.addSet(rowId: rowRow.id)
        await vm.pairExisting(pressRow.id, rowRow.id)

        // Round one: press, then row. Rest only opens once the ROUND is done.
        let pressSets = try #require(vm.exercises.first { $0.id == pressRow.id }).sets
        vm.drafts[pressSets[0].id] = .init(weight: "40", reps: "8", rpe: "7")
        await vm.completeSet(rowId: pressRow.id, setId: pressSets[0].id)
        #expect(vm.restEndsAt == nil)         // mid-round: the partner is the next move, not a rest
        let rowSets = try #require(vm.exercises.first { $0.id == rowRow.id }).sets
        vm.drafts[rowSets[0].id] = .init(weight: "50", reps: "8", rpe: "7")
        await vm.completeSet(rowId: rowRow.id, setId: rowSets[0].id)
        #expect(vm.restEndsAt != nil)

        #expect(vm.restCompleteCue == "Rest complete. Overhead press, set 2.")
        ActiveWorkoutMarker.clear()
    }

    /// Skipping a rest is not finishing one. The ring's completion branch used to read a cleared
    /// timer as "zero left" and buzz + speak for a rest nobody took — which is every superset
    /// round, because the next check-off stands the previous round's ring down.
    @Test func aSkippedRestReportsNoRemainingTimeAtAll() async throws {
        ActiveWorkoutMarker.clear()
        let container = try makeContainer()
        let vm = StrengthViewModel(container: container, weightUnit: .kg, voice: SpyVoice())
        await vm.start()
        vm.startRest(seconds: 120, exerciseName: "Squat")
        #expect(vm.restRemaining(at: Date()) ?? 0 > 0)
        vm.skipRest()
        #expect(vm.restRemaining(at: Date()) == nil)
        ActiveWorkoutMarker.clear()
    }

    // MARK: The switch itself

    /// The Settings toggle and the service read the SAME key, and the default is ON. A mismatch
    /// here is a coach that is silent for everyone who never opened Settings.
    @Test func theVoiceCoachIsOnUntilTheAthleteTurnsItOff() {
        let key = VoiceCoachService.storageKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        let service = VoiceCoachService()
        #expect(service.isEnabled)                      // never opened Settings ⇒ still coached
        service.isEnabled = false
        #expect(UserDefaults.standard.bool(forKey: key) == false)
        #expect(!service.isEnabled)
        service.isEnabled = true
        #expect(service.isEnabled)
    }
}
