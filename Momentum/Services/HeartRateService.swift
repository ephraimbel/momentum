import Foundation
import HealthKit

/// Live heart-rate source for cardio capture (running-excellence R3). Streams every heart-rate
/// sample landing in HealthKit from the run's start onward — an Apple Watch in a workout session
/// writes ~every 5 s; any BLE strap bridged through Health arrives the same way. An anchored query
/// keeps the stream open for the whole run; readings are staleness-gated so a Watch *outside* a
/// workout session (which samples only every few minutes) never masquerades as live BPM.
@MainActor
final class HeartRateService: HeartRateServing {
    private let store = HKHealthStore()
    private var query: HKAnchoredObjectQuery?
    private var continuation: AsyncStream<HRReading>.Continuation?
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

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        // Read-only; heartRate is already in HealthService's read set, so this is usually a no-op.
        try? await store.requestAuthorization(toShare: [], read: [HKQuantityType(.heartRate)])
    }

    func samples(from start: Date) -> AsyncStream<HRReading> {
        AsyncStream { continuation in
            self.continuation = continuation
            #if DEBUG
            if Self.isSimulated {
                self.startSimulated(continuation: continuation)
                return
            }
            #endif
            guard HKHealthStore.isHealthDataAvailable() else { continuation.finish(); return }
            let unit = HKUnit.count().unitDivided(by: .minute())
            let predicate = HKQuery.predicateForSamples(withStart: start, end: nil)
            let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, _, _ in
                guard let quantities = samples as? [HKQuantitySample], !quantities.isEmpty else { return }
                let readings = quantities
                    .sorted { $0.endDate < $1.endDate }
                    .map { HRReading(t: $0.endDate, bpm: Int($0.quantity.doubleValue(for: unit).rounded())) }
                    .filter { $0.bpm > 0 }
                Task { @MainActor [weak self] in
                    for r in readings {
                        self?.latestBpm = r.bpm
                        self?.latestAt = r.t
                        self?.continuation?.yield(r)
                    }
                }
            }
            let query = HKAnchoredObjectQuery(type: HKQuantityType(.heartRate), predicate: predicate,
                                              anchor: nil, limit: HKObjectQueryNoLimit, resultsHandler: handler)
            query.updateHandler = handler
            self.query = query
            store.execute(query)
        }
    }

    func stop() {
        if let query { store.stop(query) }
        query = nil
        continuation?.finish()
        continuation = nil
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

    private func startSimulated(continuation: AsyncStream<HRReading>.Continuation) {
        simulatedTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                // 96 bpm at the line → ~90 s ramp toward ~158 with a slow ±4 wander.
                let ramp = min(1.0, Double(tick) / 90)
                let bpm = Int((96 + 62 * ramp + 4 * sin(Double(tick) / 23)).rounded())
                let reading = HRReading(t: Date(), bpm: bpm)
                await MainActor.run { [weak self] in
                    self?.latestBpm = reading.bpm
                    self?.latestAt = reading.t
                }
                continuation.yield(reading)
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
            continuation.finish()
        }
    }
    #endif
}
