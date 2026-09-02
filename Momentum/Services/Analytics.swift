import Foundation
import os

/// The privacy-preserving analytics event taxonomy (PRD §13.5). Event names are the exact strings
/// from the PRD; payloads carry **only** non-PII dimensions (discipline string, counts, latency in
/// ms, booleans) — never routes, names, locations, or health values, per the §13.3 privacy rule
/// (no health-data-exfiltrating analytics, no ad SDKs).
enum AnalyticsEvent: Equatable {
    /// A cold launch. `first` is true on the very first launch of this install — which makes it the
    /// **true install denominator**, the thing every funnel view was missing (2026-08-22). Until
    /// this existed the first event of any kind was the first `onboarding_step`, so an athlete who
    /// opened the app, looked at the welcome and left fired NOTHING: they weren't a drop-off in the
    /// funnel, they weren't even an install. That is the exact shape of a cold ad click, so paid
    /// traffic was leaking out of a door we could not see.
    case appLaunched(first: Bool)
    /// What happened at the welcome gate — the screen before `onboarding_step(0)`. Pair with
    /// `app_launched(first=true)`: installs that fired the launch but never a welcome action are
    /// the athletes who bounced at the door.
    case welcomeAction(action: String)
    /// `index` preserves the enum's historical raw value; `position` is the athlete's actual
    /// one-based position in their branched flow. The human-readable name makes funnel reports
    /// resilient when steps are reordered without changing those historical raw values.
    case onboardingStep(name: String, index: Int, position: Int, total: Int)
    case onboardingShowcase(action: String)
    case onboardingPermission(kind: String, status: String)
    case planGenerated(disciplines: Int)
    case paywallView(placement: String, pricingLive: Bool)
    case paywallAction(action: String, placement: String, product: String)
    case paywallConvert(product: String, placement: String)
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
    /// A workout upload batch was rejected by the server (non-2xx). Distinct from being offline,
    /// which is normal and uncounted: this is the shape of failure that stays stuck — a 413 from an
    /// oversized body, a 401 from an expired session, a 4xx from an RLS rule. Without it, an athlete
    /// whose history stopped backing up looks identical to one who simply hasn't opened the app.
    case syncFailed(status: Int)
    /// A MetricKit diagnostic day: crashes, hangs, and CPU exceptions the system observed on this
    /// install. Counts only — no stack frames, no addresses, nothing identifying. This is how the
    /// >99.5% crash-free quality bar (PRD §22) becomes a number somebody can actually read; before
    /// it existed the payloads went to `os_log` on the device and stopped there.
    case appDiagnostics(crashes: Int, hangs: Int, cpuExceptions: Int)
    /// The daily aggregated launch/responsiveness histogram, reduced to its p90-ish tail bucket.
    /// `-1` means the payload carried no histogram for that metric.
    case appPerformance(launchMs: Int, hangMs: Int)

    /// The canonical event name (PRD §13.5).
    var name: String {
        switch self {
        case .appLaunched:       "app_launched"
        case .welcomeAction:     "welcome_action"
        case .onboardingStep:    "onboarding_step"
        case .onboardingShowcase:"onboarding_showcase"
        case .onboardingPermission:"onboarding_permission"
        case .planGenerated:     "plan_generated"
        case .paywallView:       "paywall_view"
        case .paywallAction:     "paywall_action"
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
        case .syncFailed:        "sync_failed"
        case .appDiagnostics:    "app_diagnostics"
        case .appPerformance:    "app_performance"
        }
    }

    /// Non-PII dimensions for this event.
    var parameters: [String: String] {
        switch self {
        case .appLaunched(let first):          ["first": String(first)]
        case .welcomeAction(let a):            ["action": a]
        case .onboardingStep(let n, let i, let p, let t):
            ["step": n, "index": String(i), "position": String(p), "total": String(t)]
        case .onboardingShowcase(let a):       ["action": a]
        case .onboardingPermission(let k, let s): ["kind": k, "status": s]
        case .planGenerated(let d):            ["disciplines": String(d)]
        case .paywallView(let p, let live):    ["placement": p, "pricing_live": String(live)]
        case .paywallAction(let a, let p, let product):
            ["action": a, "placement": p, "product": product]
        case .paywallConvert(let product, let placement):
            ["product": product, "placement": placement]
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
        case .syncFailed(let status):          ["status": String(status)]
        case .appDiagnostics(let c, let h, let x): ["crashes": String(c), "hangs": String(h),
                                                   "cpu_exceptions": String(x)]
        case .appPerformance(let launch, let hang): ["launch_ms": String(launch),
                                                    "hang_ms": String(hang)]
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

/// The default, privacy-preserving analytics service. Every event goes to the unified log, the
/// on-device north-star funnel, Supabase, and a memory-only Sentry breadcrumb when configured.
/// The breadcrumb is the same deliberately non-PII event name/dimensions already sent to Supabase;
/// it gives a later crash useful navigation context without enabling Sentry's automatic UI/network
/// breadcrumb collectors.
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
        // Read the first-launch stamp BEFORE `markLaunch` writes it — that ordering is the whole
        // trick behind `first`, and swapping these two lines makes every launch look like a repeat.
        let isFirstLaunch = northStar.funnel.firstLaunch == nil
        northStar.markLaunch()   // start the 24h north-star window on first launch (idempotent)
        // Send anything the last run buffered but never got to flush.
        if let sink { Task { await sink.flush() } }
        // The install denominator. Logged here rather than in a view because it must fire even when
        // the athlete never reaches a screen that is instrumented — which was precisely the bug.
        log(.appLaunched(first: isFirstLaunch))
    }

    func log(_ event: AnalyticsEvent) {
        // Event names + dimensions are non-PII, so logging them publicly is safe and useful in dev.
        let params = event.parameters.map { "\($0)=\($1)" }.sorted().joined(separator: " ")
        logger.info("event=\(event.name, privacy: .public) \(params, privacy: .public)")
        SentryMonitor.addBreadcrumb(event)

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
