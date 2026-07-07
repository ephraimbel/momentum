import Testing
@testable import Momentum

/// Post-run RPE → adaptation judging (running-excellence). Pure; compares felt vs prescribed effort.
struct EffortAdaptationTests {

    @Test func judgesEffortAgainstPrescription() {
        // An easy / long day that felt brutal is the clearest fatigue signal → recover.
        #expect(EffortAdaptation.judge(rpe: 8, runType: .easy) == .recover)
        #expect(EffortAdaptation.judge(rpe: 8, runType: .long) == .recover)
        // Notably harder than prescribed (easy is expected ~4; felt 7) → ease the block.
        #expect(EffortAdaptation.judge(rpe: 7, runType: .easy) == .ease)
        // A hard session that felt appropriately hard → no change.
        #expect(EffortAdaptation.judge(rpe: 8, runType: .intervals) == .none)
        #expect(EffortAdaptation.judge(rpe: 8, runType: .tempo) == .none)
        // A hard session that felt easy → real headroom (informational only).
        #expect(EffortAdaptation.judge(rpe: 5, runType: .intervals) == .headroom)
        // Missing data → none.
        #expect(EffortAdaptation.judge(rpe: nil, runType: .easy) == .none)
        #expect(EffortAdaptation.judge(rpe: 6, runType: nil) == .none)
    }

    @Test func onlyEaseAndRecoverNarrate() {
        #expect(EffortAdaptation.note(for: .ease) != nil)
        #expect(EffortAdaptation.note(for: .recover) != nil)
        #expect(EffortAdaptation.note(for: .headroom) == nil)
        #expect(EffortAdaptation.note(for: .none) == nil)
    }

    @Test func noteNamesTheSessionAndEffort() {
        let ease = EffortAdaptation.note(for: .ease, runType: .tempo, rpe: 9)
        #expect(ease?.detail.contains("tempo") == true && ease?.detail.contains("9/10") == true)
        let recover = EffortAdaptation.note(for: .recover, runType: .easy, rpe: 8)
        #expect(recover?.detail.contains("easy run") == true && recover?.detail.contains("8/10") == true)
        // Without context it still reads naturally (generic fallback).
        #expect(EffortAdaptation.note(for: .ease)?.detail.contains("session") == true)
    }

    @Test func expectedEffortRisesWithIntensity() {
        #expect(EffortAdaptation.expectedRPE(.recovery) < EffortAdaptation.expectedRPE(.easy))
        #expect(EffortAdaptation.expectedRPE(.easy) < EffortAdaptation.expectedRPE(.tempo))
        #expect(EffortAdaptation.expectedRPE(.tempo) < EffortAdaptation.expectedRPE(.intervals))
        #expect(EffortAdaptation.expectedRPE(.intervals) < EffortAdaptation.expectedRPE(.race))
    }
}
