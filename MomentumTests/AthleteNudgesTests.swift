import Testing
import Foundation
@testable import Momentum

/// Verifies the deterministic proactive nudges (ATHLETE-MODEL.md §9).
@MainActor
struct AthleteNudgesTests {
    private let now = Date(timeIntervalSinceReferenceDate: 700_000_000)

    @Test func emptyFactsNoNudges() {
        #expect(AthleteNudges.generate(AthleteFacts(), now: now).isEmpty)
    }

    @Test func cautionWhenPastOverreachThreshold() {
        var f = AthleteFacts(); f.currentACWR = 1.6; f.overreachThresholdACWR = 1.5
        let nudges = AthleteNudges.generate(f, now: now)
        #expect(nudges.contains { $0.kind == .caution })
        #expect(nudges.first?.kind == .caution)   // caution leads (safety first)
    }

    @Test func fitnessMilestoneWhenFaster() {
        var f = AthleteFacts(); f.paceAtEffortTrendPct = -5
        let nudges = AthleteNudges.generate(f, now: now)
        #expect(nudges.contains { $0.kind == .milestone && $0.title == "You're getting faster" })
    }

    @Test func recentPRIsAMilestone() {
        var f = AthleteFacts(); f.lastPRAt = now.addingTimeInterval(-3 * 86_400)
        let nudges = AthleteNudges.generate(f, now: now)
        #expect(nudges.contains { $0.title == "New personal record" })
    }

    @Test func quietStretchIsAGentleCheckin() {
        var f = AthleteFacts(); f.frequencyTrend28d = -1.0
        let nudges = AthleteNudges.generate(f, now: now)
        #expect(nudges.contains { $0.kind == .checkin })
    }

    @Test func cappedAtMax() {
        var f = AthleteFacts()
        f.currentACWR = 1.7; f.overreachThresholdACWR = 1.4   // caution
        f.paceAtEffortTrendPct = -6                            // milestone
        f.lastPRAt = now.addingTimeInterval(-86_400)           // milestone
        f.frequencyTrend28d = 1.0                              // encouragement
        let nudges = AthleteNudges.generate(f, now: now)
        #expect(nudges.count <= AthleteNudges.maxNudges)
    }
}
