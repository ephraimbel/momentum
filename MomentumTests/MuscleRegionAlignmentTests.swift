import Testing
import Foundation
@testable import Momentum

/// The wheel ↔ body contract (owner call 2026-08-29: "the muscle map and the human body have to be
/// aligned — a part that gets stronger has to go a stronger purple, correlated perfectly").
///
/// Three things have to hold, and each is pinned here:
/// 1. **One region model.** Every muscle belongs to exactly one wheel region, and every region is
///    actually drawn on the anatomy — for both figures. A muscle that no path renders would be a
///    region the wheel can light and the body silently can't.
/// 2. **One number.** `bodyShares` hands the figure the wheel's own share-of-the-leader.
/// 3. **One lighting law.** `MuscleLight` turns that number into colour for the rings and the
///    muscles alike: lavender deepens with the work, and only the top of the scale burns.
@Suite("Muscle map ↔ wheel alignment")
struct MuscleRegionAlignmentTests {
    typealias R = StrengthTrends.BodyRegion

    // MARK: One region model

    @Test func everyMuscleBelongsToExactlyOneRegion() {
        let trainable = MuscleGroup.allCases.filter { $0 != .fullBody }
        for muscle in trainable {
            let owners = R.allCases.filter { $0.muscles.contains(muscle) }
            #expect(owners.count == 1, "\(muscle.rawValue) belongs to \(owners.count) regions")
            #expect(owners.first == R.of(muscle))     // `muscles` is the exact inverse of `of(_:)`
        }
        #expect(R.allCases.flatMap(\.muscles).count == trainable.count)
        #expect(R.allCases.allSatisfy { !$0.muscles.isEmpty })
        #expect(!R.allCases.flatMap(\.muscles).contains(.fullBody))
    }

    /// The alignment that actually shows on screen: every region the wheel can light has anatomy
    /// to light. Checked on the male AND female datasets, front + back together.
    @Test func everyRegionIsDrawnOnBothFigures() {
        let male = drawnMuscles(BodyAnatomy.front + BodyAnatomy.back)
        let female = drawnMuscles(BodyAnatomy.femaleFront + BodyAnatomy.femaleBack)
        for region in R.allCases {
            #expect(region.muscles.contains { male.contains($0) }, "\(region.rawValue) has no male anatomy")
            #expect(region.muscles.contains { female.contains($0) }, "\(region.rawValue) has no female anatomy")
        }
        // And no trainable muscle is unrenderable — the wheel's numbers all have somewhere to go.
        for muscle in MuscleGroup.allCases where muscle != .fullBody {
            #expect(male.contains(muscle), "\(muscle.rawValue) is not drawn on the male figure")
            #expect(female.contains(muscle), "\(muscle.rawValue) is not drawn on the female figure")
        }
    }

    private func drawnMuscles(_ parts: [BodyAnatomy.Part]) -> Set<MuscleGroup> {
        Set(parts.compactMap(\.muscle))
    }

    // MARK: One number

    @Test func bodySharesCarryTheWheelsShareOfTheLeader() {
        let loads = [
            StrengthTrends.RegionLoad(region: .chest, volumeKg: 1000, sets: 10),
            StrengthTrends.RegionLoad(region: .legs, volumeKg: 500, sets: 5),
            StrengthTrends.RegionLoad(region: .arms, volumeKg: 0, sets: 0),
        ]
        let shares = StrengthTrends.bodyShares(loads) { $0.volumeKg }
        #expect(shares[.chest] == 1.0)                            // the leader is the full burn
        for muscle in R.legs.muscles { #expect(shares[muscle] == 0.5) }   // half the load, half lit
        for muscle in R.arms.muscles { #expect(shares[muscle] == nil) }   // untrained stays unlit
        // Every muscle of a region carries that region's number — the wheel's granularity, exactly.
        #expect(R.chest.muscles.allSatisfy { shares[$0] == 1.0 })
        #expect(StrengthTrends.bodyShares([], value: { $0.volumeKg }).isEmpty)
        #expect(StrengthTrends.bodyShares(loads) { _ in 0 }.isEmpty)      // nothing trained, blank body
    }

    /// The end-to-end promise: rank the regions by load, and the body's muscles come out in the
    /// same order at the same strength. This is the "correlated perfectly" check.
    @Test func theFigureRanksMusclesExactlyLikeTheWheel() {
        let loads = [
            StrengthTrends.RegionLoad(region: .legs, volumeKg: 4000, sets: 20),
            StrengthTrends.RegionLoad(region: .back, volumeKg: 3000, sets: 15),
            StrengthTrends.RegionLoad(region: .chest, volumeKg: 1000, sets: 5),
            StrengthTrends.RegionLoad(region: .core, volumeKg: 200, sets: 4),
        ]
        let shares = StrengthTrends.bodyShares(loads) { $0.volumeKg }
        func strength(_ region: R) -> Double {
            MuscleMapGrading.regionShare.intensity(shares[region.muscles[0]] ?? 0, maxVal: 1)
        }
        // A wheel ring, a by-region bar and a muscle all ask `MuscleLight.lavender` for the same
        // share, so the same region comes out at the same alpha on all three. One number, one
        // colour — the ORDER and the SPACING are identical because the function is.
        #expect(strength(.legs) == 1.0)
        #expect(strength(.back) == 0.75)
        #expect(strength(.chest) == 0.25)
        #expect(MuscleLight.lavender(strength(.legs)) > MuscleLight.lavender(strength(.back)))
        #expect(MuscleLight.lavender(strength(.back)) > MuscleLight.lavender(strength(.chest)))
        #expect(MuscleLight.lavender(strength(.chest)) > MuscleLight.lavender(strength(.core)))
    }

    // MARK: One lighting law

    @Test func lavenderDeepensWithTheWork() {
        var last = -1.0
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            let alpha = MuscleLight.lavender(t)
            #expect(alpha > last)
            last = alpha
        }
        #expect(MuscleLight.lavender(1) == 1.0)                  // fully trained is saturated
        #expect(MuscleLight.lavender(0) == MuscleLight.floor)    // the faintest lit tissue still reads
        #expect(MuscleLight.lavender(2) == 1.0)                  // clamps
        #expect(MuscleLight.lavender(-1) == MuscleLight.floor)
        // Linear the whole way, so twice the load really is twice the colour above the floor.
        let span = 1.0 - MuscleLight.floor
        #expect(abs((MuscleLight.lavender(0.5) - MuscleLight.floor) - span / 2) < 1e-9)
        #expect(abs((MuscleLight.lavender(0.25) - MuscleLight.floor) - span / 4) < 1e-9)
    }

    /// Over a training window, a muscle worked more must read visibly stronger than one worked
    /// less — the whole point of the figure. `.weeklyVolume` is the Athlete Panel's absolute scale.
    @Test func moreTrainingIsMorePurple() {
        func purple(setsPerWeek: Double) -> Double {
            MuscleLight.lavender(MuscleMapGrading.weeklyVolume.intensity(setsPerWeek, maxVal: 10))
        }
        let untrained = MuscleMapGrading.weeklyVolume.intensity(0, maxVal: 10)
        #expect(untrained == 0)                                   // never lit, never tinted
        #expect(purple(setsPerWeek: 8) > purple(setsPerWeek: 4))
        #expect(purple(setsPerWeek: 4) > purple(setsPerWeek: 1))
        #expect(purple(setsPerWeek: 10) == 1.0)                   // the hypertrophy bar = full colour
        // And the gap is VISIBLE, not a rounding difference: half the volume is a clearly
        // lighter muscle (the complaint that started this — everything looked the same).
        #expect(purple(setsPerWeek: 10) - purple(setsPerWeek: 5) > 0.25)
    }

    @Test func onlyTheTopOfTheScaleEarnsTheBurn() {
        #expect(MuscleLight.burn(1.0) == 1.0)
        #expect(MuscleLight.burn(0.9) == 0)
        #expect(MuscleLight.burn(0.5) == 0)
        #expect(MuscleLight.burn(0) == 0)
        // The leading region burns; the runner-up, however close, is lavender only.
        let loads = [
            StrengthTrends.RegionLoad(region: .legs, volumeKg: 1000, sets: 10),
            StrengthTrends.RegionLoad(region: .back, volumeKg: 950, sets: 9),
        ]
        let shares = StrengthTrends.bodyShares(loads) { $0.volumeKg }
        func burn(_ region: R) -> Double {
            MuscleLight.burn(MuscleMapGrading.regionShare.intensity(shares[region.muscles[0]] ?? 0, maxVal: 1))
        }
        #expect(burn(.legs) == 1.0)
        #expect(burn(.back) == 0)
    }

    /// The post-session body is untouched by all of this — what you just worked still lights up as
    /// the full oil-slick, no lavender ramp. (Owner: don't dim the celebration.)
    @Test func theSessionLookKeepsItsOilSlick() {
        #expect(MuscleMapGrading.session.tone == .burn)
        #expect(MuscleMapGrading.weeklyVolume.tone == .growth)
        #expect(MuscleMapGrading.regionShare.tone == .growth)
    }

    @Test func regionShareGradingPassesTheShareThrough() {
        let g = MuscleMapGrading.regionShare
        #expect(g.intensity(0.4, maxVal: 1) == 0.4)
        #expect(g.intensity(1, maxVal: 1) == 1.0)
        #expect(g.intensity(3, maxVal: 1) == 1.0)     // clamps rather than blowing past full
        #expect(g.intensity(0, maxVal: 1) == 0)
    }
}

/// The Trends page shows the same athlete twice — the body at the top of the page, the muscle-load
/// wheel down in the strength chapter. They answer different questions on purpose (the body is the
/// absolute portrait of everything you train, the wheel is where your LIFTING load sat relative to
/// its own leader), but they must never contradict each other about the lifting: the region the
/// wheel says you loaded most has to be the region the body lights most.
///
/// This suite is the tripwire on that. It works in set-equivalents, the currency both surfaces
/// credit the same way (working sets only, primary 1.0 / secondary 0.5).
@MainActor
struct AthletePanelWheelAgreementTests {
    typealias R = StrengthTrends.BodyRegion
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func lift(daysAgo: Int, primary: [MuscleGroup], secondary: [MuscleGroup] = [],
                      working: Int) -> Workout {
        let exercise = Exercise(name: "Lift", primaryMuscles: primary, secondaryMuscles: secondary,
                                equipment: .barbell, category: .compound)
        let sets = (0..<working).map { _ -> SetEntry in
            let s = SetEntry(); s.reps = 5; s.weightKg = 60; s.isComplete = true; s.type = .working
            return s
        }
        let row = WorkoutExercise(); row.exercise = exercise; row.sets = sets
        let session = StrengthSession(); session.exercises = [row]
        let w = Workout(); w.type = .strength; w.strength = session
        w.startedAt = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        return w
    }

    private func run(daysAgo: Int, km: Double) -> Workout {
        let gps = GPSDetail(); gps.distanceM = km * 1_000
        let w = Workout(); w.type = .run; w.gps = gps
        w.startedAt = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        return w
    }

    /// The panel's per-muscle sets, rolled up the wheel's way.
    private func panelByRegion(_ workouts: [Workout], days: Int) -> [R: Double] {
        var out: [R: Double] = [:]
        for (muscle, value) in MuscleActivation.weeklyRate(workouts: workouts, days: days, now: now) {
            guard let region = R.of(muscle) else { continue }
            out[region, default: 0] += value
        }
        return out
    }

    /// For lifting, the two surfaces are the SAME arithmetic: roll the body's per-muscle sets up
    /// into regions and you get the wheel's own region sets, to the last decimal.
    @Test func theBodysSetsRollUpIntoExactlyTheWheelsRegionSets() {
        let workouts = [
            lift(daysAgo: 1, primary: [.chest], secondary: [.triceps, .shoulders], working: 4),
            lift(daysAgo: 2, primary: [.back], secondary: [.biceps], working: 5),
            lift(daysAgo: 3, primary: [.quads], secondary: [.glutes, .hamstrings, .core], working: 6),
            lift(daysAgo: 4, primary: [.shoulders], working: 3),
        ]
        // A 7-day window is exactly one week, so the panel's per-week divisor is 1 and the two are
        // directly comparable without rescaling.
        let panel = panelByRegion(workouts, days: 7)
        let wheel = StrengthTrends.regionLoads(in: workouts, days: 7, now: now)

        for load in wheel {
            #expect(abs((panel[load.region] ?? 0) - load.sets) < 1e-9,
                    "\(load.region.rawValue): body \(panel[load.region] ?? 0) vs wheel \(load.sets)")
        }
    }

    /// And therefore they rank the regions identically — what leads the wheel is what burns on the
    /// body. This is the thing an athlete checks by scrolling between the two.
    @Test func theWheelsLeaderIsTheBodysLeader() {
        let workouts = [
            lift(daysAgo: 1, primary: [.back], secondary: [.biceps], working: 8),
            lift(daysAgo: 2, primary: [.chest], secondary: [.triceps], working: 3),
            lift(daysAgo: 3, primary: [.quads], working: 2),
        ]
        let panel = panelByRegion(workouts, days: 7)
        let wheel = StrengthTrends.regionLoads(in: workouts, days: 7, now: now)

        let panelOrder = panel.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map(\.key)
        let wheelOrder = wheel.filter { $0.sets > 0 }.sorted { $0.sets > $1.sets }.map(\.region)
        #expect(panelOrder == wheelOrder, "body ranks \(panelOrder), wheel ranks \(wheelOrder)")
        #expect(panelOrder.first == .back)
    }

    /// Running is the one thing the body knows and the wheel does not — by design, and by the
    /// owner's call. It may only ADD to the legs and core; it can never reorder the upper body
    /// underneath the wheel's ranking, so the two can never contradict each other about lifting.
    @Test func runningOnlyEverAddsToTheLowerBody() {
        let lifts = [
            lift(daysAgo: 1, primary: [.chest], secondary: [.triceps], working: 4),
            lift(daysAgo: 2, primary: [.back], secondary: [.biceps], working: 6),
        ]
        let liftingOnly = panelByRegion(lifts, days: 7)
        let withRunning = panelByRegion(lifts + [run(daysAgo: 3, km: 20)], days: 7)

        for region in [R.chest, .back, .shoulders, .arms] {
            #expect(withRunning[region] == liftingOnly[region],
                    "\(region.rawValue) moved when the athlete ran")
        }
        #expect((withRunning[.legs] ?? 0) > (liftingOnly[.legs] ?? 0))
        #expect((withRunning[.core] ?? 0) > (liftingOnly[.core] ?? 0))
    }

    /// End to end, from logged workouts to the alpha that actually reaches the screen: on the
    /// muscle-load screen the wheel's ring and every muscle of that region come out at the SAME
    /// number, and the ranking by that number is the wheel's own ranking by sets. Not a
    /// hand-built `RegionLoad` this time — real sessions through `regionLoads`, so a change
    /// anywhere in the chain (credit weights, the share, either ramp) trips this.
    @Test func theWheelsRingAndItsMusclesRenderAtTheSameAlpha() {
        let workouts = [
            lift(daysAgo: 1, primary: [.quads], secondary: [.glutes, .hamstrings], working: 6),
            lift(daysAgo: 2, primary: [.back], secondary: [.biceps], working: 5),
            lift(daysAgo: 3, primary: [.chest], secondary: [.triceps, .shoulders], working: 3),
            lift(daysAgo: 4, primary: [.core], working: 2),
        ]
        let loads = StrengthTrends.regionLoads(in: workouts, days: 7, now: now)
        let shares = StrengthTrends.bodyShares(loads) { $0.sets }
        let top = loads.map(\.sets).max() ?? 0
        #expect(top > 0)

        var wheelAlpha: [R: Double] = [:]
        for load in loads where load.sets > 0 {
            // What the ring is stroked at (`MuscleLight.regionStyle`, non-leader branch).
            let ring = MuscleLight.lavender(load.sets / top)
            wheelAlpha[load.region] = ring
            // What every muscle of that region is filled at on the figure under `.regionShare`.
            for muscle in load.region.muscles {
                let muscleAlpha = MuscleLight.lavender(
                    MuscleMapGrading.regionShare.intensity(shares[muscle] ?? 0, maxVal: 1))
                #expect(abs(muscleAlpha - ring) < 1e-12,
                        "\(muscle.rawValue): body \(muscleAlpha) vs \(load.region.rawValue) ring \(ring)")
            }
        }
        // Same order, drawn from the same numbers — the leader of one is the leader of the other.
        let byAlpha = wheelAlpha.sorted { $0.value > $1.value }.map(\.key)
        let bySets = loads.filter { $0.sets > 0 }.sorted { $0.sets > $1.sets }.map(\.region)
        #expect(byAlpha == bySets, "alpha ranks \(byAlpha), sets rank \(bySets)")
        #expect(byAlpha.first == .legs)
        // And only the leader burns, on either surface.
        #expect(MuscleLight.burn(MuscleMapGrading.regionShare.intensity(shares[.quads] ?? 0, maxVal: 1)) == 1)
        #expect(MuscleLight.burn(MuscleMapGrading.regionShare.intensity(shares[.back] ?? 0, maxVal: 1)) == 0)
    }

    /// The owner's actual sentence — "body parts get a stronger purple as they get stronger" —
    /// checked the way an athlete would experience it: log MORE chest work and the chest goes
    /// deeper on the Athlete Panel's figure, while nothing the athlete didn't train gets lighter.
    /// Colour depth is the figure's only channel, so it has to be monotonic in the work.
    @Test func addingWorkNeverRendersAMuscleLighter() {
        func panelAlpha(_ workouts: [Workout]) -> [MuscleGroup: Double] {
            MuscleActivation.weeklyRate(workouts: workouts, days: 7, now: now).mapValues {
                MuscleLight.lavender(MuscleMapGrading.weeklyVolume.intensity($0, maxVal: 10))
            }
        }
        let base = [
            lift(daysAgo: 1, primary: [.chest], secondary: [.triceps], working: 2),
            lift(daysAgo: 2, primary: [.back], secondary: [.biceps], working: 4),
        ]
        var last = panelAlpha(base)
        for extra in 1...6 {
            let more = panelAlpha(base + [lift(daysAgo: 3, primary: [.chest], working: extra)])
            #expect((more[.chest] ?? 0) > (last[.chest] ?? 0),
                    "chest went from \(last[.chest] ?? 0) to \(more[.chest] ?? 0) on MORE work")
            for (muscle, alpha) in last {
                #expect((more[muscle] ?? 0) >= alpha - 1e-12,
                        "\(muscle.rawValue) dimmed when the athlete trained more")
            }
            last = more
        }
        // …until the hypertrophy bar, where it saturates rather than inverting.
        let saturated = panelAlpha(base + [lift(daysAgo: 3, primary: [.chest], working: 40)])
        #expect(saturated[.chest] == 1.0)
    }
}
