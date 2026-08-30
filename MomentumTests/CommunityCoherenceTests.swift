import Testing
import Foundation
@testable import Momentum

/// Coherence tripwires for the seeded community's PROFILES.
///
/// Owner report 2026-08-28: "if they have thirty miles tracked from their grid where you can see
/// all their runs, then that should match their miles on their profile page at thirty miles
/// logged, but on their profile it says one thousand one hundred eighty one miles." The cause was
/// structural — the grid was ~15 generated history posts while `totalWorkouts`, `totalDistanceM`
/// and `dayStreak` were three *independent* draws, so no amount of tuning could make them agree.
///
/// `CommunityLedger` replaced that with one deterministic session ledger per athlete: the grid
/// materializes its entries, and every lifetime number is a fold over it. These tests are the
/// tripwire on that property. They sample hundreds of athletes across the directory (plus all
/// eight hand-curated featured members, which used to be the worst offenders — Maya claimed 4,120
/// km and a 21-day streak nothing behind her profile could account for) and assert that every
/// number a user can see agrees with every other number and with the sessions actually visible.
@MainActor
struct CommunityCoherenceTests {

    // MARK: Sampling

    /// The eight featured athletes plus ~315 generated ones spread across the whole directory.
    private func sample() -> [CommunityAthlete] {
        let all = CommunityDirectory.all()
        return Array(all.prefix(8)) + stride(from: 8, to: all.count, by: 9).map { all[$0] }
    }

    /// A smaller slice for the tests that materialize whole grids (a full grid is one feed card
    /// per session, so 300 veterans' worth of them is not what we want in a unit test).
    private func gridSample() -> [CommunityAthlete] {
        let all = CommunityDirectory.all()
        return Array(all.prefix(8)) + stride(from: 40, to: all.count, by: 137).map { all[$0] }
    }

    private var clock: CommunityLedger.Clock { CommunityDirectory.seedClock }

    private func ledger(_ a: CommunityAthlete) -> [CommunitySession] {
        CommunityLedger.sessions(handle: a.handle, primary: a.primaryType,
                                 city: a.routeCity,
                                 count: a.totalWorkouts, clock: clock, lead: a.ledgerLead)
    }

    /// "5.7 mi · 44:31" → 5.7. nil when the tile prints no distance.
    private func miles(_ statLine: String) -> Double? {
        let parts = statLine.split(separator: " ")
        guard parts.count >= 2, parts[1] == "mi" else { return nil }
        return Double(parts[0])
    }

    // MARK: The headline invariant

    @Test func everyLifetimeNumberIsAFoldOverTheSameSessions() {
        for a in sample() {
            let sessions = ledger(a)
            // The session count IS the ledger's length — the trio's "Workouts" is the number of
            // tiles the grid can show, not a number drawn beside it.
            #expect(sessions.count == a.totalWorkouts,
                    "@\(a.handle): ledger has \(sessions.count) sessions, profile says \(a.totalWorkouts)")

            // Lifetime distance is the exact sum. Not "about", not "within 10%".
            let summed = sessions.reduce(0) { $0 + $1.distanceM }
            #expect(abs(summed - a.totalDistanceM) < 1,
                    "@\(a.handle): sessions sum to \(Int(summed))m, profile claims \(Int(a.totalDistanceM))m")

            // And the profile's own derivation agrees with a fresh walk.
            let life = CommunityDirectory.lifetime(for: a)
            #expect(life.sessions == a.totalWorkouts)
            #expect(abs(life.distanceM - summed) < 1)
            #expect(life.streakDays == a.dayStreak)
            #expect(abs(life.durationS - sessions.reduce(0) { $0 + $1.durationS }) < 1)
        }
    }

    @Test func theStreakIsTheLedgersOwnRunOfDays() {
        let today = clock.today
        for a in sample() {
            let days = Set(ledger(a).map(\.day))
            #expect(StreakCalculator.currentStreak(countingDays: days, today: today) == a.dayStreak,
                    "@\(a.handle): profile shows a \(a.dayStreak) day streak the ledger can't produce")
            // A live streak can never sit above a grid whose newest tile is stale. The app's own
            // rule forgives ONE day, so the newest session is at most two days back.
            if a.dayStreak > 0, let newest = days.max() {
                #expect(today - newest <= 2,
                        "@\(a.handle): \(a.dayStreak) day streak but last trained \(today - newest) days ago")
            }
        }
    }

    @Test func theDisciplineSplitCountsTheSessionsThemselves() {
        for a in sample() {
            var counts: [WorkoutType: Int] = [:]
            for s in ledger(a) { counts[s.type, default: 0] += 1 }
            #expect(a.disciplineCounts == counts,
                    "@\(a.handle): the split doesn't match the sports in their grid")
            // The split must account for every session — it used to be a share-out over
            // `totalWorkouts` that could name sports the grid never showed.
            #expect(counts.values.reduce(0, +) == a.totalWorkouts)
            // Their own sport leads.
            #expect(counts[a.primaryType, default: 0] >= 1)
        }
    }

    @Test func theHeatmapOnlyLightsDaysThatHaveSessions() {
        for a in sample() {
            let days = Set(ledger(a).map(\.day))
            let life = CommunityDirectory.lifetime(for: a)
            #expect(life.activeDays.isSubset(of: days),
                    "@\(a.handle): the consistency grid lights days with no session on them")
            #expect(Set(life.dayMinutes.keys).isSubset(of: days))
            // And the minutes on a square are that day's real training time.
            for (day, minutes) in life.dayMinutes {
                let real = ledger(a).filter { $0.day == day }.reduce(0) { $0 + $1.durationS } / 60
                #expect(abs(minutes - real) < 0.01)
            }
        }
    }

    // MARK: Honest sessions

    @Test func noSessionIsDatedInTheFuture() {
        for a in sample() {
            for s in ledger(a) {
                #expect(s.date <= clock.asOf,
                        "@\(a.handle): a session is dated \(s.date), later than the community's clock")
            }
        }
    }

    @Test func onlyDistanceSportsCarryDistance() {
        for a in sample() {
            for s in ledger(a) {
                if s.type.isGPS {
                    #expect(s.distanceM > 100,
                            "@\(a.handle): a \(s.type.rawValue) session covers no ground")
                } else {
                    // A lifter's or yogi's lifetime distance is zero because none of their
                    // sessions cover ground — that is why "4,200 km covered" can't come back.
                    #expect(s.distanceM == 0,
                            "@\(a.handle): a \(s.type.rawValue) session carries \(Int(s.distanceM))m of distance")
                }
                #expect(s.durationS > 0)
            }
        }
    }

    @Test func everySessionIsPlausiblyLong() {
        for a in sample() {
            for s in ledger(a) where s.type.isGPS {
                let km = s.distanceM / 1000
                // A century ride is real; anything past that is a generator running away.
                #expect(km <= 130, "@\(a.handle): a \(km) km \(s.type.rawValue)")
                let paceSPerKm = s.durationS / km
                // 2:00/km would be a world record; 25:00/km is slower than a stroll.
                #expect(paceSPerKm > 100 && paceSPerKm < 1_500,
                        "@\(a.handle): \(Int(paceSPerKm))s/km on a \(s.type.rawValue)")
            }
        }
    }

    // MARK: A training life, not a uniform generator

    @Test func historyDepthMatchesTheBodyOfWork() {
        let today = clock.today
        for a in sample() {
            let days = ledger(a).map(\.day)
            guard let oldest = days.min() else { continue }
            let span = today - oldest
            // Nobody logs more than two sessions a day, so a career can't be shorter than half
            // its session count...
            #expect(span >= (a.totalWorkouts - 1) / 2,
                    "@\(a.handle): \(a.totalWorkouts) sessions crammed into \(span) days")
            // ...and at the ledger's floor rate (~0.16 sessions/day, with down weeks and breaks)
            // it can't be longer than this either. A beginner with eight sessions gets a
            // three-week history, never a five-year heatmap.
            #expect(span <= a.totalWorkouts * 10 + 90,
                    "@\(a.handle): \(a.totalWorkouts) sessions spread over \(span) days")
        }
    }

    @Test func beginnersHistoriesAreShallow() {
        let today = clock.today
        let beginners = CommunityDirectory.all().filter { $0.isSample && $0.totalWorkouts <= 15 }
        #expect(beginners.count > 20, "a 'from your first 5K' community should have beginners")
        for a in beginners.prefix(60) {
            guard let oldest = ledger(a).map(\.day).min() else { continue }
            #expect(today - oldest < 260,
                    "@\(a.handle) has \(a.totalWorkouts) sessions but a \(today - oldest) day history")
        }
    }

    @Test func trainingClustersInAWeeklyRhythm() {
        // A real training life has rest days. A generator that just scatters sessions gives every
        // athlete a near-uniform week; the ledger's rest day and weekend long day should make at
        // least one weekday clearly quieter than the busiest across a big athlete.
        let veterans = CommunityDirectory.all().filter { $0.isSample && $0.totalWorkouts > 260 }
        #expect(!veterans.isEmpty)
        var withRhythm = 0
        for a in veterans.prefix(40) {
            var perDow = [Int](repeating: 0, count: 7)
            for s in ledger(a) { perDow[((s.day % 7) + 7) % 7] += 1 }
            if let lo = perDow.min(), let hi = perDow.max(), Double(lo) < Double(hi) * 0.72 { withRhythm += 1 }
        }
        #expect(withRhythm >= 30, "only \(withRhythm)/40 veterans train on a weekly rhythm")
    }

    // MARK: The grid the user actually looks at

    @Test func theGridIsExactlyTheLedger() {
        for a in gridSample() {
            let sessions = ledger(a)
            let posts = CommunityDirectory.gridPosts(for: a, limit: .max)
            #expect(posts.count == a.totalWorkouts,
                    "@\(a.handle): \(posts.count) tiles for \(a.totalWorkouts) workouts")
            #expect(Set(posts.map(\.id)).count == posts.count, "@\(a.handle): duplicate tile ids")
            for (post, session) in zip(posts, sessions) {
                #expect(post.type == session.type)
                #expect(abs(post.date.timeIntervalSince(session.date)) < 1)
            }
        }
    }

    /// The owner's sentence, as a test: add up the miles on the tiles, and you get the number on
    /// the profile.
    @Test func theGridsMilesAddUpToTheProfilesMiles() {
        for a in gridSample() {
            let posts = CommunityDirectory.gridPosts(for: a, limit: .max)
            let tileMiles = posts.compactMap { miles($0.statLine) }.reduce(0, +)
            let profileMiles = a.totalDistanceM / 1000 * 0.621371
            // Each tile prints one decimal, so it can be up to 0.05 mi off its own session.
            let tolerance = 0.05 * Double(posts.count) + 0.5
            #expect(abs(tileMiles - profileMiles) < tolerance,
                    "@\(a.handle): tiles show \(Int(tileMiles)) mi, profile says \(Int(profileMiles)) mi")
        }
    }

    @Test func everyTilePrintsItsOwnSessionsNumbers() {
        for a in gridSample() {
            let sessions = ledger(a)
            let posts = CommunityDirectory.gridPosts(for: a, limit: .max)
            for (post, session) in zip(posts, sessions) {
                guard let mi = miles(post.statLine) else {
                    #expect(session.distanceM == 0 || !session.type.isGPS,
                            "@\(a.handle): '\(post.title)' hides a \(Int(session.distanceM))m session")
                    continue
                }
                #expect(abs(mi - session.distanceM / 1000 * 0.621371) < 0.06,
                        "@\(a.handle): tile says \(mi) mi for a \(Int(session.distanceM))m session")
            }
        }
    }

    @Test func theGridPagesInsteadOfBuildingWholeCareers() {
        guard let veteran = CommunityDirectory.all().first(where: { $0.isSample && $0.totalWorkouts > 200 })
        else { return }
        let first = CommunityDirectory.gridPosts(for: veteran, limit: CommunityDirectory.gridPageSize)
        #expect(first.count == CommunityDirectory.gridPageSize)
        let second = CommunityDirectory.gridPosts(for: veteran, limit: CommunityDirectory.gridPageSize * 2)
        #expect(second.count == CommunityDirectory.gridPageSize * 2)
        // Paging must be additive, never a re-roll: the tiles you already scrolled past keep their
        // content and their identity.
        #expect(Array(second.prefix(first.count)).map(\.id) == first.map(\.id))
        #expect(Array(second.prefix(first.count)).map(\.statLine) == first.map(\.statLine))
        // And it stops at the real end of their career.
        let all = CommunityDirectory.gridPosts(for: veteran, limit: veteran.totalWorkouts + 500)
        #expect(all.count == veteran.totalWorkouts)
    }

    // MARK: The featured eight held to the same bar

    @Test func theFeaturedEightSatisfyTheSameInvariants() {
        let featured = Array(CommunityDirectory.all().prefix(8))
        #expect(featured.count == 8)
        for a in featured {
            let sessions = ledger(a)
            #expect(sessions.count == a.totalWorkouts)
            #expect(abs(sessions.reduce(0) { $0 + $1.distanceM } - a.totalDistanceM) < 1,
                    "featured @\(a.handle) still claims a hand-written distance")
            // Their written post IS their newest session, so the top of their grid is the card the
            // wall shows them by.
            let post = a.posts.first
            #expect(post != nil)
            #expect(abs((sessions.first?.date ?? .distantPast).timeIntervalSince(post!.date)) < 1,
                    "featured @\(a.handle)'s post isn't their newest session")
            #expect(sessions.first?.type == post!.type)
            // A distance athlete's lifetime distance can't be zero, and a lifter's can't be
            // anything else than the ground their cross-training actually covered.
            if a.primaryType.isGPS { #expect(a.totalDistanceM > 0) }
        }
    }

    @Test func theWallsCardIsATileOnTheAuthorsOwnGrid() {
        // Every card on the community wall is a real ledger entry of its author's, so tapping
        // through to their profile finds the same workout instead of a thirteenth one that only
        // exists on the wall.
        for a in gridSample() where a.isSample {
            guard let card = a.posts.first else { continue }
            let posts = CommunityDirectory.gridPosts(for: a, limit: .max)
            #expect(posts.contains { $0.id == card.id },
                    "@\(a.handle)'s feed card isn't on their own grid")
        }
    }
}
