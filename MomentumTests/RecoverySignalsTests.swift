import Testing
import Foundation
@testable import Momentum

/// Device-backed readiness (PRD §4.8) — HRV / resting-HR / sleep anchors and the deterministic blend
/// that adjusts the load-derived readiness score.
struct RecoverySignalsTests {

    @Test func emptyHasNoPhysioAndLeavesScoreUntouched() {
        let s = RecoverySignals.empty
        #expect(!s.hasPhysio)
        #expect(s.blendedReadiness(base: 70) == 70)
        #expect(s.hrvNote == nil && s.restingHRNote == nil && s.sleepNote == nil)
    }

    @Test func hrvAnchorsAgainstBaseline() {
        #expect(RecoverySignals(hrvMs: 70, hrvBaselineMs: 60).hrvTrend == .up)
        #expect(RecoverySignals(hrvMs: 61, hrvBaselineMs: 60).hrvTrend == .steady)
        #expect(RecoverySignals(hrvMs: 48, hrvBaselineMs: 60).hrvTrend == .down)
        // A reading with no baseline yet still reports its presence, but as "learning".
        #expect(RecoverySignals(hrvMs: 55).hrvNote == "learning your norm")
    }

    @Test func restingHRElevatedReadsAsCaution() {
        #expect(RecoverySignals(restingHR: 48, restingHRBaseline: 48).restingHRNote == "steady")
        #expect(RecoverySignals(restingHR: 51, restingHRBaseline: 48).restingHRNote == "slightly up")
        #expect(RecoverySignals(restingHR: 56, restingHRBaseline: 48).restingHRNote == "elevated")
    }

    @Test func sleepBands() {
        #expect(RecoverySignals(sleepHours: 8).sleepNote == "solid")
        #expect(RecoverySignals(sleepHours: 6.5).sleepNote == "moderate")
        #expect(RecoverySignals(sleepHours: 5.4).sleepNote == "short")
        #expect(RecoverySignals(sleepHours: 4).sleepNote == "very short")
    }

    @Test func goodSignalsRaiseReadiness() {
        let s = RecoverySignals(hrvMs: 70, hrvBaselineMs: 60, restingHR: 47, restingHRBaseline: 48, sleepHours: 8)
        #expect(s.blendedReadiness(base: 80) > 80)          // HRV up + solid sleep push it higher
        #expect(s.blendedReadiness(base: 98) == 100)        // clamped at 100
    }

    @Test func poorSignalsLowerReadiness() {
        let s = RecoverySignals(hrvMs: 44, hrvBaselineMs: 60, restingHR: 57, restingHRBaseline: 48, sleepHours: 4.5)
        let blended = s.blendedReadiness(base: 85)
        #expect(blended < 85)                                // suppressed HRV + elevated RHR + short sleep
        #expect(blended == max(0, min(100, blended)))        // stays in range
        #expect(s.blendedReadiness(base: 10) >= 0)           // clamped at 0
    }

    @Test func partialSignalsStillBlend() {
        // Only sleep present — still counts as physio and nudges the score.
        let s = RecoverySignals(sleepHours: 8)
        #expect(s.hasPhysio)
        #expect(s.blendedReadiness(base: 70) == 75)
    }

    @Test func displayFormatting() {
        let s = RecoverySignals(hrvMs: 67.6, restingHR: 48, sleepHours: 7.5)
        #expect(s.hrvValue == "68")
        #expect(s.restingHRValue == "48")
        #expect(s.sleepValue == "7h 30m")
    }
}
