import Testing
import Foundation
@testable import Momentum

/// `RunVerdict` is the sentence the athlete reads at the emotional peak of the app, so every branch
/// is pinned — including the ones that deliberately say nothing about pace.
struct RunVerdictTests {

    /// A fixed anchor: the engine is pure and must never consult the wall clock.
    private static let day0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func run(_ daysAgo: Double, km: Double, minutes: Double) -> RunVerdict.Run {
        RunVerdict.Run(date: Self.day0.addingTimeInterval(-daysAgo * 24 * 3600),
                       distanceM: km * 1000, durationS: minutes * 60)
    }

    // MARK: First time out

    @Test func firstEverRunIsWelcomedRatherThanRanked() {
        let today = run(0, km: 5, minutes: 30)
        let line = RunVerdict.verdict(for: today, priors: [], unit: .metric)?.text
        #expect(line == "Your first one on the board. Everything after this has something to measure against.")
    }

    @Test func priorsDatedAfterTheRunAreIgnored() {
        // A caller may hand us its whole history unfiltered; anything later must not count as prior.
        let today = run(0, km: 5, minutes: 30)
        let future = RunVerdict.Run(date: Self.day0.addingTimeInterval(3600), distanceM: 5_000, durationS: 1_500)
        #expect(RunVerdict.verdict(for: today, priors: [future], unit: .metric)?.text.hasPrefix("Your first one") == true)
    }

    // MARK: Ranking among comparable distances

    @Test func fastestAtThisDistanceLeads() {
        let today = run(0, km: 10, minutes: 50)            // 5:00/km
        let priors = [run(7, km: 10, minutes: 55), run(14, km: 10, minutes: 52)]
        #expect(RunVerdict.verdict(for: today, priors: priors, unit: .metric)?.text == "Your fastest at this distance.")
    }

    @Test func secondAndThirdFastestAreNamed() {
        let priors = [run(7, km: 10, minutes: 45), run(14, km: 10, minutes: 55), run(21, km: 10, minutes: 56)]
        let second = run(0, km: 10, minutes: 50)
        #expect(RunVerdict.verdict(for: second, priors: priors, unit: .metric)?.text == "Your 2nd-fastest at this distance.")

        let third = run(0, km: 10, minutes: 55.5)
        #expect(RunVerdict.verdict(for: third, priors: priors, unit: .metric)?.text == "Your 3rd-fastest at this distance.")
    }

    /// A 5K must not be ranked against a 20K — the tolerance is what keeps the claim honest.
    @Test func distantDistancesAreNotComparable() {
        let today = run(0, km: 5, minutes: 30)             // 6:00/km, slow for them
        let priors = [run(7, km: 20, minutes: 100)]        // 5:00/km over four times the distance
        // Not comparable, and not their furthest → falls through to the consistency line.
        #expect(RunVerdict.verdict(for: today, priors: priors, unit: .metric)?.text == "Two this week.")
    }

    @Test func toleranceBoundaryIsInclusive() {
        // 15% either side counts as the same shape; a hair beyond does not.
        let today = run(0, km: 10, minutes: 50)
        let atEdge = run(7, km: 11.5, minutes: 60)         // exactly +15%
        #expect(RunVerdict.verdict(for: today, priors: [atEdge], unit: .metric)?.text == "Your fastest at this distance.")

        let pastEdge = run(7, km: 11.6, minutes: 60)       // beyond the tolerance
        #expect(RunVerdict.verdict(for: today, priors: [pastEdge], unit: .metric)?.text != "Your fastest at this distance.")
    }

    // MARK: Gains outside the podium

    @Test func aClearGainOnTheLastComparableRunIsReported() {
        // Four faster runs push today off the podium, but it still beat the most recent comparable one.
        let faster = (1...4).map { run(Double($0) * 7, km: 10, minutes: 45) }
        let lastComparable = run(3, km: 10, minutes: 55)   // most recent prior: 5:30/km
        let today = run(0, km: 10, minutes: 50)            // 5:00/km ⇒ 30 s/km faster
        let line = RunVerdict.verdict(for: today, priors: faster + [lastComparable], unit: .metric)?.text
        #expect(line == "30s/km faster than last time at this distance.")
    }

    @Test func theGainIsPhrasedPerDisplayedUnit() {
        let faster = (1...4).map { run(Double($0) * 7, km: 10, minutes: 45) }
        let lastComparable = run(3, km: 10, minutes: 55)
        let today = run(0, km: 10, minutes: 50)            // 30 s/km ⇒ ~48 s/mi
        let line = RunVerdict.verdict(for: today, priors: faster + [lastComparable], unit: .imperial)?.text
        #expect(line == "48s/mi faster than last time at this distance.")
    }

    @Test func noiseSizedGainsAreNotClaimed() {
        let faster = (1...4).map { run(Double($0) * 7, km: 10, minutes: 45) }
        let lastComparable = run(3, km: 10, minutes: 50.2)   // ~1.2 s/km — below the threshold
        let today = run(0, km: 10, minutes: 50)
        let line = RunVerdict.verdict(for: today, priors: faster + [lastComparable], unit: .metric)?.text
        #expect(line?.contains("faster") == false)
    }

    // MARK: No-shame

    /// The heart of the no-shame rule: a slower run is never handed back as a deficit.
    @Test func aSlowerRunIsNeverReportedAsSlower() throws {
        let priors = (1...5).map { run(Double($0) * 7, km: 10, minutes: 45) }
        let today = run(0, km: 10, minutes: 60)            // markedly slower than every prior
        let text = try #require(RunVerdict.verdict(for: today, priors: priors, unit: .metric)?.text)
        #expect(!text.contains("slower"))
        #expect(!text.contains("off your"))
        #expect(!text.localizedCaseInsensitiveContains("down"))
        // It falls through to something true about showing up instead.
        #expect(text.contains("week"))
    }

    // MARK: New ground

    @Test func aNewFurthestIsCalledOut() {
        let today = run(0, km: 21, minutes: 120)
        let priors = [run(7, km: 10, minutes: 50), run(14, km: 12, minutes: 62)]
        #expect(RunVerdict.verdict(for: today, priors: priors, unit: .metric)?.text == "The furthest you've gone. New ground.")
    }

    // MARK: Consistency fallback

    @Test func consistencyCountsOnlyTheTrailingSevenDays() {
        // Two comparable runs inside the week, one well outside it. Today is markedly slower than
        // both recent ones, so it falls through to the count.
        let priors = [run(1, km: 10, minutes: 40), run(3, km: 10, minutes: 41), run(60, km: 10, minutes: 42)]
        let today = run(0, km: 10, minutes: 60)
        #expect(RunVerdict.verdict(for: today, priors: priors, unit: .metric)?.text == "That's 3 this week.")
    }

    @Test func aLoneRunInTheWeekReadsAsTheHardOneDone() {
        // Three faster priors, so the podium branch can't fire; all long outside the trailing week.
        let priors = [run(40, km: 10, minutes: 40), run(50, km: 10, minutes: 41), run(60, km: 10, minutes: 42)]
        let today = run(0, km: 10, minutes: 60)
        #expect(RunVerdict.verdict(for: today, priors: priors, unit: .metric)?.text == "First one of the week. That's the hard one done.")
    }

    // MARK: Tone — what the surface is allowed to dress as an achievement

    /// The accent rule depends on this: only a real best may wear the earned treatment. A line about
    /// showing up must not arrive in the same iridescent capsule as a personal record.
    @Test func onlyGenuineBestsAreToneEarned() {
        let podium = run(0, km: 10, minutes: 50)
        #expect(RunVerdict.verdict(for: podium, priors: [run(7, km: 10, minutes: 55)], unit: .metric)?.tone == .earned)

        let furthest = run(0, km: 21, minutes: 120)
        #expect(RunVerdict.verdict(for: furthest, priors: [run(7, km: 10, minutes: 50)], unit: .metric)?.tone == .earned)

        let faster = (1...4).map { run(Double($0) * 7, km: 10, minutes: 45) }
        let gain = run(0, km: 10, minutes: 50)
        #expect(RunVerdict.verdict(for: gain, priors: faster + [run(3, km: 10, minutes: 55)], unit: .metric)?.tone == .gain)

        let slower = run(0, km: 10, minutes: 60)
        #expect(RunVerdict.verdict(for: slower, priors: faster, unit: .metric)?.tone == .steady)

        let first = run(0, km: 5, minutes: 30)
        #expect(RunVerdict.verdict(for: first, priors: [], unit: .metric)?.tone == .beginning)
    }

    // MARK: Degenerate input

    @Test func aRecordingWithNoDistanceHasNoVerdict() {
        let empty = RunVerdict.Run(date: Self.day0, distanceM: 0, durationS: 600)
        #expect(RunVerdict.verdict(for: empty, priors: [], unit: .metric) == nil)
    }

    @Test func aRecordingWithNoDurationHasNoVerdict() {
        let empty = RunVerdict.Run(date: Self.day0, distanceM: 5_000, durationS: 0)
        #expect(RunVerdict.verdict(for: empty, priors: [], unit: .metric) == nil)
    }

    @Test func priorsWithoutDistanceOrDurationNeverDecideARank() {
        let today = run(0, km: 10, minutes: 50)
        let junk = [RunVerdict.Run(date: Self.day0.addingTimeInterval(-3600), distanceM: 0, durationS: 0)]
        // The junk prior is discarded, leaving no history at all.
        #expect(RunVerdict.verdict(for: today, priors: junk, unit: .metric)?.text.hasPrefix("Your first one") == true)
    }
}
