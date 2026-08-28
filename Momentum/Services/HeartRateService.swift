import Foundation
import HealthKit

/// Live heart rate from HealthKit (running-excellence R3) — the second live-HR source next to the
/// BLE strap (`HeartRateMonitor`). An anchored query streams heart-rate samples landing in Health
/// from `start()` onward: an Apple Watch in a workout session writes ~every 5 s, and anything else
/// bridged through Health arrives the same way. Readings are staleness-gated so a Watch *outside* a
/// workout session (which samples only every few minutes) never masquerades as live BPM.
///
/// Deliberately never requests Health authorization — a full-screen Health sheet at the start line
/// would block the run (and its taps). Read access comes from the existing Apple Health connect
/// flow; without it the query simply yields nothing, like missing hardware.
@MainActor
final class HeartRateService: HeartRateServing {
    private let store = HKHealthStore()
    private var query: HKAnchoredObjectQuery?
    #if DEBUG
    private var simulatedTask: Task<Void, Never>?
    #endif

    private var latestBpm: Int?
    private var latestAt: Date?

    /// Older than this and the reading is history, not "your heart rate right now".
    private static let stalenessS: TimeInterval = 60

    var bpm: Int? {
        guard let latestAt, Date().timeIntervalSince(latestAt) <= Self.stalenessS else { return nil }
        return latestBpm
    }

    /// "Connected" = a live source is actually feeding us (fresh reading within the staleness window).
    var isConnected: Bool { bpm != nil }

    func start() {
        guard query == nil else { return }
        #if DEBUG
        if Self.isSimulated { startSimulated(); return }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let predicate = HKQuery.predicateForSamples(withStart: Date(), end: nil)
        let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, _, _ in
            guard let latest = (samples as? [HKQuantitySample])?.max(by: { $0.endDate < $1.endDate }) else { return }
            let value = Int(latest.quantity.doubleValue(for: unit).rounded())
            guard value > 0 else { return }
            Task { @MainActor [weak self] in
                self?.latestBpm = value
                self?.latestAt = latest.endDate
            }
        }
        let query = HKAnchoredObjectQuery(type: HKQuantityType(.heartRate), predicate: predicate,
                                          anchor: nil, limit: HKObjectQueryNoLimit, resultsHandler: handler)
        query.updateHandler = handler
        self.query = query
        store.execute(query)
    }

    func stop() {
        if let query { store.stop(query) }
        query = nil
        #if DEBUG
        simulatedTask?.cancel()
        simulatedTask = nil
        #endif
        latestBpm = nil
        latestAt = nil
    }

    #if DEBUG
    /// The simulator has no Watch/strap feeding Health, so live HR can't be exercised there.
    /// `--demo-hr` (or the self-contained `--ui-test-route` run) swaps in a plausible synthetic
    /// stream — a warm-up ramp settling into a gently oscillating aerobic effort — for visual
    /// iteration and UI tests. Never ships (DEBUG) and never activates without the launch arg.
    static var isSimulated: Bool {
        ProcessInfo.processInfo.arguments.contains("--demo-hr") || LocationService.isUITestRoute
    }

    private func startSimulated() {
        simulatedTask = Task { [weak self] in
            var tick = 0
            let outage = LocationService.isOutage
            while !Task.isCancelled {
                // `--ui-test-outage`: the strap/Watch goes quiet with the GPS feed. No new
                // readings land, so the last one ages through the real 60 s staleness gate and
                // `bpm` goes nil — exercising the live screen's honest "--" placeholder.
                if outage, tick >= Int(LocationService.outageAtS) {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                // 96 bpm at the line → ~90 s ramp toward ~158 with a slow ±4 wander.
                let ramp = min(1.0, Double(tick) / 90)
                let value = Int((96 + 62 * ramp + 4 * sin(Double(tick) / 23)).rounded())
                await MainActor.run { [weak self] in
                    self?.latestBpm = value
                    self?.latestAt = Date()
                }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    #endif
}

/// The run screen's live-HR source: a BLE strap and the HealthKit stream, raced. The strap wins when
/// both report (it's the lower-latency, purpose-worn device); a Watch in a workout session covers
/// everyone else. Either alone is enough — and with neither, `bpm` stays nil and the run never
/// depends on it.
@MainActor
final class LiveHeartRateSource: HeartRateServing {
    private let strap: HeartRateMonitor
    private let health: HeartRateService

    init(strap: HeartRateMonitor = HeartRateMonitor(), health: HeartRateService = HeartRateService()) {
        self.strap = strap
        self.health = health
    }

    var bpm: Int? { strap.bpm ?? health.bpm }
    var isConnected: Bool { strap.isConnected || health.isConnected }

    func start() {
        strap.start()
        health.start()
    }

    func stop() {
        strap.stop()
        health.stop()
    }
}
