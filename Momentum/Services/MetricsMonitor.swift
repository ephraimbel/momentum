import Foundation
import os
#if canImport(MetricKit)
import MetricKit
#endif

/// Crash + performance monitoring via Apple's on-device **MetricKit** (PRD §13.5) — no third-party
/// crash SDK, no PII. The system delivers a daily aggregated metrics payload and, on iOS 14+,
/// diagnostic payloads (crashes, hangs, disk-write exceptions, CPU exceptions). We summarize the
/// quality-bar signals (launch time, hang time, the count of crash diagnostics) into the unified log,
/// where they can be read locally or forwarded to a dashboard later.
///
/// Daily MetricKit payloads arrive at most once every 24h, and only on a physical device — this is a
/// no-op in the simulator. It's a singleton because `MXMetricManager` keeps a weak list of
/// subscribers; we register once at launch and never unregister.
final class MetricsMonitor: NSObject {
    static let shared = MetricsMonitor()
    private let logger = Logger(subsystem: "com.ephraimbel.momentum.app", category: "metrics")

    /// Register for MetricKit delivery. Safe to call once at app launch.
    func start() {
        #if canImport(MetricKit) && !targetEnvironment(simulator)
        MXMetricManager.shared.add(self)
        #endif
    }
}

#if canImport(MetricKit)
extension MetricsMonitor: MXMetricManagerSubscriber {
    /// Daily aggregated performance metrics (launch, hang, GPU, memory, …).
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            if let launch = payload.applicationLaunchMetrics {
                let p90 = launch.histogrammedTimeToFirstDraw.bucketEnumerator.allObjects.last
                logger.info("metric=app_launch ttfd_buckets=\(launch.histogrammedTimeToFirstDraw.totalBucketCount, privacy: .public) last=\(String(describing: p90), privacy: .public)")
            }
            if let responsiveness = payload.applicationResponsivenessMetrics {
                logger.info("metric=responsiveness hang_buckets=\(responsiveness.histogrammedApplicationHangTime.totalBucketCount, privacy: .public)")
            }
        }
    }

    /// Diagnostic payloads — crashes, hangs, CPU/disk exceptions (iOS 14+).
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            let cpuExceptions = payload.cpuExceptionDiagnostics?.count ?? 0
            if crashes + hangs + cpuExceptions > 0 {
                logger.error("diagnostic crashes=\(crashes, privacy: .public) hangs=\(hangs, privacy: .public) cpu=\(cpuExceptions, privacy: .public)")
            }
        }
    }
}
#endif
