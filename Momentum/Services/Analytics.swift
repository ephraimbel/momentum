import Foundation
import os

/// The privacy-preserving analytics event taxonomy (PRD §13.5). Event names are the exact strings
/// from the PRD; payloads carry **only** non-PII dimensions (discipline string, counts, latency in
/// ms, booleans) — never routes, names, locations, or health values, per the §13.3 privacy rule
/// (no health-data-exfiltrating analytics, no ad SDKs).
enum AnalyticsEvent: Equatable {
    case onboardingStep(index: Int)
    case planGenerated(disciplines: Int)
    case paywallView(placement: String)
    case paywallConvert(product: String)
    case workoutStarted(type: String)
    case setLogged(latencyMs: Int)
    case restTimerComplete
    case workoutCompleted(type: String)
    case aiReadViewed(latencyMs: Int, fallback: Bool)
    case prHit(type: String)
    case planSessionAdapted
    case shareCreated(style: String)

    /// The canonical event name (PRD §13.5).
    var name: String {
        switch self {
        case .onboardingStep:    "onboarding_step"
        case .planGenerated:     "plan_generated"
        case .paywallView:       "paywall_view"
        case .paywallConvert:    "paywall_convert"
        case .workoutStarted:    "workout_started"
        case .setLogged:         "set_logged"
        case .restTimerComplete: "rest_timer_complete"
        case .workoutCompleted:  "workout_completed"
        case .aiReadViewed:      "ai_read_viewed"
        case .prHit:             "pr_hit"
        case .planSessionAdapted:"plan_session_adapted"
        case .shareCreated:      "share_created"
        }
    }

    /// Non-PII dimensions for this event.
    var parameters: [String: String] {
        switch self {
        case .onboardingStep(let i):           ["index": String(i)]
        case .planGenerated(let d):            ["disciplines": String(d)]
        case .paywallView(let p):              ["placement": p]
        case .paywallConvert(let p):           ["product": p]
        case .workoutStarted(let t):           ["type": t]
        case .setLogged(let ms):               ["latency_ms": String(ms)]
        case .restTimerComplete:               [:]
        case .workoutCompleted(let t):         ["type": t]
        case .aiReadViewed(let ms, let fb):    ["latency_ms": String(ms), "fallback": String(fb)]
        case .prHit(let t):                    ["type": t]
        case .planSessionAdapted:              [:]
        case .shareCreated(let s):             ["style": s]
        }
    }
}

@MainActor
protocol AnalyticsServing: AnyObject {
    /// Record an event. Implementations must be non-blocking and privacy-preserving.
    func log(_ event: AnalyticsEvent)
    /// The current north-star funnel status (PRD §13.5) for surfacing/debugging.
    func northStarStatus() -> NorthStarFunnel.Status
}

/// The default, privacy-preserving analytics sink. Events stream to the unified log (os.Logger) for
/// local debugging and feed the on-device north-star funnel. There is **no** third-party SDK and no
/// network egress here — a Supabase `analytics_events` forwarder (owner-scoped, non-PII) can layer on
/// top later behind config, exactly like `SyncService` (see docs/SYNC-SETUP.md).
@MainActor
final class AnalyticsService: AnalyticsServing {
    private let logger = Logger(subsystem: "com.momentum.app", category: "analytics")
    private let northStar: NorthStarTracker

    init(northStar: NorthStarTracker = NorthStarTracker()) {
        self.northStar = northStar
        northStar.markLaunch()   // start the 24h north-star window on first launch (idempotent)
    }

    func log(_ event: AnalyticsEvent) {
        // Event names + dimensions are non-PII, so logging them publicly is safe and useful in dev.
        let params = event.parameters.map { "\($0)=\($1)" }.sorted().joined(separator: " ")
        logger.info("event=\(event.name, privacy: .public) \(params, privacy: .public)")

        // Advance the north-star funnel on its two defining milestones.
        switch event {
        case .workoutCompleted: northStar.markFirstWorkout()
        case .aiReadViewed:     northStar.markFirstAIRead()
        default: break
        }
    }

    func northStarStatus() -> NorthStarFunnel.Status { northStar.status() }
}

/// No-op analytics for previews/tests that don't assert on instrumentation.
@MainActor
final class StubAnalyticsService: AnalyticsServing {
    func log(_ event: AnalyticsEvent) {}
    func northStarStatus() -> NorthStarFunnel.Status { .pending }
}
