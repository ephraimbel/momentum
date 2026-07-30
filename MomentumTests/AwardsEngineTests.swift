import Foundation
import Testing
@testable import Momentum

/// Fixture tests for the deterministic awards engine — every threshold crossing, its attribution
/// (when + which workout), and the catalog↔engine agreement that keeps a defined award from ever
/// drifting away from its detection rule.
struct AwardsEngineTests {

    // MARK: Fixtures

    /// A fixed calendar + reference date so day math never depends on the test machine's clock.
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_770_000_000)   // 2026-02-02 02:40 UTC

    private func date(daysAgo: Int, hour: Int = 9) -> Date {
        let base = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base)!
    }

    private func run(_ daysAgo: Int, km: Double, hour: Int = 9, climb: Double = 0,
                     type: WorkoutType = .run) -> AwardsEngine.Activity {
        AwardsEngine.Activity(id: UUID(), date: date(daysAgo: daysAgo, hour: hour), type: type,
                              distanceM: km * 1000, elevationGainM: climb,
                              durationS: km * 360, volumeKg: 0, startHour: hour)
    }

    private func lift(_ daysAgo: Int, volumeKg: Double) -> AwardsEngine.Activity {
        AwardsEngine.Activity(id: UUID(), date: date(daysAgo: daysAgo), type: .strength,
                              distanceM: 0, elevationGainM: 0, durationS: 3000,
                              volumeKg: volumeKg, startHour: 9)
    }

    private func snapshot(activities: [AwardsEngine.Activity] = [],
                          records: [AwardsEngine.RecordFact] = [],
                          planned: [AwardsEngine.PlannedFact] = [],
                          streakDays: Set<Int> = []) -> AwardsEngine.Snapshot {
        AwardsEngine.Snapshot(activities: activities, records: records, planned: planned,
                              streakDays: streakDays, now: now)
    }

    private func earned(_ s: AwardsEngine.Snapshot) -> [String: AwardsEngine.Earned] {
        Dictionary(uniqueKeysWithValues:
            AwardsEngine.evaluate(s, calendar: calendar).map { ($0.awardID, $0) })
    }

    // MARK: Catalog sanity

    @Test func catalogIDsAreUniqueAndComplete() {
        let ids = AwardsCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for collection in Award.Collection.allCases {
            let awards = AwardsCatalog.awards(in: collection)
            #expect(!awards.isEmpty)
            #expect(awards.contains { $0.isCrown }, "\(collection) has no crown")
        }
    }

    /// Every threshold the engine can emit must exist in the catalog, and vice versa for the
    /// threshold-driven collections — an id typo on either side fails here, not in production.
    @Test func engineAndCatalogAgree() {
        let catalogIDs = Set(AwardsCatalog.all.map(\.id))
        var engineIDs = Set<String>()
        engineIDs.formUnion(AwardsEngine.lifetimeDistanceM.map(\.id))
        engineIDs.formUnion(AwardsEngine.singleRunM.map(\.id))
        engineIDs.formUnion(AwardsEngine.lifetimeClimbM.map(\.id))
        engineIDs.formUnion(AwardsEngine.benchmarkS.map(\.id))
        engineIDs.formUnion(AwardsEngine.streakDaysThresholds.map(\.id))
        engineIDs.formUnion(AwardsEngine.perfectWeeks.map(\.id))
        engineIDs.formUnion(AwardsEngine.strengthSessions.map(\.id))
        engineIDs.formUnion(AwardsEngine.lifetimeVolumeKg.map(\.id))
        engineIDs.formUnion(AwardsEngine.sessionCounts.map(\.id))
        engineIDs.formUnion(AwardsEngine.weeklyRunM.map(\.id))
        engineIDs.formUnion(AwardsEngine.rideLifetimeM.map(\.id))
        engineIDs.formUnion(AwardsEngine.sessionDurationS.map(\.id))
        engineIDs.formUnion(AwardsEngine.singleClimbM.map(\.id))
        engineIDs.formUnion(AwardsEngine.raceCounts.map(\.id))
        engineIDs.formUnion(AwardsEngine.setCounts.map(\.id))
        engineIDs.formUnion(["longrun.first", "consistency.dawn", "consistency.night",
                             "training.racepr", "training.return",
                             "ride.century", "strength.coverage",
                             "moments.newyear", "moments.seasons", "moments.wanderer"])
        #expect(engineIDs == catalogIDs)
    }

    /// Every award has a computable progress reading (the gallery's locked arc relies on it).
    @Test func everyAwardHasProgress() {
        let s = snapshot(activities: [run(3, km: 10)])
        for award in AwardsCatalog.all {
            #expect(AwardsEngine.progress(toward: award, in: s, calendar: calendar) != nil,
                    "no progress rule for \(award.id)")
        }
    }

    // MARK: Distance

    @Test func lifetimeDistanceAttributesTheCrossingRun() {
        let runs = [run(10, km: 20), run(5, km: 35), run(2, km: 10)]
        let e = earned(snapshot(activities: runs))
        // 20 + 35 crosses 50 km on the second run — not the third.
        #expect(e["distance.50"]?.workoutID == runs[1].id)
        #expect(e["distance.50"]?.earnedAt == runs[1].date)
        #expect(e["distance.100"] == nil)
    }

    @Test func ridesDoNotFeedRunningDistance() {
        let e = earned(snapshot(activities: [run(3, km: 60, type: .ride)]))
        #expect(e["distance.50"] == nil)
    }

    @Test func trailRunsCount() {
        let e = earned(snapshot(activities: [run(3, km: 60, type: .trailRun)]))
        #expect(e["distance.50"] != nil)
    }

    // MARK: Long run

    @Test func firstRunNeedsARealRun() {
        #expect(earned(snapshot(activities: [run(1, km: 0.4)]))["longrun.first"] == nil)
        let real = run(1, km: 3)
        let e = earned(snapshot(activities: [real]))
        #expect(e["longrun.first"]?.workoutID == real.id)
    }

    @Test func marathonToleratesGPSUnderage() {
        // 42.0 km on the watch is a marathon (0.5% tolerance); 41.9 km is not.
        #expect(earned(snapshot(activities: [run(1, km: 42.0)]))["longrun.marathon"] != nil)
        #expect(earned(snapshot(activities: [run(1, km: 41.9)]))["longrun.marathon"] == nil)
    }

    @Test func longRunLadderEarnsEveryRungItPasses() {
        let big = run(2, km: 22)
        let e = earned(snapshot(activities: [big]))
        for id in ["longrun.first", "longrun.5k", "longrun.10k", "longrun.half"] {
            #expect(e[id]?.workoutID == big.id, "\(id) missing")
        }
        #expect(e["longrun.marathon"] == nil)
    }

    // MARK: Climb

    @Test func climbAccumulatesAcrossFootSports() {
        let hike = run(8, km: 12, climb: 5000, type: .hike)
        let trail = run(3, km: 10, climb: 4000, type: .trailRun)
        let e = earned(snapshot(activities: [hike, trail]))
        #expect(e["climb.5000"]?.workoutID == hike.id)
        #expect(e["climb.everest"]?.workoutID == trail.id)   // 9,000 crosses 8,849 here
        #expect(e["climb.25000"] == nil)
    }

    // MARK: Speed

    @Test func benchmarksFallAtTheFirstRecordUnderTheBar() {
        let w1 = UUID(), w2 = UUID()
        let records = [
            AwardsEngine.RecordFact(type: .fastest5k, value: 1900, achievedAt: date(daysAgo: 30), workoutID: w1),
            AwardsEngine.RecordFact(type: .fastest5k, value: 1750, achievedAt: date(daysAgo: 12), workoutID: w2),
            AwardsEngine.RecordFact(type: .fastest10k, value: 3550, achievedAt: date(daysAgo: 5), workoutID: w2),
        ]
        let e = earned(snapshot(records: records))
        #expect(e["speed.5k.sub30"]?.workoutID == w2)   // 1750 is the first row under 1800
        #expect(e["speed.5k.sub25"] == nil)
        #expect(e["speed.10k.sub60"]?.workoutID == w2)
    }

    // MARK: Streaks

    @Test func streakSurvivesTheGraceDayAndDatesTheCrossing() {
        let today = StreakCalculator.localDay(now, calendar: calendar)
        // 8 counting days with one forgiven gap: days -8…-4, (gap), -2…0.
        var days = Set((0...2).map { today - $0 })
        days.formUnion((4...8).map { today - $0 })
        let e = earned(snapshot(streakDays: days))
        #expect(e["streak.7"] != nil)
        // The 7th counting day is `today - 1` (5 + gap + 2 walked in order from day -8).
        let expected = calendar.date(byAdding: .day, value: -1, to: now)!
        #expect(abs(e["streak.7"]!.earnedAt.timeIntervalSince(expected)) < 1)
        #expect(e["streak.14"] == nil)
    }

    @Test func twoMissedDaysBreakTheStreak() {
        let today = StreakCalculator.localDay(now, calendar: calendar)
        var days = Set((0...3).map { today - $0 })       // 4-day current run
        days.formUnion((6...9).map { today - $0 })       // broken by a 2-day gap
        #expect(earned(snapshot(streakDays: days))["streak.7"] == nil)
    }

    // MARK: Time of day

    @Test func dawnPatrolSealsOnTheFifthEarlyStart() {
        let early = (1...5).map { run(20 - $0, km: 5, hour: 5) }
        let e = earned(snapshot(activities: early + [run(2, km: 5, hour: 12)]))
        #expect(e["consistency.dawn"]?.workoutID == early[4].id)
        #expect(e["consistency.night"] == nil)
    }

    // MARK: Training

    @Test func perfectWeekNeedsAFullCompletedWeek() {
        // Sessions anchored to a real calendar-week start, so a fixture can never straddle a week
        // boundary and silently split into two under-count weeks.
        func week(weeksAgo: Int, statuses: [SessionStatus]) -> [AwardsEngine.PlannedFact] {
            let anchor = calendar.date(byAdding: .day, value: -7 * weeksAgo, to: now)!
            let start = calendar.dateInterval(of: .weekOfYear, for: anchor)!.start
            return statuses.enumerated().map { i, status in
                AwardsEngine.PlannedFact(
                    date: calendar.date(byAdding: .day, value: i, to: start)!.addingTimeInterval(9 * 3600),
                    status: status, isRace: false, workoutID: nil)
            }
        }
        // A completed week of 3, well in the past.
        let good = week(weeksAgo: 4, statuses: [.completed, .completed, .completed])
        #expect(earned(snapshot(planned: good))["training.perfectweek"] != nil)
        // One session moved → not perfect.
        let moved = week(weeksAgo: 4, statuses: [.completed, .moved, .completed])
        #expect(earned(snapshot(planned: moved))["training.perfectweek"] == nil)
        // Only two sessions → below the floor.
        let light = week(weeksAgo: 4, statuses: [.completed, .completed])
        #expect(earned(snapshot(planned: light))["training.perfectweek"] == nil)
        // This week isn't over yet — no award for a week still in flight.
        let current = week(weeksAgo: 0, statuses: [.completed, .completed, .completed])
        #expect(earned(snapshot(planned: current))["training.perfectweek"] == nil)
    }

    @Test func raceDayComesFromACompletedPlannedRace() {
        let w = UUID()
        let race = AwardsEngine.PlannedFact(date: date(daysAgo: 10), status: .completed,
                                            isRace: true, workoutID: w)
        let open = AwardsEngine.PlannedFact(date: date(daysAgo: 3), status: .planned,
                                            isRace: true, workoutID: nil)
        let e = earned(snapshot(planned: [race, open]))
        #expect(e["training.race"]?.workoutID == w)
    }

    @Test func theReturnNeedsFourteenDaysAway() {
        let back = run(1, km: 5)
        let e = earned(snapshot(activities: [run(20, km: 5), back]))
        #expect(e["training.return"]?.workoutID == back.id)
        #expect(earned(snapshot(activities: [run(10, km: 5), run(1, km: 5)]))["training.return"] == nil)
        // A first-ever workout is a beginning, not a return.
        #expect(earned(snapshot(activities: [run(1, km: 5)]))["training.return"] == nil)
    }

    // MARK: Strength

    @Test func strengthCountsAndTonnageAccumulate() {
        let lifts = (0..<10).map { lift(30 - $0, volumeKg: 12_000) }
        let e = earned(snapshot(activities: lifts))
        #expect(e["strength.first"]?.workoutID == lifts[0].id)
        #expect(e["strength.10"]?.workoutID == lifts[9].id)
        #expect(e["strength.50"] == nil)
        // 120,000 kg total crosses 100 t on the ninth session (108k).
        #expect(e["volume.100t"]?.workoutID == lifts[8].id)
        #expect(e["volume.500t"] == nil)
    }

    // MARK: New collections (2026-07-22 expansion)

    @Test func bigWeekEarnedMidWeekByTheCrossingRun() {
        // Three runs anchored inside one calendar week: 10 + 10 + 8 crosses 25 km on the third.
        let start = calendar.dateInterval(of: .weekOfYear,
                                          for: calendar.date(byAdding: .day, value: -28, to: now)!)!.start
        func runOn(day: Int, km: Double) -> AwardsEngine.Activity {
            AwardsEngine.Activity(id: UUID(),
                                  date: calendar.date(byAdding: .day, value: day, to: start)!
                                      .addingTimeInterval(9 * 3600),
                                  type: .run, distanceM: km * 1000, elevationGainM: 0,
                                  durationS: km * 360, volumeKg: 0, startHour: 9)
        }
        let runs = [runOn(day: 0, km: 10), runOn(day: 2, km: 10), runOn(day: 4, km: 8)]
        let e = earned(snapshot(activities: runs))
        #expect(e["week.25"]?.workoutID == runs[2].id)
        #expect(e["week.40"] == nil)
        // Two 15 km runs in DIFFERENT weeks never make a 25 km week.
        let split = [runOn(day: 0, km: 15), runOn(day: 9, km: 15)]
        #expect(earned(snapshot(activities: split))["week.25"] == nil)
    }

    @Test func rideLadderExcludesEBikes() {
        let ride = run(5, km: 110, type: .gravelRide)
        let e = earned(snapshot(activities: [ride]))
        #expect(e["ride.100"]?.workoutID == ride.id)
        #expect(e["ride.century"]?.workoutID == ride.id)
        let ebike = run(5, km: 110, type: .eBikeRide)
        let e2 = earned(snapshot(activities: [ebike]))
        #expect(e2["ride.100"] == nil)
        #expect(e2["ride.century"] == nil)
    }

    @Test func timeOnFeetCountsAnySport() {
        let hike = AwardsEngine.Activity(id: UUID(), date: date(daysAgo: 3), type: .hike,
                                         distanceM: 12_000, elevationGainM: 300,
                                         durationS: 7_500, volumeKg: 0, startHour: 9)
        let e = earned(snapshot(activities: [hike]))
        #expect(e["endurance.1h"]?.workoutID == hike.id)
        #expect(e["endurance.2h"]?.workoutID == hike.id)
        #expect(e["endurance.3h"] == nil)
    }

    @Test func singleClimbSpecials() {
        let e = earned(snapshot(activities: [run(3, km: 20, climb: 700, type: .trailRun)]))
        #expect(e["climb.single500"] != nil)
        #expect(e["climb.single1000"] == nil)
    }

    @Test func raceLadderAndRacePR() {
        func race(daysAgo: Int, km: Double, durationS: Double) -> AwardsEngine.PlannedFact {
            AwardsEngine.PlannedFact(date: date(daysAgo: daysAgo), status: .completed, isRace: true,
                                     workoutID: UUID(), raceDistanceM: km * 1000, raceDurationS: durationS)
        }
        // Two 5Ks, the second faster → Race PR at the second; ladder counts 3 races total.
        let races = [race(daysAgo: 100, km: 5, durationS: 1_700),
                     race(daysAgo: 50, km: 5, durationS: 1_620),
                     race(daysAgo: 10, km: 10, durationS: 3_500)]
        let e = earned(snapshot(planned: races))
        #expect(e["training.race"]?.workoutID == races[0].workoutID)
        #expect(e["training.race3"]?.workoutID == races[2].workoutID)
        #expect(e["training.race10"] == nil)
        #expect(e["training.racepr"]?.workoutID == races[1].workoutID)
        // A slower repeat and a different-distance race are not PRs.
        let noPR = [race(daysAgo: 100, km: 5, durationS: 1_600),
                    race(daysAgo: 50, km: 5, durationS: 1_700),
                    race(daysAgo: 10, km: 10, durationS: 3_500)]
        #expect(earned(snapshot(planned: noPR))["training.racepr"] == nil)
    }

    @Test func setLadderAndFullCoverage() {
        func liftWeek(daysAgo: Int, sets: Int, buckets: Set<AwardsEngine.MuscleBucket>) -> AwardsEngine.Activity {
            AwardsEngine.Activity(id: UUID(), date: date(daysAgo: daysAgo), type: .strength,
                                  distanceM: 0, elevationGainM: 0, durationS: 3000,
                                  volumeKg: 5000, startHour: 9,
                                  workingSets: sets, muscleBuckets: buckets)
        }
        // Coverage needs all six buckets inside ONE calendar week — anchor both sessions to it.
        let start = calendar.dateInterval(of: .weekOfYear,
                                          for: calendar.date(byAdding: .day, value: -28, to: now)!)!.start
        let upper = AwardsEngine.Activity(id: UUID(), date: start.addingTimeInterval(9 * 3600),
                                          type: .strength, distanceM: 0, elevationGainM: 0,
                                          durationS: 3000, volumeKg: 5000, startHour: 9,
                                          workingSets: 500, muscleBuckets: [.chest, .back, .shoulders, .arms])
        let lower = AwardsEngine.Activity(id: UUID(), date: start.addingTimeInterval(2 * 86_400 + 9 * 3600),
                                          type: .strength, distanceM: 0, elevationGainM: 0,
                                          durationS: 3000, volumeKg: 5000, startHour: 9,
                                          workingSets: 600, muscleBuckets: [.legs, .core])
        let e = earned(snapshot(activities: [upper, lower]))
        #expect(e["strength.coverage"]?.workoutID == lower.id)
        #expect(e["strength.sets1000"]?.workoutID == lower.id)   // 500 + 600 crosses 1,000
        #expect(e["strength.sets10000"] == nil)
        // Same buckets spread over two different weeks → no coverage.
        let spread = [liftWeek(daysAgo: 40, sets: 10, buckets: [.chest, .back, .shoulders, .arms]),
                      liftWeek(daysAgo: 20, sets: 10, buckets: [.legs, .core])]
        #expect(earned(snapshot(activities: spread))["strength.coverage"] == nil)
    }

    @Test func sessionLadderUsesQualifyingFloors() {
        // Nine real runs + one 200 m blip: the blip must not seal "Ten Deep".
        var acts = (1...9).map { run(40 - $0, km: 5) }
        acts.append(run(20, km: 0.2))
        #expect(earned(snapshot(activities: acts))["sessions.10"] == nil)
        acts.append(run(2, km: 5))
        let e = earned(snapshot(activities: acts))
        #expect(e["sessions.10"]?.workoutID == acts.last?.id)
    }

    @Test func halfMarathonBenchmarkFromNewRecordType() {
        let w = UUID()
        let e = earned(snapshot(records: [AwardsEngine.RecordFact(type: .fastestHalf, value: 7_000,
                                                                  achievedAt: date(daysAgo: 8), workoutID: w)]))
        #expect(e["speed.half.sub2"]?.workoutID == w)
        #expect(e["speed.half.sub145"] == nil)
        #expect(e["speed.mara.sub4"] == nil)
    }

    @Test func fourSeasonsNeedsOneCalendarYear() {
        func runAt(month: Int, year: Int) -> AwardsEngine.Activity {
            var comps = DateComponents()
            comps.year = year; comps.month = month; comps.day = 15; comps.hour = 9
            return AwardsEngine.Activity(id: UUID(), date: calendar.date(from: comps)!, type: .run,
                                         distanceM: 5_000, elevationGainM: 0, durationS: 1_800,
                                         volumeKg: 0, startHour: 9)
        }
        let fullYear = [runAt(month: 2, year: 2025), runAt(month: 5, year: 2025),
                        runAt(month: 8, year: 2025), runAt(month: 11, year: 2025)]
        let e = earned(snapshot(activities: fullYear))
        #expect(e["moments.seasons"]?.workoutID == fullYear[3].id)
        // The same four quarters straddling two years never complete a set.
        let straddle = [runAt(month: 8, year: 2024), runAt(month: 11, year: 2024),
                        runAt(month: 2, year: 2025), runAt(month: 5, year: 2025)]
        #expect(earned(snapshot(activities: straddle))["moments.seasons"] == nil)
    }

    @Test func wandererClustersByDistance() {
        // ~0.5° longitude ≈ 45 km apart at 40°N; five spread points earn, clustered repeats don't.
        func runAtLon(_ lon: Double, daysAgo: Int) -> AwardsEngine.Activity {
            AwardsEngine.Activity(id: UUID(), date: date(daysAgo: daysAgo), type: .run,
                                  distanceM: 5_000, elevationGainM: 0, durationS: 1_800,
                                  volumeKg: 0, startHour: 9, startLat: 40.0, startLon: lon)
        }
        let spread = (0..<5).map { runAtLon(Double($0) * 0.5, daysAgo: 50 - $0 * 5) }
        let e = earned(snapshot(activities: spread))
        #expect(e["moments.wanderer"]?.workoutID == spread[4].id)
        // Five runs from the same neighborhood: one place, no award.
        let home = (0..<5).map { runAtLon(0.001 * Double($0), daysAgo: 50 - $0 * 5) }
        #expect(earned(snapshot(activities: home))["moments.wanderer"] == nil)
    }

    // MARK: Progress

    @Test func distanceProgressReadsTheRunningTotal() {
        let s = snapshot(activities: [run(5, km: 30)])
        let p = AwardsEngine.progress(toward: AwardsCatalog.award("distance.50")!, in: s,
                                      calendar: calendar)!
        #expect(abs(p.fraction - 0.6) < 0.001)
        #expect(p.current == 30_000)
        #expect(p.target == 50_000)
    }

    @Test func speedProgressImprovesDownward() {
        let s = snapshot(records: [AwardsEngine.RecordFact(type: .fastest5k, value: 1560,
                                                           achievedAt: date(daysAgo: 4), workoutID: nil)])
        let p = AwardsEngine.progress(toward: AwardsCatalog.award("speed.5k.sub25")!, in: s,
                                      calendar: calendar)!
        #expect(abs(p.fraction - 1500.0 / 1560.0) < 0.001)
        // No time yet → zero, not a crash.
        let empty = AwardsEngine.progress(toward: AwardsCatalog.award("speed.5k.sub25")!,
                                          in: snapshot(), calendar: calendar)!
        #expect(empty.fraction == 0)
    }

    @Test func progressClampsAtOne() {
        let s = snapshot(activities: [run(5, km: 80)])
        let p = AwardsEngine.progress(toward: AwardsCatalog.award("distance.50")!, in: s,
                                      calendar: calendar)!
        #expect(p.fraction == 1)
    }

    // MARK: Determinism

    @Test func evaluateIsDeterministic() {
        let acts = [run(10, km: 22, climb: 900), run(5, km: 6, hour: 5), lift(3, volumeKg: 8000)]
        let s = snapshot(activities: acts.shuffled(),
                         records: [AwardsEngine.RecordFact(type: .fastest5k, value: 1700,
                                                           achievedAt: date(daysAgo: 5), workoutID: nil)])
        let a = AwardsEngine.evaluate(s, calendar: calendar)
        let b = AwardsEngine.evaluate(s, calendar: calendar)
        #expect(a == b)
        // Shuffled input order changes nothing — the engine sorts internally.
        let s2 = snapshot(activities: acts.reversed(),
                          records: s.records)
        #expect(Set(AwardsEngine.evaluate(s2, calendar: calendar).map(\.awardID))
                == Set(a.map(\.awardID)))
    }
}
