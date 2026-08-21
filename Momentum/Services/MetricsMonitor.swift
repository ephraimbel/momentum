import Foundation
import os
#if canImport(MetricKit)
import MetricKit
#endif

/// Crash + performance monitoring via Apple's on-device **MetricKit** (PRD §13.5) — no third-party
/// crash SDK, no PII. The system delivers a daily aggregated metrics payload and, on iOS 14+,
/// diagnostic payloads (crashes, hangs, disk-write exceptions, CPU exceptions).
///
/// Payloads are summarized to the unified log **and forwarded to analytics** (`start(reporting:)`,
/// 2026-08-21). The forwarding is the part that matters: until it existed, every crash count, hang
/// count, and launch histogram this class received was written to `os_log` on the device and read by
/// nobody, which meant the >99.5% crash-free bar in PRD §22 was a target with no instrument behind
/// it. Only counts and millisecond buckets leave — never a stack frame, an address, or anything
/// identifying — so this stays inside the §13.3 privacy rule.
///
/// Daily MetricKit payloads arrive at most once every 24h, and only on a physical device — this is a
/// no-op in the simulator. It's a singleton because `MXMetricManager` keeps a weak list of
/// subscribers; we register once at launch and never unregister.
final class MetricsMonitor: NSObject {
    static let shared = MetricsMonitor()
    private let logger = Logger(subsystem: "com.ephraimbel.momentum.app", category: "metrics")

    /// Where summarized payloads go. Weak: the monitor is a singleton and must not be the thing
    /// keeping the analytics service (and its Supabase sink) alive.
    private weak var analytics: (any AnalyticsServing)?

    /// Register for MetricKit delivery. Safe to call once at app launch.
    /// - Parameter reporting: analytics sink for the summarized payloads. Omit to keep the old
    ///   log-only behavior (previews, tests).
    @MainActor
    func start(reporting analytics: (any AnalyticsServing)? = nil) {
        self.analytics = analytics
        #if canImport(MetricKit) && !targetEnvironment(simulator)
        MXMetricManager.shared.add(self)
        #endif
    }

    /// Hop to the main actor to log — `AnalyticsServing` is `@MainActor` and MetricKit delivers on
    /// its own queue.
    private func report(_ event: AnalyticsEvent) {
        Task { @MainActor [weak self] in self?.analytics?.log(event) }
    }
}

#if canImport(MetricKit)
extension MetricsMonitor: MXMetricManagerSubscriber {
    /// Daily aggregated performance metrics (launch, hang, GPU, memory, …).
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let launchMs = payload.applicationLaunchMetrics
                .map { Self.tailBucketMs($0.histogrammedTimeToFirstDraw) } ?? -1
            let hangMs = payload.applicationResponsivenessMetrics
                .map { Self.tailBucketMs($0.histogrammedApplicationHangTime) } ?? -1
            logger.info("metric=app_performance launch_ms=\(launchMs, privacy: .public) hang_ms=\(hangMs, privacy: .public)")
            guard launchMs >= 0 || hangMs >= 0 else { continue }
            report(.appPerformance(launchMs: launchMs, hangMs: hangMs))
        }
    }

    /// Diagnostic payloads — crashes, hangs, CPU/disk exceptions (iOS 14+).
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            let cpuExceptions = payload.cpuExceptionDiagnostics?.count ?? 0
            guard crashes + hangs + cpuExceptions > 0 else { continue }
            logger.error("diagnostic crashes=\(crashes, privacy: .public) hangs=\(hangs, privacy: .public) cpu=\(cpuExceptions, privacy: .public)")
            report(.appDiagnostics(crashes: crashes, hangs: hangs, cpuExceptions: cpuExceptions))
        }
    }

    /// The upper edge of the highest non-empty bucket, in milliseconds — the slow tail, which is the
    /// half of a launch/hang histogram worth watching. The previous code logged
    /// `totalBucketCount` (how many BUCKETS the histogram had, not how long anything took) and a
    /// `String(describing:)` of the last bucket object, neither of which is a duration.
    /// Both call sites are `MXHistogram<UnitDuration>`, so this takes that concretely rather than
    /// generically — a generic `U: Unit` cannot be converted to milliseconds without a force-cast,
    /// and a force-cast in the crash reporter is its own punchline.
    static func tailBucketMs(_ histogram: MXHistogram<UnitDuration>) -> Int {
        var tail = -1
        for case let bucket as MXHistogramBucket<UnitDuration> in histogram.bucketEnumerator {
            guard bucket.bucketCount > 0 else { continue }
            tail = Int(bucket.bucketEnd.converted(to: .milliseconds).value)
        }
        return tail
    }
}
#endif
