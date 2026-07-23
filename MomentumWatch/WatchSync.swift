import Foundation
import Observation
import WatchConnectivity
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The wrist's picture of the phone's brain (Slice 4, revived): readiness, today's session, and
/// the next race arrive as a compact `applicationContext` push and are cached in the shared app
/// group so complications read the same numbers the app shows. The morning check-in travels the
/// other way (`transferUserInfo` — queued, survives the phone being away). Everything degrades:
/// no phone, no pairing, no data → cards simply don't render, never a fake number.
@MainActor
@Observable
final class WatchSyncStore: NSObject {
    static let shared = WatchSyncStore()
    static let appGroup = "group.com.ephraimbel.momentum.app"

    struct Readiness: Equatable {
        var score: Int
        var band: String        // RecoveryModel.Readiness rawValue ("primed"…)
        var driver: String
        var dayKey: String
    }

    struct TodaySession: Equatable {
        var title: String       // "Long run"
        var detail: String      // "6 mi · ~11:56 /mi"
        var typeRaw: String     // WorkoutType rawValue for the start shortcut
        var paceLoSPerKm: Double?
        var paceHiSPerKm: Double?
        var dayKey: String
    }

    struct Race: Equatable {
        var name: String
        var dateKey: String     // local yyyy-MM-dd of race day
    }

    private(set) var readiness: Readiness?
    private(set) var session: TodaySession?
    private(set) var race: Race?
    /// Day the athlete answered the check-in ON THE WATCH (locally latched so the card flips
    /// immediately; the phone's recompute lands as a readiness push moments later).
    private(set) var checkinSentDayKey: String?

    private let defaults = UserDefaults(suiteName: WatchSyncStore.appGroup) ?? .standard

    static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }

    private override init() {
        super.init()
        load()
        applyDebugOverrides()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Today's values only — yesterday's readiness on the wrist would be a quiet lie.
    var todayReadiness: Readiness? {
        readiness?.dayKey == Self.dayKey() ? readiness : nil
    }

    var todaySession: TodaySession? {
        session?.dayKey == Self.dayKey() ? session : nil
    }

    var checkinAnsweredToday: Bool {
        checkinSentDayKey == Self.dayKey() || todayReadiness != nil && defaults.bool(forKey: "checkin.\(Self.dayKey())")
    }

    /// Days until the race (0 = race day), nil when no race or it's passed.
    var raceDaysAway: Int? {
        guard let race else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        guard let day = f.date(from: race.dateKey) else { return nil }
        let days = Calendar.current.dateComponents([.day],
                                                   from: Calendar.current.startOfDay(for: Date()),
                                                   to: day).day ?? -1
        return days >= 0 ? days : nil
    }

    /// The morning answers, on their way to the phone (queued through WatchConnectivity, so an
    /// out-of-range iPhone gets them on reconnect). Latches the local day immediately.
    func sendCheckin(energy: String, legs: String) {
        checkinSentDayKey = Self.dayKey()
        defaults.set(true, forKey: "checkin.\(Self.dayKey())")
        guard WCSession.isSupported() else { return }
        WCSession.default.transferUserInfo([
            "kind": "checkin",
            "energy": energy,
            "legs": legs,
            "dayKey": Self.dayKey(),
        ])
    }

    // MARK: Cache (shared with the complication timeline provider)

    private func load() {
        if let score = defaults.object(forKey: "sync.readiness.score") as? Int,
           let band = defaults.string(forKey: "sync.readiness.band"),
           let driver = defaults.string(forKey: "sync.readiness.driver"),
           let day = defaults.string(forKey: "sync.readiness.dayKey") {
            readiness = Readiness(score: score, band: band, driver: driver, dayKey: day)
        }
        if let title = defaults.string(forKey: "sync.session.title"),
           let detail = defaults.string(forKey: "sync.session.detail"),
           let typeRaw = defaults.string(forKey: "sync.session.typeRaw"),
           let day = defaults.string(forKey: "sync.session.dayKey") {
            session = TodaySession(title: title, detail: detail, typeRaw: typeRaw,
                                   paceLoSPerKm: defaults.object(forKey: "sync.session.paceLo") as? Double,
                                   paceHiSPerKm: defaults.object(forKey: "sync.session.paceHi") as? Double,
                                   dayKey: day)
        }
        if let name = defaults.string(forKey: "sync.race.name"),
           let dateKey = defaults.string(forKey: "sync.race.dateKey") {
            race = Race(name: name, dateKey: dateKey)
        }
        checkinSentDayKey = defaults.bool(forKey: "checkin.\(Self.dayKey())") ? Self.dayKey() : nil
    }

    private func apply(context: [String: Any]) {
        if let score = context["readinessScore"] as? Int,
           let band = context["readinessBand"] as? String,
           let day = context["readinessDayKey"] as? String {
            let driver = context["readinessDriver"] as? String ?? ""
            readiness = Readiness(score: score, band: band, driver: driver, dayKey: day)
            defaults.set(score, forKey: "sync.readiness.score")
            defaults.set(band, forKey: "sync.readiness.band")
            defaults.set(driver, forKey: "sync.readiness.driver")
            defaults.set(day, forKey: "sync.readiness.dayKey")
        }
        if let title = context["sessionTitle"] as? String,
           let detail = context["sessionDetail"] as? String,
           let day = context["sessionDayKey"] as? String {
            let typeRaw = context["sessionTypeRaw"] as? String ?? "run"
            session = TodaySession(title: title, detail: detail, typeRaw: typeRaw,
                                   paceLoSPerKm: context["sessionPaceLo"] as? Double,
                                   paceHiSPerKm: context["sessionPaceHi"] as? Double,
                                   dayKey: day)
            defaults.set(title, forKey: "sync.session.title")
            defaults.set(detail, forKey: "sync.session.detail")
            defaults.set(typeRaw, forKey: "sync.session.typeRaw")
            defaults.set(day, forKey: "sync.session.dayKey")
            defaults.set(context["sessionPaceLo"] as? Double, forKey: "sync.session.paceLo")
            defaults.set(context["sessionPaceHi"] as? Double, forKey: "sync.session.paceHi")
        } else if context["sessionCleared"] as? Bool == true {
            session = nil
            defaults.removeObject(forKey: "sync.session.title")
        }
        if let raceName = context["raceName"] as? String,
           let raceDate = context["raceDateKey"] as? String {
            race = Race(name: raceName, dateKey: raceDate)
            defaults.set(raceName, forKey: "sync.race.name")
            defaults.set(raceDate, forKey: "sync.race.dateKey")
        } else if context["raceCleared"] as? Bool == true {
            race = nil
            defaults.removeObject(forKey: "sync.race.name")
            defaults.removeObject(forKey: "sync.race.dateKey")
        }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: Debug overrides — the watch sim has no paired phone; cards verify via launch args

    private func applyDebugOverrides() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let arg = args.first(where: { $0.hasPrefix("--watch-readiness=") }),
           let score = Int(arg.dropFirst("--watch-readiness=".count)) {
            let band = score >= 80 ? "primed" : score >= 65 ? "ready" : score >= 45 ? "steady" : "easy"
            readiness = Readiness(score: score, band: band,
                                  driver: "Load well absorbed", dayKey: Self.dayKey())
            defaults.set(true, forKey: "checkin.\(Self.dayKey())")
            checkinSentDayKey = Self.dayKey()
        }
        if args.contains("--watch-session") {
            session = TodaySession(title: "Long run", detail: "6 mi · ~11:56 /mi", typeRaw: "run",
                                   paceLoSPerKm: 424, paceHiSPerKm: 465, dayKey: Self.dayKey())
        }
        if let arg = args.first(where: { $0.hasPrefix("--watch-race=") }) {
            // "--watch-race=Berlin Half:3" → race in 3 days ("0" = race day)
            let raw = String(arg.dropFirst("--watch-race=".count))
            let parts = raw.split(separator: ":")
            if parts.count == 2, let days = Int(parts[1]),
               let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) {
                race = Race(name: String(parts[0]), dateKey: Self.dayKey(date))
            }
        }
        if args.contains("--watch-checkin") {
            defaults.removeObject(forKey: "checkin.\(Self.dayKey())")
            checkinSentDayKey = nil
            readiness = nil
        }
        #endif
    }
}

// MARK: WCSession delegate (nonisolated; hop to main to publish)

extension WatchSyncStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        // A context can be waiting from before this activation — fold it in.
        let pending = session.receivedApplicationContext
        guard !pending.isEmpty else { return }
        Task { @MainActor in self.apply(context: pending) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in self.apply(context: context) }
    }
}
