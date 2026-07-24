import Testing
import Foundation
@testable import Momentum

/// The tier above Aggressive (user call 2026-07-23): Podium — for athletes training to WIN.
/// Pins the levers, the structural upgrades, the graceful degradation, and the non-negotiable
/// safety rails that make it a coach and not a dare.
struct PodiumTierTests {

    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private func race(weeksOut: Int) -> Date {
        Calendar.current.date(byAdding: .weekOfYear, value: weeksOut, to: start)!
    }

    /// A committed marathoner: experienced, 6-day week, real base, sharp 5K.
    private func podiumInputs(days: Int = 6, intensity: PlanIntensity = .podium,
                              injuries: [InjuryArea] = []) -> PlanInputs {
        var inp = PlanInputs(disciplines: [.running], goal: .raceDistance,
                             daysPerWeek: days, equipment: .fullGym, sessionMinutes: 60,
                             raceDate: race(weeksOut: 20),
                             runningExperience: .experienced, liftingExperience: .some)
        inp.raceDistanceM = RaceDistance.marathon.meters
        inp.intensity = intensity
        inp.injuryHistory = injuries
        inp.currentWeeklyVolumeM = 60_000
        inp.longestRunM = 26_000
        return inp
    }

    @Test func podiumSitsAboveAggressiveOnEveryLever() {
        #expect(PlanIntensity.podium.weeklyRamp > PlanIntensity.aggressive.weeklyRamp)
        #expect(PlanIntensity.podium.qualityBias > PlanIntensity.aggressive.qualityBias)
        #expect(PlanIntensity.podium.floorDays == 5)
        #expect(PlanIntensity.aggressive.floorDays == 0)
        #expect(PlanIntensity.podium.tightLeash && PlanIntensity.aggressive.tightLeash)
        #expect(!PlanIntensity.balanced.tightLeash)
        #expect(PlanIntensity.podium.riskNote != nil)   // the honesty line is not optional
    }

    @Test func podiumPeaksAboveAggressiveAndLongRunsGoLonger() {
        let calibration = CalibrationSeed(estimatedP5kSPerKm: 250)   // sharp athlete — duration cap clears 35k
        let podium = PlanEngine.generate(profile: podiumInputs(), catalog: [],
                                         calibration: calibration, startDate: start)
        let aggressive = PlanEngine.generate(profile: podiumInputs(intensity: .aggressive), catalog: [],
                                             calibration: calibration, startDate: start)
        let podiumPeak = podium.weeks.map(\.runVolumeM).max() ?? 0
        let aggressivePeak = aggressive.weeks.map(\.runVolumeM).max() ?? 0
        #expect(podiumPeak > aggressivePeak, "the ~20% ceiling boost should show at peak")

        let podiumLongest = podium.weeks.flatMap(\.sessions)
            .filter { $0.runType == .long }.compactMap(\.targetDistanceM).max() ?? 0
        let aggressiveLongest = aggressive.weeks.flatMap(\.sessions)
            .filter { $0.runType == .long }.compactMap(\.targetDistanceM).max() ?? 0
        #expect(podiumLongest > aggressiveLongest, "the marathon long-run cap rises 32→35 km")
        #expect(podiumLongest <= 36_000, "…but never past the podium cap (+snap slack)")
    }

    @Test func trainingWeeksCarryAnOptionalShakeoutRestDaysStayOnDownWeeks() {
        let plan = PlanEngine.generate(profile: podiumInputs(), catalog: [], startDate: start)
        let training = plan.weeks.filter { !$0.isDeload && !$0.isTaper && $0.phase != .recovery
            && !$0.sessions.contains { $0.runType == .race } }
        let down = plan.weeks.filter { $0.isDeload || $0.isTaper }
        #expect(!training.isEmpty && !down.isEmpty)
        for week in training {
            let jogs = week.sessions.filter { $0.rationale?.contains("shakeout") == true }
            #expect(jogs.count == 1, "one optional shakeout per training week")
            #expect(jogs.first?.runType == .recovery)
            #expect((jogs.first?.targetDistanceM ?? 0) <= 3_300, "a shakeout is a jog, not a session")
        }
        for week in down {
            #expect(!week.sessions.contains { $0.rationale?.contains("shakeout") == true },
                    "down weeks keep their full rest days")
        }
    }

    @Test func aggressiveNeverGrowsAShakeout() {
        let plan = PlanEngine.generate(profile: podiumInputs(intensity: .aggressive), catalog: [], startDate: start)
        #expect(!plan.weeks.flatMap(\.sessions).contains { $0.rationale?.contains("shakeout") == true })
    }

    @Test func podiumDegradesGracefullyUnderItsDayFloor() {
        // 3 days: no boost, no shakeout — trains like Aggressive rather than pretending.
        let plan = PlanEngine.generate(profile: podiumInputs(days: 3), catalog: [], startDate: start)
        #expect(!plan.weeks.flatMap(\.sessions).contains { $0.rationale?.contains("shakeout") == true })
        for week in plan.weeks where !week.sessions.contains(where: { $0.runType == .race }) {
            #expect(week.sessions.count == 3)
        }
    }

    @Test func injuryHistoryHoldsPodiumToTheProtectiveCaps() {
        // A hurt body gets NO podium upgrades: no shakeout, ramp/quality capped at balanced —
        // the same promise the aggressive tier keeps.
        let plan = PlanEngine.generate(profile: podiumInputs(injuries: [.knee]), catalog: [], startDate: start)
        #expect(!plan.weeks.flatMap(\.sessions).contains { $0.rationale?.contains("shakeout") == true })
        let capped = PlanEngine.generate(profile: {
            var i = podiumInputs(injuries: [.knee]); i.intensity = .balanced; return i
        }(), catalog: [], startDate: start)
        let podiumPeak = plan.weeks.map(\.runVolumeM).max() ?? 0
        let balancedPeak = capped.weeks.map(\.runVolumeM).max() ?? 0
        #expect(podiumPeak <= balancedPeak + 100, "injury history must cap podium volume at balanced")
    }

    @Test func feasibilityNeverRecommendsPodium() {
        // Podium is a commitment the athlete makes, not advice the engine gives.
        for weeks in [2, 6, 12, 20, 52] {
            for exp in [ExperienceLevel.new, .some, .experienced] {
                let f = PlanFeasibility.assess(raceDistanceM: RaceDistance.marathon.meters,
                                               goalFinishTimeS: 9_000, currentP5kSPerKm: 280,
                                               currentWeeklyVolumeM: 50_000, weeksAvailable: weeks,
                                               experience: exp, daysPerWeek: 6)
                #expect(f.recommended != .podium)
            }
        }
    }
}
