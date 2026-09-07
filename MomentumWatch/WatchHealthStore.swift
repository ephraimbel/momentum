import Foundation
import Observation
import WatchConnectivity
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The wrist's copy of the phone's health snapshot (2026-09-06): readiness, sleep, HRV, resting
/// heart rate, strain and the week's training — one Codable value the phone builds from its own
/// engines (`WristHealth`) and pushes with the rest of the application context.
///
/// The store never computes a score. It decodes, persists to the app group (so the complications
/// read the same bytes), and asks the phone for a fresher one when what it holds is from another
/// day or a few hours old — the phone re-reads Health through the morning, so a number can move.
@MainActor
@Observable
final class WatchHealthStore {
    static let shared = WatchHealthStore()
    static let snapshotKey = "sync.health.snapshot"
    static let lastRequestKey = "sync.health.lastRequest"
    /// A refresh request is a background launch of the phone app; one every ten minutes is plenty.
    static let requestInterval: TimeInterval = 10 * 60

    private(set) var snapshot: WristHealthSnapshot?
    private let defaults = UserDefaults(suiteName: WatchSyncStore.appGroup) ?? .standard

    private init() {
        load()
        applyDebugOverrides()
    }

    /// Called by `WatchSyncStore` for every application context that carries a `health` payload.
    func apply(data: Data) {
        guard let decoded = WristHealthSnapshot.decode(data) else { return }
        // Never let an older snapshot overwrite a newer one (contexts can arrive out of order
        // after a reconnect).
        if let current = snapshot, current.generatedAt > decoded.generatedAt { return }
        snapshot = decoded
        defaults.set(data, forKey: Self.snapshotKey)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// True when the snapshot is from another day or older than three hours.
    var isStale: Bool { snapshot?.isStale() ?? true }

    /// Today's snapshot, or the most recent one the wrist holds — the views label an older one
    /// honestly rather than going blank at midnight (a night's sleep is still last night's sleep).
    var current: WristHealthSnapshot? { snapshot }

    /// Ask the phone for a fresher snapshot, at most once per `requestInterval`. Delivered by
    /// `transferUserInfo`, which launches the phone app in the background if it is not running.
    func requestRefreshIfStale(now: Date = Date()) {
        guard isStale, WCSession.isSupported() else { return }
        let last = defaults.object(forKey: Self.lastRequestKey) as? Date ?? .distantPast
        guard now.timeIntervalSince(last) >= Self.requestInterval else { return }
        defaults.set(now, forKey: Self.lastRequestKey)
        WCSession.default.transferUserInfo(["kind": "refresh", "dayKey": WristHealthSnapshot.dayKey(now)])
    }

    private func load() {
        snapshot = defaults.data(forKey: Self.snapshotKey).flatMap(WristHealthSnapshot.decode)
    }

    private func applyDebugOverrides() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--watch-health-demo") {
            snapshot = .demo()
        } else if args.contains("--watch-health-empty") {
            snapshot = WristHealthSnapshot(dayKey: WristHealthSnapshot.dayKey(Date()), generatedAt: Date(), healthConnected: true)
        } else if args.contains("--watch-health-disconnected") {
            snapshot = WristHealthSnapshot(dayKey: WristHealthSnapshot.dayKey(Date()), generatedAt: Date(), healthConnected: false)
        } else if args.contains("--watch-health-stale") {
            var s = WristHealthSnapshot.demo(now: Date().addingTimeInterval(-86_400))
            s.readiness?.score = 61
            s.readiness?.band = "moderate"
            s.readiness?.word = "Moderate"
            snapshot = s
        }
        #endif
    }
}

#if DEBUG
extension WristHealthSnapshot {
    /// A deterministic, well-recovered morning for simulator screenshots and reviews.
    static func demo(now: Date = Date()) -> WristHealthSnapshot {
        var s = WristHealthSnapshot(dayKey: dayKey(now), generatedAt: now, healthConnected: true)
        s.readiness = .init(
            score: 78, band: "ready", word: "Ready",
            driver: "Sleep did the work · high confidence",
            guidance: "A good day for the session as planned. Keep the easy parts easy.",
            confidence: "high",
            pillars: [
                .init(kind: "sleep", title: "Sleep", detail: "7h 42m of 7h 30m", points: 9.5),
                .init(kind: "hrv", title: "HRV", detail: "52 ms · norm 48", points: 6.0),
                .init(kind: "restingHR", title: "Resting HR", detail: "51 bpm · norm 52", points: 2.5),
                .init(kind: "load", title: "Load", detail: "Recent training", points: -3.0),
                .init(kind: "checkin", title: "Check-in", detail: "Full tank · Fresh", points: 4.0),
            ],
            modifiers: [])
        s.sleep = .init(asleepH: 7.7, needH: 7.5, debt14H: 1.3, efficiencyPct: 92, deepPct: 19, remPct: 23,
                        band: "Good", nightDayKey: dayKey(now), note: "Right on your need. Deep and REM in your norm.",
                        week: [6.9, 7.2, 6.4, 7.8, 7.1, 6.6, 7.7])
        s.hrv = .init(value: 52, baseline: 48, trend: "up", note: "Above your norm. Recovered.",
                      week: [46, 49, 44, 51, 47, 50, 52])
        s.restingHR = .init(value: 51, baseline: 52, trend: "steady", note: "In your norm.",
                            week: [53, 52, 54, 51, 52, 52, 51])
        s.respiratoryZ = 0.3
        s.wristTempDeltaC = 0.1
        s.strain = .init(score: 34, band: "Light", workoutLoad: 118, ambientLoad: 42,
                         week: [58, 21, 72, 15, 44, 66, 34])
        s.training = .init(weekDoneM: 24_300, weekPlannedM: 41_000, doneSessions: 3, totalSessions: 5,
                           streakDays: 12, loadWord: "Building", loadLine: "Load is rising at a rate you can absorb.")
        return s
    }
}
#endif
