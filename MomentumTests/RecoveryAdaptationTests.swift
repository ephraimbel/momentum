import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Recovery-driven daily adaptation: two independent warning signs ease today's quality run — one
/// noisy night never lurches the plan; the aggressive tier runs on a tighter leash.
@MainActor
struct RecoveryAdaptationTests {

    private func signals(hrv: Double? = nil, hrvBase: Double? = nil,
                         rhr: Int? = nil, rhrBase: Double? = nil,
                         sleep: Double? = nil) -> RecoverySignals {
        RecoverySignals(hrvMs: hrv, hrvBaselineMs: hrvBase,
                        restingHR: rhr, restingHRBaseline: rhrBase, sleepHours: sleep)
    }

    @Test func oneBadSignalNeverLurchesThePlan() {
        // HRV suppressed but sleep + RHR fine → hold steady (noise-resistant by design).
        let s = signals(hrv: 40, hrvBase: 55, rhr: 48, rhrBase: 48, sleep: 8)
        #expect(RecoveryAdaptation.decide(signals: s, intensity: .balanced) == nil)
        // A single short night alone → also nothing.
        let tired = signals(hrv: 55, hrvBase: 55, sleep: 5.0)
        #expect(RecoveryAdaptation.decide(signals: tired, intensity: .balanced) == nil)
    }

    @Test func twoWarningSignsEaseTodayWithAPlainReason() throws {
        // HRV down + resting HR well elevated → ease, and the reason names both.
        let s = signals(hrv: 40, hrvBase: 55, rhr: 55, rhrBase: 48)
        let d = try #require(RecoveryAdaptation.decide(signals: s, intensity: .balanced))
        #expect(d.reason.contains("HRV"))
        #expect(d.reason.contains("resting HR"))
    }

    @Test func aggressiveRunsOnATighterLeash() {
        // HRV down + resting HR only *slightly* up (2 bpm): balanced holds; aggressive eases.
        let s = signals(hrv: 40, hrvBase: 55, rhr: 50, rhrBase: 48)
        #expect(RecoveryAdaptation.decide(signals: s, intensity: .balanced) == nil)
        #expect(RecoveryAdaptation.decide(signals: s, intensity: .aggressive) != nil)
        // 6.2h sleep counts as short only for aggressive.
        let t = signals(hrv: 40, hrvBase: 55, sleep: 6.2)
        #expect(RecoveryAdaptation.decide(signals: t, intensity: .balanced) == nil)
        #expect(RecoveryAdaptation.decide(signals: t, intensity: .aggressive) != nil)
    }

    @Test func noSignalsMeansNoDecision() {
        #expect(RecoveryAdaptation.decide(signals: .empty, intensity: .aggressive) == nil)
    }

    @Test func theAthletesOwnWordsCountAsSignals() throws {
        // Clean wearables, but the athlete says sore legs AND low energy → ease (their word stands
        // equal to the sensor). One subjective signal alone → still hold.
        let rough = DailyCheckin(energy: .low, legs: .sore)
        let d = try #require(RecoveryAdaptation.decide(signals: .empty, intensity: .balanced, checkin: rough))
        #expect(d.reason.contains("legs"))
        #expect(d.reason.contains("energy"))

        let justTired = DailyCheckin(energy: .low, legs: .fresh)
        #expect(RecoveryAdaptation.decide(signals: .empty, intensity: .balanced, checkin: justTired) == nil)

        // A check-in signal + a wearable signal combine across sources.
        let hrvDown = signals(hrv: 40, hrvBase: 55)
        let sore = DailyCheckin(energy: .full, legs: .sore)
        #expect(RecoveryAdaptation.decide(signals: hrvDown, intensity: .balanced, checkin: sore) != nil)
    }

    @Test func tripwireNeedsLoadAndBodyToAgree() throws {
        let suppressed = signals(hrv: 40, hrvBase: 55)
        // Load spike alone: could be a planned peak week — hold.
        #expect(RecoveryAdaptation.tripwire(acwr: 1.8, signals: .empty) == nil)
        // Body warning alone at sane load: the daily ease's job, not a cutback.
        #expect(RecoveryAdaptation.tripwire(acwr: 1.1, signals: suppressed) == nil)
        // Both: the overtraining signature — forced cutback, reason names both.
        let d = try #require(RecoveryAdaptation.tripwire(acwr: 1.8, signals: suppressed))
        #expect(d.reason.contains("load"))
        #expect(d.reason.contains("HRV"))
    }

    @Test func cutbackAppliesOncePerWeekAndMakesNextSessionRecovery() throws {
        let pc = PersistenceController.inMemory(); let ctx = pc.container.mainContext
        let vm = OnboardingViewModel()
        vm.activities = [.run]; vm.goal = .endurance; vm.experience = .some; vm.weeklyRunVolumeM = 30_000
        let profile = vm.finish(in: ctx)
        let plan = try #require(profile.plan)

        let d = RecoveryAdaptation.Decision(reason: "your training load has spiked and HRV is suppressed")
        let note = try #require(RecoveryAdaptation.applyCutback(d, plan: plan, in: ctx))
        #expect(note.headline == "Cutback week")
        #expect(note.detail.contains("not failing"))              // no-shame framing, always

        // The very next session became a true recovery day; the throttle is set.
        let next = try #require(plan.sessions.filter { $0.status == .planned }.min { $0.date < $1.date })
        if next.strengthTargets.isEmpty { #expect(next.runType == .recovery) }
        #expect(plan.lastAdaptedAt != nil)

        // A second tripwire inside the same week is refused — a cutback can never spiral.
        #expect(RecoveryAdaptation.applyCutback(d, plan: plan, in: ctx) == nil)
    }

    @Test func easesOnlyTodaysQualityRunAndRecordsWhy() throws {
        let pc = PersistenceController.inMemory(); let ctx = pc.container.mainContext
        let vm = OnboardingViewModel()
        vm.activities = [.run]; vm.goal = .raceDistance; vm.raceDistance = .tenK
        vm.hasRace = true; vm.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 10, to: Date())!
        vm.experience = .some; vm.weeklyRunVolumeM = 30_000
        let profile = vm.finish(in: ctx)
        profile.distanceUnit = "metric"   // deterministic clean-km snapping, locale-independent
        let plan = try #require(profile.plan)

        // Force a quality session onto today so there's something to protect.
        let session = try #require(plan.sessions.filter { $0.discipline == .running }.min { $0.date < $1.date })
        session.date = Date()
        session.runType = .intervals
        session.targetDistanceM = 8_000
        let othersBefore = plan.sessions.filter { $0 !== session }.map(\.runType)

        let d = RecoveryAdaptation.Decision(reason: "HRV below your norm and a short night (5.5h)")
        let note = try #require(RecoveryAdaptation.applyToToday(d, plan: plan, in: ctx))
        #expect(note.headline == "Easy day instead")

        #expect(session.runType == .easy)                        // today softened…
        #expect(session.targetDistanceM == 7_000)                // …volume trimmed 10% (8000→7200), snapped to 7.0 km
        #expect(session.rationale?.contains("HRV") == true)      // reason on the session itself
        let othersAfter = plan.sessions.filter { $0 !== session }.map(\.runType)
        #expect(othersBefore == othersAfter)                     // ONLY today — bounded, not a rewrite

        // Recorded to adaptation history (and mirrored to the inbox via CoachingEvent).
        let events = (try? ctx.fetch(FetchDescriptor<CoachingEvent>())) ?? []
        #expect(events.contains { $0.headline == "Easy day instead" })

        // An already-easy day has nothing to protect.
        session.runType = .easy
        #expect(RecoveryAdaptation.applyToToday(d, plan: plan, in: ctx) == nil)
    }
}
