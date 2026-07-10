import Testing
import Foundation
@testable import Momentum

/// Deterministic recovery/readiness (PRD §4.8) — monotony, strain, and the rules-only readiness band.
@MainActor
struct RecoveryModelTests {
    private func run(daysAgo: Int, minutes: Double, rpe: Int? = nil) -> Workout {
        let w = Workout()
        w.type = .run
        w.startedAt = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        w.durationS = minutes * 60
        w.perceivedEffort = rpe
        return w
    }

    @Test func noHistoryHasNoReadiness() {
        #expect(!RecoveryModel(workouts: []).hasData)
    }

    @Test func steadyVariedLoadIsWellRecovered() {
        // Every 3 days for 4 weeks → sweet-spot ACWR, low monotony, rest days present.
        let ws = stride(from: 0, through: 27, by: 3).map { run(daysAgo: $0, minutes: 40) }
        let r = RecoveryModel(workouts: ws)
        #expect(r.hasData)
        #expect(r.acwr < 1.3)
        #expect(r.restDays > 0)
        #expect(r.score >= 80)
        #expect(r.readiness == .primed)
    }

    @Test func acuteSpikeLowersReadiness() {
        var ws = [run(daysAgo: 20, minutes: 30)]                  // thin chronic base
        ws += (0..<4).map { run(daysAgo: $0, minutes: 60) }       // big recent block
        let r = RecoveryModel(workouts: ws)
        #expect(r.acwr > 1.5)
        #expect(r.score < 65)
        #expect(r.readiness != .primed && r.readiness != .ready)
    }

    @Test func dailyGrindWithNoRestIsDepleted() {
        let ws = (0..<7).map { run(daysAgo: $0, minutes: 45) }    // same load 7 days straight
        let r = RecoveryModel(workouts: ws)
        #expect(r.restDays == 0)
        #expect(r.monotony == 2.5)          // all-equal nonzero days ⇒ max monotony (SD≈0 fallback)
        #expect(r.readiness == .depleted)
        #expect(r.score < 25)
    }

    @Test func monotonyMatchesMeanOverSD() {
        // Loads (RPE 10 makes load = 10×minutes): today 600, yesterday 200, rest 0.
        let ws = [run(daysAgo: 0, minutes: 60, rpe: 10), run(daysAgo: 1, minutes: 20, rpe: 10)]
        let r = RecoveryModel(workouts: ws)
        // mean = 800/7 = 114.29; SD over [600,200,0,0,0,0,0] ≈ 209.95 → monotony ≈ 0.544.
        #expect(abs(r.monotony - 0.544) < 0.01)
        #expect(abs(r.strain - r.weeklyLoad * r.monotony) < 0.001)
        #expect(r.weeklyLoad == 800)
    }

    @Test func bandThresholds() {
        #expect(RecoveryModel.band(95) == .primed)
        #expect(RecoveryModel.band(80) == .primed)
        #expect(RecoveryModel.band(79) == .ready)
        #expect(RecoveryModel.band(64) == .moderate)
        #expect(RecoveryModel.band(44) == .strained)
        #expect(RecoveryModel.band(24) == .depleted)
    }
}

/// The canonical session-load formula shared across surfaces.
@MainActor
struct TrainingLoadTests {
    @Test func loadIsDurationTimesEffort() {
        let w = Workout(); w.type = .run; w.durationS = 60 * 60; w.perceivedEffort = 8
        #expect(TrainingLoad.session(w) == 60 * 8)          // 60 min × RPE 8
    }

    @Test func defaultsByDisciplineWhenNoRPE() {
        let w = Workout(); w.type = .walk; w.durationS = 30 * 60   // walk default RPE 4
        #expect(TrainingLoad.session(w) == 30 * 4)
    }

    @Test func distanceFallbackWhenNoDuration() {
        let w = Workout(); w.type = .run; w.durationS = 0
        let g = GPSDetail(); g.distanceM = 5000; w.gps = g
        #expect(TrainingLoad.session(w) == 5 * 6)           // 5 km × 6
    }
}
