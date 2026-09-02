import Testing
@testable import Momentum

struct SentryMonitorTests {
    @Test func blankAndBuildPlaceholdersKeepMonitoringDark() {
        #expect(SentryMonitor.configuration(from: ["SentryDSN": ""],
                                            environment: "test") == nil)
        #expect(SentryMonitor.configuration(from: ["SentryDSN": "$(SENTRY_DSN)"],
                                            environment: "test") == nil)
    }

    @Test func onlySecureSentryCloudDSNsAreAccepted() {
        let base: [String: Any] = [
            "CFBundleIdentifier": "com.example.app",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
        ]
        #expect(SentryMonitor.configuration(
            from: base.merging(["SentryDSN": "http://key@o1.ingest.sentry.io/2"]) { _, new in new },
            environment: "test") == nil)
        #expect(SentryMonitor.configuration(
            from: base.merging(["SentryDSN": "https://key@example.com/2"]) { _, new in new },
            environment: "test") == nil)

        let config = SentryMonitor.configuration(
            from: base.merging(["SentryDSN": "https://key@o1.ingest.us.sentry.io/2"]) { _, new in new },
            environment: "test")
        #expect(config?.releaseName == "com.example.app@1.2.3+42")
        #expect(config?.distribution == "42")
        #expect(config?.environment == "test")
    }

    @Test func issueTagsAreAllowlistedBoundedAndNeverCarryFreeformData() {
        let long = String(repeating: "x", count: 120)
        let result = SentryMonitor.sanitizedTags([
            "status": " 401 ",
            "error_code": " PGRST301 ",
            "byte_bucket": "under_32k",
            "auth_retried": "true",
            "placement": long,
            "email": "athlete@example.com",
            "route": "30.2,-97.7",
        ])
        #expect(result["status"] == "401")
        #expect(result["error_code"] == "PGRST301")
        #expect(result["byte_bucket"] == "under_32k")
        #expect(result["auth_retried"] == "true")
        #expect(result["placement"]?.count == 80)
        #expect(result["email"] == nil)
        #expect(result["route"] == nil)
    }
}
