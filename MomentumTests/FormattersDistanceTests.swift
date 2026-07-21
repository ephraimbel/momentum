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
