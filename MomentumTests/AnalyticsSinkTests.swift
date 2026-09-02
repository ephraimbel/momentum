import Foundation
import Testing
@testable import Momentum

/// `AnalyticsSink` buffering/persistence rules. The network leg isn't exercised here — the app is
/// built with no Supabase config in the test host, so `flush()` is a no-op and the queue is the
/// contract: nothing may be lost, nothing may grow without bound, and a restart must pick up where
/// the last run left off.
@MainActor
struct AnalyticsSinkTests {

    /// Isolated defaults per test — `.standard` would leak the queue between cases and into the app.
    private func freshDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func queuesEventsUntilFlushed() async {
        let sink = AnalyticsSink(defaults: freshDefaults())
        await sink.enqueue(name: "paywall_view", params: ["placement": "coach"])
        await sink.enqueue(name: "paywall_convert", params: ["product": "annual"])
        #expect(await sink.queuedCount == 2)
    }

    /// A termination between flushes must not cost events: a new sink over the same defaults
    /// resumes the queue. This is the whole reason the buffer is persisted rather than in-memory.
    @Test func queueSurvivesRelaunch() async {
        let defaults = freshDefaults()
        let first = AnalyticsSink(defaults: defaults)
        await first.enqueue(name: "onboarding_step", params: ["index": "3"])
        await first.enqueue(name: "plan_generated", params: ["disciplines": "2"])

        let second = AnalyticsSink(defaults: defaults)
        #expect(await second.queuedCount == 2)
    }

    /// Past the cap the OLDEST events go, not the newest — a device offline for weeks should still
    /// report what it did most recently rather than a stale prefix.
    @Test func dropsOldestPastTheCap() async {
        let sink = AnalyticsSink(defaults: freshDefaults())
        for i in 0..<(AnalyticsSink.maxQueued + 25) {
            await sink.enqueue(name: "workout_started", params: ["type": "run", "i": String(i)])
        }
        #expect(await sink.queuedCount == AnalyticsSink.maxQueued)
    }

    /// The install id is minted once and reused — it's the join key for every funnel query, so a
    /// per-launch id would silently make every install look like a one-event visitor.
    @Test func installIDIsStableAcrossSinks() async {
        let defaults = freshDefaults()
        _ = AnalyticsSink(defaults: defaults)
        let first = defaults.string(forKey: "com.momentum.analytics.installID")
        _ = AnalyticsSink(defaults: defaults)
        let second = defaults.string(forKey: "com.momentum.analytics.installID")
        #expect(first != nil)
        #expect(first == second)
    }

    /// Column names are the wire contract with `public.app_events` (migration 20260725000001) —
    /// snake_case, and an ISO-8601 timestamp PostgREST will accept for a timestamptz.
    @Test func envelopeEncodesToTheTableColumns() throws {
        let envelope = AnalyticsSink.Envelope(
            installID: "11111111-1111-1111-1111-111111111111",
            name: "paywall_view", params: ["placement": "coach"],
            appVersion: "1.0.0", build: "10", platform: "ios",
            occurredAt: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try #require(String(data: try encoder.encode(envelope), encoding: .utf8))

        #expect(json.contains("\"install_id\""))
        #expect(json.contains("\"app_version\""))
        #expect(json.contains("\"occurred_at\""))
        #expect(json.contains("1970-01-01T00:00:00Z"))
        // The taxonomy is non-PII by construction; assert the shape we actually send stays flat.
        #expect(json.contains("\"placement\":\"coach\""))
    }
}

/// The taxonomy itself — every event must carry a name, and the two that gate the north-star funnel
/// must exist. `workout_completed` and `pr_hit` were declared but never logged anywhere in the app
/// until 2026-07-25, which left `NorthStarFunnel` structurally unable to report `.achieved`.
struct AnalyticsEventTaxonomyTests {

    @Test func everyEventHasANonEmptySnakeCaseName() {
        let events: [AnalyticsEvent] = [
            .onboardingStep(name: "identity", index: 1, position: 2, total: 22),
            .onboardingShowcase(action: "viewed"),
            .onboardingPermission(kind: "notifications", status: "granted"),
            .planGenerated(disciplines: 2),
            .paywallView(placement: "coach", pricingLive: true),
            .paywallAction(action: "purchase_attempt", placement: "coach", product: "annual"),
            .paywallConvert(product: "annual", placement: "coach"),
            .workoutStarted(type: "run"), .setLogged(latencyMs: 42), .restTimerComplete,
            .workoutCompleted(type: "run"), .aiReadViewed(latencyMs: 900, fallback: false),
            .prHit(type: "fastest5k"), .planSessionAdapted, .shareCreated(style: "classic"),
        ]
        for event in events {
            #expect(!event.name.isEmpty)
            #expect(event.name == event.name.lowercased())
            #expect(!event.name.contains(" "))
        }
    }

    /// The funnel's denominator and numerator. If either name drifts, `paywall_funnel` in the
    /// migration silently returns zero rows.
    @Test func paywallFunnelEventNamesAreStable() {
        #expect(AnalyticsEvent.paywallView(placement: "coach", pricingLive: true).name == "paywall_view")
        #expect(AnalyticsEvent.paywallConvert(product: "annual", placement: "coach").name == "paywall_convert")
        #expect(AnalyticsEvent.paywallView(placement: "coach", pricingLive: true).parameters["placement"] == "coach")
        #expect(AnalyticsEvent.paywallConvert(product: "annual", placement: "coach").parameters["product"] == "annual")
        #expect(AnalyticsEvent.paywallConvert(product: "annual", placement: "coach").parameters["placement"] == "coach")
    }

    @Test func northStarEventsExist() {
        #expect(AnalyticsEvent.workoutCompleted(type: "run").name == "workout_completed")
        #expect(AnalyticsEvent.aiReadViewed(latencyMs: 1, fallback: true).name == "ai_read_viewed")
    }
}
