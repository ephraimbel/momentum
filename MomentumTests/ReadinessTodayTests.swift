import Testing
import Foundation
@testable import Momentum

/// `ReadinessToday` — the ONE full-blend recipe every surface (Today deck, Trends strip, Health
/// hub) must compute. These tests pin the wiring: the recipe threads banded baselines and the
/// learned sleep context, and it genuinely differs from the retired "light" construction — the
/// difference that once showed 91 on the deck and 75 in Progress.
struct ReadinessTodayTests {

    private var calendar: Calendar { Calendar(identifier: .gregorian) }
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Ten days of gently varying HRV around 100 ms — enough history to band a baseline.
    private func hrvHistory() -> [(day: Date, value: Double)] {
        (1...10).compactMap { ago in
            guard let d = calendar.date(byAdding: .day, value: -ago, to: now) else { return nil }
            return (day: d, value: 100 + Double(ago % 5) - 2)
        }
    }

    @Test @MainActor func recipeMatchesHubAssembly() {
        var signals = RecoverySignals()
        signals.hrvMs = 104
        let hist = hrvHistory()
        let viaRecipe = ReadinessToday.build(workouts: [], checkins: [], signals: signals,
                                             hrvHist: hist, rhrHist: [], nights: [],
                                             now: now, calendar: calendar)
        // Hand-assembled exactly the way the Health hub used to build its hero score.
        let manual = MorningReadiness(
            load: nil, signals: signals,
            hrvBaseline: HealthBaselines.build(from: hist, windowDays: HealthBaselines.Window.hrv,
                                               now: now, calendar: calendar),
            restingHRBaseline: nil, sleepNeedH: 8.0, sleepDebt14H: 0, checkin: nil)
        #expect(viaRecipe != nil && manual != nil)
        #expect(viaRecipe?.score == manual?.score)
        #expect(viaRecipe?.band == manual?.band)
    }

    @Test @MainActor func fullBlendDiffersFromRetiredLightBlend() {
        // HRV a touch above a banded norm: the z-path reads it far stronger than the coarse
        // ratio fallback — the exact class of mismatch the deck used to show vs the hub.
        var signals = RecoverySignals()
        signals.hrvMs = 108
        signals.hrvBaselineMs = 100
        let full = ReadinessToday.build(workouts: [], checkins: [], signals: signals,
                                        hrvHist: hrvHistory(), rhrHist: [], nights: [],
                                        now: now, calendar: calendar)
        let light = MorningReadiness(load: nil, signals: signals, checkin: nil)   // the old deck path
        #expect(full != nil && light != nil)
        #expect(full?.score != light?.score)
    }

    @Test @MainActor func noHistoryDegradesToTheSameNumberAsLight() {
        // Without histories or nights the recipe IS the light blend — a watch-less athlete's
        // number doesn't change because the plumbing did.
        var signals = RecoverySignals()
        signals.hrvMs = 104
        signals.hrvBaselineMs = 100
        signals.sleepHours = 7
        let viaRecipe = ReadinessToday.build(workouts: [], checkins: [], signals: signals,
                                             hrvHist: [], rhrHist: [], nights: [],
                                             now: now, calendar: calendar)
        let light = MorningReadiness(load: nil, signals: signals, checkin: nil)
        #expect(viaRecipe?.score == light?.score)
    }
}
