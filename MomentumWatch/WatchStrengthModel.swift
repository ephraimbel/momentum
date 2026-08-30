import Foundation
import WatchKit
import Observation

/// On-wrist strength logging (PRD §8.10): adjust weight/reps, log a set (haptic + auto rest timer),
/// repeat. Weight is stored SI (kg) and displayed in the user's unit; steps are unit-natural (5 lb /
/// 2.5 kg). Standalone for now — Slice 4 hands the planned exercise + targets over from the phone and
/// syncs the logged sets back.
@MainActor
@Observable
final class WatchStrengthModel {
    let unit = WeightUnit.default()
    private(set) var weightKg: Double = 20      // a sensible bar-ish default
    private(set) var reps = 8
    private(set) var completedSets = 0
    private(set) var restEndsAt: Date?

    let restDurationS: TimeInterval = 120

    private var weightStepKg: Double { unit == .lb ? 5 * Formatters.kgPerLb : 2.5 }

    func addWeight(_ direction: Double) { weightKg = max(0, weightKg + direction * weightStepKg) }
    func addReps(_ delta: Int) { reps = max(0, reps + delta) }

    // MARK: Crown control — the premium way to land on a plate weight

    /// Weight in the athlete's display unit, for the crown binding.
    var weightDisplayValue: Double { unit == .lb ? weightKg / Formatters.kgPerLb : weightKg }
    /// One crown detent = one plate step (5 lb / 2.5 kg) — the same step the buttons take.
    var weightStepDisplay: Double { unit == .lb ? 5 : 2.5 }

    func setWeightDisplay(_ value: Double) {
        let kg = unit == .lb ? value * Formatters.kgPerLb : value
        weightKg = max(0, kg)
    }

    /// The wrist's voice coach — the same words the phone's gym coach says, minus the exercise
    /// name, which the standalone wrist logger doesn't have. Silent unless the phone has pushed
    /// the Pro gate across (`WatchSyncStore.voiceCoachOn`).
    private var voice: WatchVoiceCoach { .shared }

    /// Warm the speech stack as the logger opens, so the first rest call lands on the beat.
    func begin() { voice.prepare() }

    /// Log the current set: success haptic + start the rest countdown (fires on the wrist).
    func logSet() {
        completedSets += 1
        WKInterfaceDevice.current().play(.success)
        restEndsAt = Date().addingTimeInterval(restDurationS)
        voice.announce(CoachingCueBuilder.restStart(seconds: restDurationS))
    }

    /// The rest ran out. Distinct from `skipRest` on purpose: a rest the athlete cut short is not
    /// a rest that finished, and speaking over the set they just started is worse than silence.
    func completeRest() {
        restEndsAt = nil
        voice.announce(CoachingCueBuilder.restComplete())
    }

    func skipRest() {
        restEndsAt = nil
        voice.stop()
    }

    func restRemaining(at now: Date) -> TimeInterval {
        guard let restEndsAt else { return 0 }
        return max(0, restEndsAt.timeIntervalSince(now))
    }

    var weightText: String { Formatters.weight(kg: weightKg, unit: unit) }

    #if DEBUG
    /// Pre-seed a mid-session state (a couple sets logged, resting) so the sim can verify the layout.
    func seedDemoIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--watch-demo") else { return }
        weightKg = 60; reps = 5; completedSets = 2
        restEndsAt = Date().addingTimeInterval(95)
    }
    #endif
}
