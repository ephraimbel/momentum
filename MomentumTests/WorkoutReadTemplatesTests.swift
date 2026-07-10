import Testing
import Foundation
@testable import Momentum

/// The deterministic AI-read fallback must satisfy the §8.8 / §13.11 acceptance bar: ≤55 words,
/// no medical claims, plan-aware.
@MainActor
struct WorkoutReadTemplatesTests {

    private func strengthWorkout() -> Workout {
        let bench = Exercise(name: "Bench", primaryMuscles: [.chest], equipment: .barbell, category: .compound)
        let set = SetEntry(); set.weightKg = 80; set.reps = 5; set.isComplete = true; set.type = .working
        let row = WorkoutExercise(); row.exercise = bench; row.sets = [set]
        let session = StrengthSession(); session.totalVolumeKg = 800; session.totalSets = 2; session.exercises = [row]
        let w = Workout(); w.type = .strength; w.durationS = 1800; w.strength = session
        return w
    }

    private func runWorkout() -> Workout {
        let gps = GPSDetail(); gps.distanceM = 8000; gps.elevationGainM = 64
        let w = Workout(); w.type = .run; w.durationS = 2510; w.gps = gps
        return w
    }

    @Test func strengthReadIsConciseSpecificAndPlanAware() {
        let read = WorkoutReadTemplates.read(for: strengthWorkout(), planned: true, weightUnit: .kg)
        #expect(read.narrative.split(separator: " ").count <= 55)
        #expect(read.narrative.contains("Bench"))
        #expect(read.narrative.lowercased().contains("plan"))
        #expect(!read.insights.isEmpty)
        assertNoMedicalClaims(read.narrative)
    }

    @Test func cardioReadIsConcise() {
        let read = WorkoutReadTemplates.read(for: runWorkout(), planned: false, distanceUnit: .metric)
        #expect(read.narrative.split(separator: " ").count <= 55)
        #expect(read.narrative.contains("Run"))
        assertNoMedicalClaims(read.narrative)
    }

    @Test func sanitizeStripsMedicalLanguage() {
        #expect(WorkoutReadTemplates.sanitize("You risk injury if you continue")
                == "Session saved, momentum's got the details.")
        #expect(WorkoutReadTemplates.sanitize("Great pace today") == "Great pace today")
        // Em dashes are converted to clean sentence punctuation (no AI-slop dashes).
        #expect(WorkoutReadTemplates.sanitize("Strong work — nice splits") == "Strong work. Nice splits")
    }

    @Test func coachingClauseNamesSessionAndAdherence() {
        // A guided speed session with rep data → names it + reports adherence (2 of 3 on pace).
        let reps = [
            RepResult(repIndex: 1, repTotal: 3, title: nil, targetPaceSPerKm: 300, achievedPaceSPerKm: 298, distanceM: 400, durationS: 119),
            RepResult(repIndex: 2, repTotal: 3, title: nil, targetPaceSPerKm: 300, achievedPaceSPerKm: 330, distanceM: 400, durationS: 132),
            RepResult(repIndex: 3, repTotal: 3, title: nil, targetPaceSPerKm: 300, achievedPaceSPerKm: 301, distanceM: 400, durationS: 120),
        ]
        #expect(WorkoutReadTemplates.coachingClause(runType: .intervals, reps: reps)
                == "That's your speed session done ✓. 2 of 3 reps on pace.")
        // A long run with no guided reps → the aerobic-base tie-in.
        #expect(WorkoutReadTemplates.coachingClause(runType: .long, reps: [])
                == "That's your long run done ✓, aerobic base building.")
        // A free run (no prescription) adds no coaching clause.
        #expect(WorkoutReadTemplates.coachingClause(runType: .freeRun, reps: []) == nil)
        #expect(WorkoutReadTemplates.coachingClause(runType: nil, reps: []) == nil)
    }

    private func assertNoMedicalClaims(_ text: String) {
        let lower = text.lowercased()
        for banned in ["injur", "pain", "diagnos", "medical"] {
            #expect(!lower.contains(banned), "narrative contains banned term \(banned): \(text)")
        }
    }
}
