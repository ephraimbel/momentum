import Foundation
import Testing
@testable import Momentum

/// The wrist's health snapshot (2026-09-06): built once on the phone from the same engines every
/// phone surface reads, carried to the watch as one Codable value. These pin the wire format, the
/// staleness rules and the pieces the watch renders.
@MainActor
struct WristHealthTests {
    private let cal = Calendar(identifier: .gregorian)
    private var now: Date {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 6; c.hour = 7; c.minute = 30
        return cal.date(from: c)!
    }

    private func day(_ ago: Int) -> Date {
        cal.date(byAdding: .day, value: -ago, to: cal.startOfDay(for: now))!
    }

    private func inputs(readiness: MorningReadiness? = nil) -> WristHealth.Inputs {
        var signals = RecoverySignals()
        signals.hrvMs = 52; signals.hrvBaselineMs = 48
        signals.restingHR = 51; signals.restingHRBaseline = 52
        signals.sleepHours = 7.7
        let nights = (0..<7).map { ago in
            SleepReport.Night(date: day(ago), asleepH: [7.7, 6.6, 7.1, 7.8, 6.4, 7.2, 6.9][ago],
                              coreS: nil, deepS: nil, remS: nil, awakeS: nil, inBedS: nil)
        }
        return WristHealth.Inputs(
            readiness: readiness, signals: signals,
            hrvHist: (0..<7).map { (day($0), 52 - Double($0)) },
            rhrHist: (0..<7).map { (day($0), 51 + Double($0 % 2)) },
            nights: nights, workouts: [], checkin: nil,
            dailySteps: (0..<7).map { (day($0), 6_000 + Double($0) * 500) },
            healthConnected: true)
    }

    @Test func snapshotCarriesLastNightTheVitalsAndTheWeek() {
        let s = WristHealth.build(inputs(), now: now, calendar: cal)
        #expect(s.dayKey == "2026-09-06")
        #expect(s.healthConnected)
        #expect(s.sleep?.asleepH == 7.7)
        #expect(s.sleep?.week.count == 7)
        #expect(s.sleep?.week.last == 7.7, "the week is oldest first, last night last")
        #expect(s.hrv?.value == 52 && s.hrv?.baseline == 48 && s.hrv?.trend == "up")
        #expect(s.hrv?.week.last == 52)
        #expect(s.restingHR?.value == 51 && s.restingHR?.trend == "steady")
        // Steps alone make a strain day, so the week has seven entries and today a score — and the
        // band is the engine's own cut for that score, never a word the wrist invents.
        #expect(s.strain?.week.count == 7)
        #expect(s.strain.map { (0...100).contains($0.score) && $0.band == DayStrain.band($0.score).rawValue } == true)
        #expect(s.strain?.ambientLoad ?? 0 > 0, "today's steps count as ambient load")
        #expect(s.readiness == nil, "no readiness was supplied, none is invented")
    }

    @Test func wireFormatRoundTripsAndRefusesAFutureVersion() {
        let s = WristHealth.build(inputs(), now: now, calendar: cal)
        let data = s.encoded()!
        #expect(WristHealthSnapshot.decode(data) == s)
        var future = s
        future.version = WristHealthSnapshot.currentVersion + 1
        #expect(WristHealthSnapshot.decode(future.encoded()!) == nil)
        // Unknown keys from a newer phone are ignored, not fatal.
        var json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["somethingNewer"] = ["x": 1]
        let widened = try! JSONSerialization.data(withJSONObject: json)
        #expect(WristHealthSnapshot.decode(widened) == s)
    }

    @Test func stalenessFollowsTheDayAndTheClock() {
        let s = WristHealth.build(inputs(), now: now, calendar: cal)
        #expect(s.isForToday(now: now, calendar: cal))
        #expect(!s.isStale(now: now.addingTimeInterval(3_500), calendar: cal))
        #expect(s.isStale(now: now.addingTimeInterval(4 * 3600), calendar: cal), "four hours on, ask again")
        #expect(s.isStale(now: day(-1), calendar: cal), "another day is always stale")
        #expect(!s.isForToday(now: day(-1), calendar: cal))
    }

    @Test func theEmptyLinesAreHonestAboutWhy() {
        var s = WristHealthSnapshot(dayKey: "2026-09-06", generatedAt: now, healthConnected: false)
        #expect(s.emptyLine?.contains("Connect Apple Health") == true)
        s.healthConnected = true
        #expect(s.emptyLine?.contains("first night") == true)
        s.hrv = .init(value: 50, baseline: nil, trend: nil, note: nil, week: [])
        #expect(s.emptyLine == nil)
        #expect(s.hasVitals)
    }

    @Test func cacheStoresAndClears() {
        let defaults = UserDefaults(suiteName: "WristHealthTests.\(UUID().uuidString)")!
        let s = WristHealth.build(inputs(), now: now, calendar: cal)
        WristHealth.store(s, defaults: defaults)
        #expect(WristHealth.cached(defaults: defaults) == s)
        WristHealth.clear(defaults: defaults)
        #expect(WristHealth.cached(defaults: defaults) == nil)
    }

    @Test func bandKeysAreStableAndHoursReadAsHoursAndMinutes() {
        #expect(WristHealth.bandKey(.primed) == "primed")
        #expect(WristHealth.bandKey(.depleted) == "depleted")
        #expect(WristHealth.hours(7.7) == "7h 42m")
        #expect(WristHealth.hours(0.25) == "0h 15m")
    }
}
