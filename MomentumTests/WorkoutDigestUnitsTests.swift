import Testing
import Foundation
@testable import Momentum

/// The AI payload's unit contract.
///
/// Every stored number is SI, and the prompt never said so — so the model was handed
/// `avgPaceSPerKm: 330` for an athlete who reads miles, asked to "reference concrete data", and
/// sometimes simply relabelled the kilometre figure ("5:30 per mile" on a 5:30/km run, seen on the
/// simulator). The fix is that the payload now carries the same pre-formatted strings the screen
/// shows, so there is nothing left to convert. These pin that they are genuinely in the athlete's
/// unit, because the failure is silent: the sentence still reads perfectly, it is just wrong.
@MainActor
struct WorkoutDigestUnitsTests {

    /// ~5 km at 5:30/km, sampled every 10 s along a straight line, so the split re-cut is real.
    private func run() -> Workout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let paceSPerKm = 330.0, distanceM = 5_030.0
        let w = Workout(); w.type = .run; w.startedAt = start
        w.durationS = distanceM / 1000 * paceSPerKm
        let gps = GPSDetail()
        gps.distanceM = distanceM
        gps.avgPaceSPerKm = paceSPerKm
        let step = 10.0
        var samples: [LocationSample] = []
        for i in 0...Int(distanceM / step) {
            let s = LocationSample()
            s.t = start.addingTimeInterval(Double(i) * step / 1000 * paceSPerKm)
            s.lat = 30.25 + Double(i) * step / 111_320.0
            s.lon = -97.73
            s.accepted = true
            samples.append(s)
        }
        gps.samples = samples
        w.gps = gps
        return w
    }

    @Test func imperialAthleteGetsMileLabelsNotKilometreFiguresWearingMileNames() throws {
        let gps = try #require(WorkoutDigest(run(), distanceUnit: .imperial).gps)
        #expect(gps.displayUnit == "mi")
        #expect(gps.distanceLabel.contains("mi"))
        // 5:30/km is 8:51/mi. The whole bug was this coming back as "5:30".
        #expect(gps.avgPaceLabel == "8:51 /mi")
        #expect(gps.avgPaceLabel?.contains("5:30") == false)
    }

    @Test func metricAthleteGetsKilometreLabels() throws {
        let gps = try #require(WorkoutDigest(run(), distanceUnit: .metric).gps)
        #expect(gps.displayUnit == "km")
        #expect(gps.avgPaceLabel == "5:30 /km")
        #expect(gps.distanceLabel.contains("km"))
    }

    @Test func rawFieldsStaySI() throws {
        // The labels are additive. Anything reading the payload for arithmetic still gets SI.
        let gps = try #require(WorkoutDigest(run(), distanceUnit: .imperial).gps)
        #expect(abs(gps.avgPaceSPerKm - 330) < 0.001)
        #expect(abs(gps.distanceM - 5_030) < 0.001)
    }

    @Test func splitLabelsAreCutToTheAthletesUnitNotAlwaysKilometres() throws {
        // `splitResults` is always kilometre splits. Handing those to a mile-reading athlete's coach
        // is how a kilometre time becomes a sentence about a mile.
        let imperial = try #require(WorkoutDigest(run(), distanceUnit: .imperial).gps)
        let metric = try #require(WorkoutDigest(run(), distanceUnit: .metric).gps)
        #expect(imperial.splitLabels.count == 3)   // 5.03 km is 3 full miles
        #expect(metric.splitLabels.count == 5)     // and 5 full kilometres
        #expect(imperial.splitLabels.allSatisfy { $0.hasPrefix("8:") })
        #expect(metric.splitLabels.allSatisfy { $0.hasPrefix("5:") })
    }

    @Test func aWorkoutWithNoPaceOffersNoPaceLabelRatherThanZero() throws {
        // "If a label is missing, say nothing about that number" only works if a missing number
        // actually arrives missing.
        let w = run()
        w.gps?.avgPaceSPerKm = 0
        let gps = try #require(WorkoutDigest(w, distanceUnit: .imperial).gps)
        #expect(gps.avgPaceLabel == nil)
    }
}
