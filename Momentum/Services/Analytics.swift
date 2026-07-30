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
    case spotsViewed(count: Int)
    case spotSelected(kind: String)
    /// A launch could not open the SwiftData store and moved it aside. Rare by construction and
    /// invisible without this event — the only signal that a shipped migration broke somebody's
    /// install. `recovered` is false when the store had to be removed to make the app launchable.
    case storeQuarantined(recovered: Bool)

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
        case .spotsViewed:       "spots_viewed"
        case .spotSelected:      "spot_selected"
        case .storeQuarantined:  "store_quarantined"
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
        case .spotsViewed(let n):              ["count": String(n)]
        case .spotSelected(let k):             ["kind": k]
        case .storeQuarantined(let r):         ["recovered": String(r)]
        }
    }
}

@MainActor
protocol AnalyticsServing: AnyObject {
    /// Record an event. Implementations must be non-blocking and privacy-preserving.
    func log(_ event: AnalyticsEvent)
    /// Push any buffered events now. Called when the app backgrounds — the last reliable moment to
    /// get a session off the device.
    func flush()
    /// The current north-star funnel status (PRD §13.5) for surfacing/debugging.
    func northStarStatus() -> NorthStarFunnel.Status
}

/// The default, privacy-preserving analytics service. Every event goes three places: the unified
/// log (local debugging), the on-device north-star funnel, and — since 2026-07-25 — `AnalyticsSink`,
/// which batches them to Supabase so the onboarding funnel and paywall view→convert rate are
/// actually measurable off-device. No third-party SDK; the sink is a no-op until Supabase is
/// configured, so an unconfigured build behaves exactly as it did before (log-only).
@MainActor
final class AnalyticsService: AnalyticsServing {
    private let logger = Logger(subsystem: "com.ephraimbel.momentum.app", category: "analytics")
    private let northStar: NorthStarTracker
    private let sink: AnalyticsSink?

    init(northStar: NorthStarTracker = NorthStarTracker(), sink: AnalyticsSink? = AnalyticsSink()) {
        self.northStar = northStar
        self.sink = sink
        northStar.markLaunch()   // start the 24h north-star window on first launch (idempotent)
        // Send anything the last run buffered but never got to flush.
        if let sink { Task { await sink.flush() } }
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

        if let sink {
            let name = event.name, parameters = event.parameters
            Task { await sink.enqueue(name: name, params: parameters) }
        }
    }

    /// Push whatever is buffered — call when the app backgrounds, which is the last reliable moment
    /// to get a session's events off the device.
    func flush() {
        guard let sink else { return }
        Task { await sink.flush() }
    }

    func northStarStatus() -> NorthStarFunnel.Status { northStar.status() }
}

/// No-op analytics for previews/tests that don't assert on instrumentation.
@MainActor
final class StubAnalyticsService: AnalyticsServing {
    func log(_ event: AnalyticsEvent) {}
    func flush() {}
    func northStarStatus() -> NorthStarFunnel.Status { .pending }
}
