import Testing
import Foundation
@testable import Momentum

/// The distance numeral helpers behind the post-workout hero. `distance(meters:unit:)` is now
/// written in terms of `distanceNumeral`, so its old behaviour is pinned here too.
struct FormattersDistanceTests {

    // MARK: distanceNumeral — trailing zeros dropped

    @Test func wholeValuesLoseTheirDecimals() {
        #expect(Formatters.distanceNumeral(6) == "6")
        #expect(Formatters.distanceNumeral(5.0) == "5")
    }

    @Test func oneDecimalIsKeptWhenItCarriesInformation() {
        #expect(Formatters.distanceNumeral(3.5) == "3.5")
    }

    @Test func twoDecimalsSurviveOnARecordedDistance() {
        #expect(Formatters.distanceNumeral(5.03) == "5.03")
    }

    @Test func hundredAndOverRoundsToWhole() {
        #expect(Formatters.distanceNumeral(123.4) == "123")
    }

    // MARK: distance — unchanged by the refactor

    @Test func distanceStillAppendsItsUnit() {
        #expect(Formatters.distance(meters: 5_000, unit: .metric) == "5 km")
        #expect(Formatters.distance(meters: 3_500, unit: .metric) == "3.5 km")
        #expect(Formatters.distance(meters: Formatters.metersPerMile, unit: .imperial) == "1 mi")
    }

    // MARK: wholeDistance — number and unit split apart

    /// Load-bearing in two places that both used to hardcode "km": the Progress trend/history tiles
    /// and the celebration's week caption. The unit word has to come from the athlete's setting, and
    /// the value has to be whole — "16 of 19.88 mi this week" was false precision on a target nobody
    /// set to two decimals.
    @Test func wholeDistanceReturnsARoundedValueAndTheRightUnitWord() {
        let metric = Formatters.wholeDistance(meters: 32_000, unit: .metric)
        #expect(metric.value == 32)
        #expect(metric.unit == "km")

        let imperial = Formatters.wholeDistance(meters: 32_000, unit: .imperial)
        #expect(imperial.value == 20)          // 19.88 mi, rounded — never rendered as 19.88
        #expect(imperial.unit == "mi")
    }

    @Test func wholeDistanceRoundsRatherThanTruncates() {
        #expect(Formatters.wholeDistance(meters: 26_000, unit: .imperial).value == 16)   // 16.16
        #expect(Formatters.wholeDistance(meters: 1_600, unit: .metric).value == 2)       // 1.6 → 2
        #expect(Formatters.wholeDistance(meters: 1_400, unit: .metric).value == 1)       // 1.4 → 1
    }

    @Test func wholeDistanceHandlesZero() {
        #expect(Formatters.wholeDistance(meters: 0, unit: .metric).value == 0)
        #expect(Formatters.wholeDistance(meters: 0, unit: .imperial).unit == "mi")
    }

    // MARK: steadyNumeral — the count-up's digit count must not move

    /// The property that matters: whatever the hero counts THROUGH renders with the same number of
    /// decimals as where it lands. Otherwise the numeral changes width mid-tally and visibly jitters
    /// — which tabular figures cannot fix, because it's digit count and not digit width.
    @Test func theDecimalCountIsFixedByTheTargetNotThePassingValue() {
        let toFourFortyFive = Formatters.steadyNumeral(target: 4.45)
        #expect(toFourFortyFive(0) == "0.00")
        #expect(toFourFortyFive(2.5) == "2.50")
        #expect(toFourFortyFive(4.45) == "4.45")

        let toFive = Formatters.steadyNumeral(target: 5)
        #expect(toFive(0) == "0")
        #expect(toFive(5) == "5")
    }

    /// A clean 5 km run reads "5" at rest — the bug this replaced always rendered "5.00".
    @Test func aWholeTargetLandsWithoutTrailingZeros() {
        #expect(Formatters.steadyNumeral(target: 10)(10) == "10")
        #expect(Formatters.steadyNumeral(target: 3.5)(3.5) == "3.5")
        #expect(Formatters.steadyNumeral(target: 4.45)(4.45) == "4.45")
    }

    @Test func longDistancesDropToWholeUnits() {
        #expect(Formatters.steadyNumeral(target: 161)(161) == "161")
    }

    @Test func aZeroTargetIsSafe() {
        #expect(Formatters.steadyNumeral(target: 0)(0) == "0")
    }
}
