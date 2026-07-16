import Testing
import Foundation
@testable import Momentum

/// Recovery Hub plan §11.1.2 fixtures — the race-day Form (TSB) projection: actual daily loads
/// concatenated with `PlannedLoad` estimates through the one impulse-response model, read at the
/// race-day point. The reference loop below re-derives the EWMA independently with the model's
/// published constants (CTL 42d, ATL 7d — FitnessFreshness.series), so a drifted constant or a
/// load landing on the wrong day fails loudly.
@MainActor
struct RaceProjectionTests {
    /// Fixed clock + UTC calendar so day-bucketing is deterministic on any machine.
    private let now = Date(timeIntervalSince1970: 1_760_000_000)   // 2025-10-09, mid-morning UTC
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private var today: Date { cal.startOfDay(for: now) }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    private func run(minutes: Double, rpe: Int = 6, onDay offset: Int) -> Workout {
        let w = Workout()
        w.type = .run
        w.startedAt = day(offset).addingTimeInterval(9.0 * 3600)   // 9am local, unambiguous bucket
        w.durationS = minutes * 60
        w.perceivedEffort = rpe
        return w
    }

    /// Independent reference: the exact exponentially-weighted impulse response over a daily-load
    /// array, written out with the published constants rather than calling the engine.
    private func reference(_ loads: [Double]) -> (ctl: Double, atl: Double) {
        let ctlAlpha = 1 - exp(-1.0 / 42.0)
        let atlAlpha = 1 - exp(-1.0 / 7.0)
        var ctl = 0.0, atl = 0.0
        for load in loads {
            ctl += ctlAlpha * (load - ctl)
            atl += atlAlpha * (load - atl)
        }
        return (ctl, atl)
    }

    @Test func raceDayTSBMatchesHandComputedImpulseResponse() throws {
        // Two known actual loads + two planned sessions, race in 7 days.
        // Actuals: 60' @ RPE 7 two days ago → 420; 30' @ RPE 6 yesterday → 180.
        let workouts = [run(minutes: 60, rpe: 7, onDay: -2), run(minutes: 30, rpe: 6, onDay: -1)]
        let planned = [(date: day(2), estLoad: 200.0), (date: day(5), estLoad: 120.0)]

        let p = try #require(RaceProjection.build(workouts: workouts, raceDate: day(7),
                                                  plannedLoads: planned, now: now, calendar: cal))

        // Hand-build the same daily-load array: 120 history days ending today, then 7 more to race.
        var loads = [Double](repeating: 0, count: 127)
        loads[117] = 420.0    // day −2 (today is index 119)
        loads[118] = 180.0    // day −1
        loads[121] = 200.0    // day +2
        loads[124] = 120.0    // day +5; race day itself stays 0 — a race-morning read
        let expected = reference(loads)

        #expect(abs(p.ctl - expected.ctl) < 0.000_000_1)
        #expect(abs(p.atl - expected.atl) < 0.000_000_1)
        #expect(abs(p.tsb - (expected.ctl - expected.atl)) < 0.000_000_1)
        #expect(p.daysToRace == 7)
        #expect(p.raceDay == day(7))
        #expect(p.band == RaceProjection.band(expected.ctl - expected.atl))

        // The projected series runs today → race day inclusive and ends on the race-day point.
        #expect(p.series.count == 8)
        #expect(p.series.first?.date == today)
        #expect(p.series.last?.date == day(7))
        #expect(p.series.last?.ctl == p.ctl)
        #expect(p.series.last?.atl == p.atl)
    }

    @Test func taperScenarioDecliningPlannedLoadsLiftTSB() throws {
        // A steady 8-week block (45' @ RPE 6 daily → load 270) leaves ATL ≈ CTL and Form pinned
        // low. A declining taper — each planned day lighter than the last — must lift projected
        // TSB above today's, and above what holding the block's load flat would project.
        let workouts = (1...56).map { run(minutes: 45, rpe: 6, onDay: -$0) }
        let raceDate = day(14)
        let taper: [(date: Date, estLoad: Double)] = (1...13).map {
            (date: day($0), estLoad: 195.0 - 15.0 * Double($0))   // 180 → 0, strictly declining
        }
        let flat: [(date: Date, estLoad: Double)] = (1...13).map {
            (date: day($0), estLoad: 270.0)
        }

        let tapered = try #require(RaceProjection.build(workouts: workouts, raceDate: raceDate,
                                                        plannedLoads: taper, now: now, calendar: cal))
        let held = try #require(RaceProjection.build(workouts: workouts, raceDate: raceDate,
                                                     plannedLoads: flat, now: now, calendar: cal))

        let todayTSB = try #require(tapered.series.first).tsb
        #expect(tapered.tsb > todayTSB)          // the taper's job: Form rises into race day
        #expect(tapered.tsb > held.tsb)          // and rises BECAUSE the loads decline
        #expect(tapered.band != .heavy)          // a real taper off a steady block arrives ≥ 0
    }

    @Test func nilWhenNoDatedRaceOrRaceTooClose() {
        let workouts = [run(minutes: 40, onDay: -3)]
        // No dated race.
        #expect(RaceProjection.build(workouts: workouts, raceDate: nil, plannedLoads: [],
                                     now: now, calendar: cal) == nil)
        // No plan at all (the model-convenience path).
        #expect(RaceProjection.build(workouts: workouts, plan: nil, now: now, calendar: cal) == nil)
        // Race behind us, race today, race 2 days out: all under the 3-day floor.
        for offset in [-1, 0, 2] {
            #expect(RaceProjection.build(workouts: workouts, raceDate: day(offset), plannedLoads: [],
                                         now: now, calendar: cal) == nil)
        }
        // Exactly 3 days out is the boundary: projectable.
        #expect(RaceProjection.build(workouts: workouts, raceDate: day(3), plannedLoads: [],
                                     now: now, calendar: cal) != nil)
    }

    @Test func missingPlannedSessionsDegradeToActualOnlyDecay() throws {
        // No remaining prescriptions → every future day is load 0 and both curves simply decay:
        // ctl(race) = ctl(today) · (1 − ctlAlpha)^days, same for atl with its own constant.
        let workouts = [run(minutes: 60, rpe: 6, onDay: -10), run(minutes: 50, rpe: 7, onDay: -4)]
        let p = try #require(RaceProjection.build(workouts: workouts, raceDate: day(10),
                                                  plannedLoads: [], now: now, calendar: cal))
        let start = try #require(p.series.first)
        let ctlDecay = pow(exp(-1.0 / 42.0), 10.0)
        let atlDecay = pow(exp(-1.0 / 7.0), 10.0)
        #expect(abs(p.ctl - start.ctl * ctlDecay) < 0.000_000_1)
        #expect(abs(p.atl - start.atl * atlDecay) < 0.000_000_1)
        // Fatigue fades faster than fitness, so an actual-only projection freshens toward CTL.
        #expect(p.tsb > start.tsb)
    }

    @Test func raceDayAndPastPlannedSessionsAreExcluded() throws {
        // A leftover past prescription and the race itself must not move the projection: history
        // is real workouts only, and the race never counts against its own morning's form.
        let workouts = [run(minutes: 45, rpe: 6, onDay: -1)]
        let realTaper = [(date: day(3), estLoad: 150.0)]
        let padded = realTaper + [(date: day(-1), estLoad: 300.0),   // past-dated leftover
                                  (date: day(7), estLoad: 500.0),    // the race itself
                                  (date: day(4), estLoad: 0.0)]      // zero-load noise

        let clean = try #require(RaceProjection.build(workouts: workouts, raceDate: day(7),
                                                      plannedLoads: realTaper, now: now, calendar: cal))
        let noisy = try #require(RaceProjection.build(workouts: workouts, raceDate: day(7),
                                                      plannedLoads: padded, now: now, calendar: cal))
        #expect(clean.ctl == noisy.ctl)
        #expect(clean.atl == noisy.atl)
        #expect(clean.series == noisy.series)
    }

    @Test func bandBoundaries() {
        // fresh ≥ +10 · ready 0..<10 · heavy < 0 (§11.1.2 — tighter than formLabel's mid-block bands).
        #expect(RaceProjection.band(-30.0) == .heavy)
        #expect(RaceProjection.band(-0.001) == .heavy)
        #expect(RaceProjection.band(0.0) == .ready)
        #expect(RaceProjection.band(9.999) == .ready)
        #expect(RaceProjection.band(10.0) == .fresh)
        #expect(RaceProjection.band(25.0) == .fresh)
    }
}
