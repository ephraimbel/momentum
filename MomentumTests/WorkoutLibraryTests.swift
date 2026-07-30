import Testing
import Foundation
@testable import Momentum

/// The workout library's contract: every catalog entry must compile — through the REAL builder —
/// into a guided workout whose structure and paces a coach would sign off on. The catalog is data;
/// these tests are what keep it honest as it grows.
@Suite("WorkoutLibrary")
struct WorkoutLibraryTests {

    private let p5k = 300.0        // a 25:00 5K athlete
    private let unit = DistanceUnit.metric

    private func built(_ entry: WorkoutLibrary.Entry, volume: Double? = nil) -> StructuredWorkout? {
        let rx = WorkoutLibrary.prescription(entry, volume: volume, p5k: p5k, unit: unit)
        return StructuredWorkoutBuilder.build(from: rx.makeSession(on: .now), p5kSPerKm: p5k,
                                              raceDistanceM: 42_195)
    }

    // MARK: Every entry expands

    @Test func everyEntryBuildsAGuidedWorkout() {
        // Collected ids, not per-item comments — the app module's (dormant) `Comment` model makes
        // Testing.Comment ambiguous inside the #expect expansion, and a failed id list reads better.
        let unbuildable = WorkoutLibrary.all.filter { built($0) == nil }.map(\.id)
        #expect(unbuildable.isEmpty)
        let empty = WorkoutLibrary.all.filter { (built($0)?.workStepCount ?? 0) == 0 }.map(\.id)
        #expect(empty.isEmpty)
    }

    @Test func repDialsProduceExactlyThatManyWorkSteps() {
        for entry in WorkoutLibrary.all {
            guard case let .reps(options, _) = entry.dial else { continue }
            let wrong = options.filter { built(entry, volume: Double($0))?.workStepCount != $0 }
            #expect(wrong.isEmpty)
        }
    }

    @Test func dialDefaultsAreAlwaysOfferedOptions() {
        let offMenu = WorkoutLibrary.all.filter { entry in
            switch entry.dial {
            case let .reps(options, def): !options.contains(def)
            case let .kilometers(options, def): !options.contains(def)
            case let .minutes(options, def): !options.contains(def)
            }
        }.map(\.id)
        #expect(offMenu.isEmpty)
    }

    @Test func offMenuVolumeFallsBackToTheDefault() {
        let entry = WorkoutLibrary.entry(id: "reps-400")!
        let rx = WorkoutLibrary.prescription(entry, volume: 40, p5k: p5k, unit: unit)
        let def = WorkoutLibrary.prescription(entry, p5k: p5k, unit: unit)
        #expect(rx == def)   // 40×400 is not a session we'll ever hand an athlete
    }

    // MARK: The coach's math — paces land in the right zones, in the right order

    @Test func repPacesFollowTheDanielsLadder() {
        let vo2 = WorkoutLibrary.prescription(WorkoutLibrary.entry(id: "reps-400")!, p5k: p5k, unit: unit)
        let fiveK = WorkoutLibrary.prescription(WorkoutLibrary.entry(id: "reps-800")!, p5k: p5k, unit: unit)
        let cruise = WorkoutLibrary.prescription(WorkoutLibrary.entry(id: "cruise")!, p5k: p5k, unit: unit)
        let tempo = WorkoutLibrary.prescription(WorkoutLibrary.entry(id: "tempo")!, p5k: p5k, unit: unit)

        // s/km ascending = intensity descending: VO₂ reps < 5K-pace reps < threshold work.
        #expect(vo2.targetPaceSPerKm < fiveK.targetPaceSPerKm)
        #expect(fiveK.targetPaceSPerKm < cruise.targetPaceSPerKm)
        // 5K-pace reps price at exactly the athlete's 5K; cruise reps at exactly threshold.
        #expect(fiveK.targetPaceSPerKm == PlanEngine.pace(.race, p5k: p5k))
        #expect(cruise.targetPaceSPerKm == tempo.targetPaceSPerKm)
    }

    @Test func cruiseIntervalsKeepTheShortFloat() {
        // The 60 s float is the point of cruise reps (Daniels) — the default 120 s would dilute it.
        let steps = built(WorkoutLibrary.entry(id: "cruise")!)!.steps
        let floats = steps.filter { $0.kind == .recovery }
        #expect(!floats.isEmpty)
        #expect(floats.allSatisfy { $0.target == .duration(60) })
    }

    @Test func shortRepsRecoverNinetySeconds() {
        let steps = built(WorkoutLibrary.entry(id: "reps-400")!)!.steps
        let recoveries = steps.filter { $0.kind == .recovery }
        #expect(recoveries.allSatisfy { $0.target == .duration(90) })
    }

    @Test func progressionClimbsThroughTheGears() {
        // E → M → T: each third strictly faster (smaller s/km) than the last.
        let steps = built(WorkoutLibrary.entry(id: "progression")!)!.steps
        let paces = steps.compactMap(\.paceSPerKm)
        #expect(paces.count == 3)
        #expect(paces[0] > paces[1] && paces[1] > paces[2])
    }

    @Test func raceFinishLongEndsAtRacePace() {
        let steps = built(WorkoutLibrary.entry(id: "long-racefinish")!)!.steps
        #expect(steps.count == 2)
        // The finish block runs faster than the steady body, and it's the LAST thing you do.
        #expect(steps[1].paceSPerKm! < steps[0].paceSPerKm!)
        #expect(steps[1].target.distanceM == 5_000)
    }

    @Test func fartlekSurgesAndFloatsAlternate() {
        let steps = built(WorkoutLibrary.entry(id: "fartlek-3030")!)!.steps
        let surges = steps.filter { $0.title == "Surge" }
        let floats = steps.filter { $0.title == "Float" }
        #expect(surges.count == 12 && floats.count == 12)
        #expect(surges.allSatisfy { $0.target == .duration(30) })
    }

    @Test func hillsAreEffortNotPace() {
        // A grade destroys pace targets — hill pushes must guide by effort (nil pace), with the
        // jog-down never shorter than a real 90 s reset.
        let steps = built(WorkoutLibrary.entry(id: "hills-short")!)!.steps
        let pushes = steps.filter { $0.title == "Hill" }
        #expect(pushes.allSatisfy { $0.paceSPerKm == nil })
        let downs = steps.filter { $0.title == "Jog down" }
        #expect(downs.allSatisfy { $0.target == .duration(90) })   // max(90, 30 × 1.6)
    }

    @Test func runWalkNeverJudgesPace() {
        // The on-ramp session guides by TIME only — a beginner must never hear "pick it up"
        // mid-run-segment. Steps are named so every surface says the plain thing: Run. Walk.
        let steps = built(WorkoutLibrary.entry(id: "runwalk")!)!.steps
        #expect(steps.allSatisfy { $0.paceSPerKm == nil })
        #expect(steps.filter { $0.kind == .work }.allSatisfy { $0.title == "Run" })
        #expect(steps.filter { $0.kind == .recovery }.allSatisfy { $0.title == "Walk" })
    }

    // MARK: Sizing honesty

    @Test func biggerDialsMeanMoreSession() {
        let entry = WorkoutLibrary.entry(id: "reps-400")!
        let small = WorkoutLibrary.prescription(entry, volume: 6, p5k: p5k, unit: unit)
        let large = WorkoutLibrary.prescription(entry, volume: 12, p5k: p5k, unit: unit)
        #expect(large.targetDistanceM! > small.targetDistanceM!)

        let fartlek = WorkoutLibrary.entry(id: "fartlek-classic")!
        let f6 = WorkoutLibrary.prescription(fartlek, volume: 6, p5k: p5k, unit: unit)
        let f12 = WorkoutLibrary.prescription(fartlek, volume: 12, p5k: p5k, unit: unit)
        #expect(f12.targetDurationS! > f6.targetDurationS!)
    }

    @Test func kilometerDialsSnapToCleanCoachDistances() {
        let rx = WorkoutLibrary.prescription(WorkoutLibrary.entry(id: "tempo")!, p5k: p5k, unit: .metric)
        // Metric snap increments are 0.5 km below 10 km — never "6.37 km".
        let km = rx.targetDistanceM! / 1000
        #expect(abs(km - (km * 2).rounded() / 2) < 0.001)
    }

    @Test func estimatedDurationsAreSane() {
        // Every catalog session is a real training session: 15 minutes to 2.5 hours.
        let offScale = WorkoutLibrary.all.filter { entry in
            let estimate = WorkoutLibrary.estimatedDurationS(built(entry)!,
                                                             easyPaceSPerKm: PlanEngine.pace(.easy, p5k: p5k))
            return estimate <= 15 * 60 || estimate >= 150 * 60
        }.map(\.id)
        #expect(offScale.isEmpty)
    }

    // MARK: Coach prose is present everywhere (the library speaks, always)

    @Test func everyEntryCarriesItsFullCoachVoice() {
        let mute = WorkoutLibrary.all.filter {
            $0.what.isEmpty || $0.why.isEmpty || $0.feels.isEmpty
                || $0.execution.count < 2 || $0.rationale.isEmpty
        }.map(\.id)
        #expect(mute.isEmpty)
    }

    @Test func categoriesAllHaveEntries() {
        let empty = WorkoutLibrary.Category.allCases.filter { WorkoutLibrary.entries(in: $0).isEmpty }
        #expect(empty.isEmpty)
    }

    // MARK: Headlines — every surface says the workout's SHAPE, never a misleading average

    @Test @MainActor func headlinesSpeakTheWorkoutShape() {
        func headline(_ id: String) -> String {
            let rx = WorkoutLibrary.prescription(WorkoutLibrary.entry(id: id)!, p5k: p5k, unit: unit)
            return PlanCoaching.brief(for: rx.makeSession(on: .now), distanceUnit: unit)
        }
        // Rep sessions lead with reps × distance and the REP pace — "Intervals 5.2 km ~4:41 /km"
        // read as a continuous run at that pace, which no interval session is.
        #expect(headline("reps-400").hasPrefix("8 × 400m @ "))
        #expect(headline("reps-800").hasPrefix("5 × 800m @ "))
        #expect(headline("reps-3min").hasPrefix("5 × 3min @ "))
        #expect(headline("cruise").hasPrefix("4 × 1.6km @ "))
        // Effort work carries no marquee pace — surges and hills run by feel.
        #expect(headline("fartlek-classic") == "8 × 1min surges")
        #expect(headline("fartlek-3030") == "12 × 30s surges")
        #expect(headline("hills-short") == "8 × 30s hills")
        #expect(headline("hills-long") == "6 × 75s hills")
        // Composites say their two parts plainly.
        #expect(headline("strides") == "5 km easy + 6 strides")
        #expect(headline("long-racefinish") == "Long 16 km · last 5 km @ race pace")
        #expect(headline("runwalk").hasPrefix("Run/walk 2:1"))
        // Continuous sessions keep the distance-and-pace form — there it's the truth.
        #expect(headline("tempo").hasPrefix("Tempo "))
        #expect(headline("progression").hasPrefix("Progression "))
    }

    @Test func grammarRoundTripsExactly() {
        // The intervals string IS the prescription — a label that parses back different
        // (75 s written "1.2min" reads back as 72 s) silently corrupts the workout. Pin the
        // second-granular entries end-to-end through the real parser.
        let hillSteps = built(WorkoutLibrary.entry(id: "hills-long")!)!.steps
        #expect(hillSteps.filter { $0.title == "Hill" }.allSatisfy { $0.target == .duration(75) })
        let shortHills = built(WorkoutLibrary.entry(id: "hills-short")!)!.steps
        #expect(shortHills.filter { $0.title == "Hill" }.allSatisfy { $0.target == .duration(30) })
        let surges = built(WorkoutLibrary.entry(id: "fartlek-surges")!)!.steps
        #expect(surges.filter { $0.title == "Surge" }.allSatisfy { $0.target == .duration(120) })
        let strides = built(WorkoutLibrary.entry(id: "strides")!)!.steps
        #expect(strides.filter { $0.title == "Stride" }.allSatisfy { $0.target == .duration(20) })
    }

    // MARK: The watch payload round-trips

    @Test func structuredWorkoutSurvivesCodableRoundTrip() throws {
        let workout = built(WorkoutLibrary.entry(id: "fartlek-classic")!)!
        let data = try JSONEncoder().encode(workout)
        let back = try JSONDecoder().decode(StructuredWorkout.self, from: data)
        #expect(back == workout)
    }
}
