import Foundation
#if canImport(Sentry)
import Sentry
#endif

/// Privacy-locked production diagnostics on Sentry's $0 Developer plan.
///
/// This is intentionally NOT product analytics. Supabase owns conversion funnels; Sentry owns
/// crash/hang diagnosis and a very small set of handled operational failures. No identity is ever
/// assigned, and only `AnalyticsEvent`'s already-reviewed non-PII dimensions become breadcrumbs.
enum SentryMonitor {
    enum Issue: String, Sendable {
        case storeQuarantined = "swiftdata_store_quarantined"
        case syncEncodingFailed = "workout_sync_encoding_failed"
        case syncRejected = "workout_sync_rejected"
        case syncUnauthorized = "workout_sync_unauthorized"
        case syncPayloadRejected = "workout_sync_payload_rejected"
        case storePricingUnavailable = "store_pricing_unavailable"
        case storePurchaseFailed = "store_purchase_failed"
    }

    struct Configuration: Equatable, Sendable {
        let dsn: String
        let releaseName: String
        let distribution: String
        let environment: String
    }

    /// Only bounded, non-PII operational dimensions can become searchable Sentry tags.
    private static let allowedTagKeys: Set<String> = [
        "auth_retried", "byte_bucket", "count_bucket", "error_code", "placement", "product",
        "recovered", "status",
    ]

    static func configure(bundle: Bundle = .main,
                          arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if canImport(Sentry)
        #if DEBUG
        // Unit/UI tests and ordinary simulator launches never consume quota or create noise.
        guard arguments.contains("--enable-sentry") else { return }
        let environment = "development"
        #else
        let environment = "production"
        #endif

        guard let configuration = configuration(from: bundle.infoDictionary ?? [:],
                                                environment: environment) else { return }

        SentrySDK.start { options in
            options.dsn = configuration.dsn
            options.releaseName = configuration.releaseName
            options.dist = configuration.distribution
            options.environment = configuration.environment
            options.debug = false

            // Core error monitoring: all low-volume errors, crashes, hangs and watchdog exits.
            options.sampleRate = 1
            options.enableCrashHandler = true
            options.enableAppHangTracking = true
            options.enableWatchdogTerminationTracking = true
            options.enableAutoSessionTracking = true
            options.attachStacktrace = true

            // Privacy + free-tier budget: every high-volume or content-bearing feature is off.
            options.sendDefaultPii = false
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.enableMemoryIntrospection = false
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            options.enableNetworkTracking = false
            options.enableAutoPerformanceTracing = false
            options.enableUIViewControllerTracing = false
            options.enableUserInteractionTracing = false
            options.enableFileIOTracing = false
            options.enableCoreDataTracing = false
            options.tracesSampleRate = nil
            options.sessionReplay.sessionSampleRate = 0
            options.sessionReplay.onErrorSampleRate = 0
            options.enableLogs = false

            // Momentum already summarizes MetricKit locally and forwards only aggregate counts to
            // Supabase. Do not send its raw diagnostic payload a second time through Sentry.
            options.enableMetricKit = false
            options.enableMetricKitRawPayload = false
            options.maxBreadcrumbs = 40
        }
        #endif
    }

    /// Static issue names + an allowlisted set of short tags; never forward Error descriptions,
    /// URLs, response bodies, workout values or user-authored text.
    static func capture(_ issue: Issue, tags: [String: String] = [:]) {
        #if canImport(Sentry)
        guard SentrySDK.isEnabled else { return }
        let safe = sanitizedTags(tags)
        SentrySDK.capture(message: issue.rawValue) { scope in
            scope.setLevel(.error)
            for (key, value) in safe { scope.setTag(value: value, key: key) }
        }
        #endif
    }

    /// Existing analytics events are non-PII by construction. Keeping only those hand-authored
    /// breadcrumbs makes a crash trace useful while avoiding UI text, URLs and network bodies.
    static func addBreadcrumb(_ event: AnalyticsEvent) {
        #if canImport(Sentry)
        guard SentrySDK.isEnabled else { return }
        let crumb = Breadcrumb(level: .info, category: "app.event")
        crumb.message = event.name
        for (key, value) in event.parameters {
            crumb.setData(value: String(value.prefix(80)), key: key)
        }
        SentrySDK.addBreadcrumb(crumb)
        #endif
    }

    static func configuration(from info: [String: Any], environment: String) -> Configuration? {
        guard let raw = info["SentryDSN"] as? String else { return nil }
        let dsn = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dsn.isEmpty, !dsn.contains("$("), let url = URL(string: dsn),
              url.scheme == "https", let host = url.host?.lowercased(),
              host == "sentry.io" || host.hasSuffix(".sentry.io"),
              url.user != nil else { return nil }

        let version = (info["CFBundleShortVersionString"] as? String).flatMap(nonEmpty) ?? "0"
        let build = (info["CFBundleVersion"] as? String).flatMap(nonEmpty) ?? "0"
        let bundleID = (info["CFBundleIdentifier"] as? String).flatMap(nonEmpty)
            ?? "com.ephraimbel.momentum.app"
        return Configuration(dsn: dsn,
                             releaseName: "\(bundleID)@\(version)+\(build)",
                             distribution: build,
                             environment: environment)
    }

    static func sanitizedTags(_ tags: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: tags.compactMap { key, value in
            guard allowedTagKeys.contains(key) else { return nil }
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            return (key, String(cleaned.prefix(80)))
        })
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
