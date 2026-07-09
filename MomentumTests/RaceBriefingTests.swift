import Testing
@testable import Momentum

/// The pre-race briefing: right window, right message per day, fueling sized to the predicted finish.
struct RaceBriefingTests {
    private let marathon = RaceDistance.marathon.meters

    @Test func onlyTheFinalDaysGetABriefing() {
        #expect(RaceBriefing.build(distanceM: marathon, p5kSPerKm: 300, daysOut: 4) == nil)
        #expect(RaceBriefing.build(distanceM: marathon, p5kSPerKm: 300, daysOut: -1) == nil)
        #expect(RaceBriefing.build(distanceM: marathon, p5kSPerKm: 0, daysOut: 1) == nil)   // no fitness read
        #expect(RaceBriefing.build(distanceM: marathon, p5kSPerKm: 300, daysOut: 3) != nil)
    }

    @Test func eachDayCarriesItsOwnMessage() throws {
        let approach = try #require(RaceBriefing.build(distanceM: marathon, p5kSPerKm: 300, daysOut: 3))
        #expect(approach.body.contains("Taper means taper"))
        #expect(approach.body.contains("carbs"))

        let eve = try #require(RaceBriefing.build(distanceM: marathon, p5kSPerKm: 300, daysOut: 1))
        #expect(eve.title == "Tomorrow is race day")
        #expect(eve.body.contains("nothing new"))
        #expect(eve.body.contains("kit"))

        let day = try #require(RaceBriefing.build(distanceM: marathon, p5kSPerKm: 300, daysOut: 0))
        #expect(day.title.contains("Race day"))
        // A ~4-hour predicted marathon lands in the 60–90 g/hr race plan.
        #expect(day.body.contains("60–90 g"))
        #expect(day.body.contains("too easy"))     // start-control coaching
    }

    @Test func shortRaceGetsTheLighterFuelPlan() throws {
        // A ~25-minute 5K predicts under an hour → no in-race carbs pushed on race day.
        let day = try #require(RaceBriefing.build(distanceM: RaceDistance.fiveK.meters, p5kSPerKm: 300, daysOut: 0))
        #expect(!day.body.contains("60–90 g"))
        #expect(!day.body.contains("30–60 g"))
    }
}
