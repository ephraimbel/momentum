import Testing
import Foundation
@testable import Momentum

/// The analytics event taxonomy (PRD §13.5) — names must match the PRD exactly and payloads must be
/// non-PII (the §13.3 privacy rule). Pure value mapping, so fully unit-testable.
struct AnalyticsEventTests {

    @Test func eventNamesMatchPRDTaxonomy() {
        #expect(AnalyticsEvent.appLaunched(first: true).name == "app_launched")
        #expect(AnalyticsEvent.welcomeAction(action: "get_started").name == "welcome_action")
        #expect(AnalyticsEvent.onboardingStep(name: "name", index: 0, position: 1, total: 22).name == "onboarding_step")
        #expect(AnalyticsEvent.onboardingShowcase(action: "viewed").name == "onboarding_showcase")
        #expect(AnalyticsEvent.onboardingPermission(kind: "location", status: "granted").name == "onboarding_permission")
        #expect(AnalyticsEvent.planGenerated(disciplines: 2).name == "plan_generated")
        #expect(AnalyticsEvent.paywallView(placement: "ai_read", pricingLive: true).name == "paywall_view")
        #expect(AnalyticsEvent.paywallAction(action: "purchase_attempt", placement: "ai_read", product: "annual").name == "paywall_action")
        #expect(AnalyticsEvent.paywallConvert(product: "annual", placement: "full_plan").name == "paywall_convert")
        #expect(AnalyticsEvent.workoutStarted(type: "run").name == "workout_started")
        #expect(AnalyticsEvent.setLogged(latencyMs: 12).name == "set_logged")
        #expect(AnalyticsEvent.restTimerComplete.name == "rest_timer_complete")
        #expect(AnalyticsEvent.workoutCompleted(type: "run").name == "workout_completed")
        #expect(AnalyticsEvent.aiReadViewed(latencyMs: 30, fallback: true).name == "ai_read_viewed")
        #expect(AnalyticsEvent.prHit(type: "strength").name == "pr_hit")
        #expect(AnalyticsEvent.planSessionAdapted.name == "plan_session_adapted")
        #expect(AnalyticsEvent.shareCreated(style: "Story").name == "share_created")
    }

    @Test func parametersCarryOnlyNonPIIDimensions() {
        #expect(AnalyticsEvent.workoutStarted(type: "trailRun").parameters == ["type": "trailRun"])
        #expect(AnalyticsEvent.aiReadViewed(latencyMs: 420, fallback: false).parameters
                == ["latency_ms": "420", "fallback": "false"])
        #expect(AnalyticsEvent.paywallConvert(product: "weekly", placement: "fuel_locked").parameters
                == ["product": "weekly", "placement": "fuel_locked"])
        #expect(AnalyticsEvent.restTimerComplete.parameters.isEmpty)
        #expect(AnalyticsEvent.planSessionAdapted.parameters.isEmpty)
        // The install denominator: `first` must serialize as the literal the funnel views filter on
        // (`params->>'first' = 'true'`), so a change to Bool's description would break the read side.
        #expect(AnalyticsEvent.appLaunched(first: true).parameters == ["first": "true"])
        #expect(AnalyticsEvent.appLaunched(first: false).parameters == ["first": "false"])
        #expect(AnalyticsEvent.welcomeAction(action: "get_started").parameters
                == ["action": "get_started"])
        #expect(AnalyticsEvent.onboardingStep(name: "notifications", index: 23, position: 20, total: 24).parameters
                == ["step": "notifications", "index": "23", "position": "20", "total": "24"])
        #expect(AnalyticsEvent.paywallView(placement: "full_plan", pricingLive: false).parameters
                == ["placement": "full_plan", "pricing_live": "false"])
        #expect(AnalyticsEvent.onboardingPermission(kind: "notifications", status: "skipped").parameters
                == ["kind": "notifications", "status": "skipped"])
    }
}

/// The north-star funnel (PRD §13.5): a new user is "achieved" only when they complete a first
/// workout AND view the AI read, both within 24h of first launch.
struct NorthStarTests {
    private let launch = Date(timeIntervalSince1970: 1_000_000)
    private func hours(_ h: Double) -> Date { launch.addingTimeInterval(h * 3600) }

    @Test func pendingWithoutFirstLaunch() {
        let f = NorthStarFunnel(firstLaunch: nil, firstWorkout: nil, firstAIRead: nil)
        #expect(f.status(now: launch) == .pending)
    }

    @Test func achievedWhenBothWithin24h() {
        let f = NorthStarFunnel(firstLaunch: launch, firstWorkout: hours(2), firstAIRead: hours(3))
        #expect(f.status(now: hours(4)) == .achieved)
    }

    @Test func pendingWhileInsideWindowAndIncomplete() {
        let f = NorthStarFunnel(firstLaunch: launch, firstWorkout: hours(2), firstAIRead: nil)
        #expect(f.status(now: hours(5)) == .pending)   // still time to view the read
    }

    @Test func missedWhenWindowClosesIncomplete() {
        let f = NorthStarFunnel(firstLaunch: launch, firstWorkout: hours(2), firstAIRead: nil)
        #expect(f.status(now: hours(25)) == .missed)
    }

    @Test func missedWhenAMilestoneLandsAfterTheWindow() {
        // Workout in-window but the read came too late → never achieved.
        let f = NorthStarFunnel(firstLaunch: launch, firstWorkout: hours(1), firstAIRead: hours(30))
        #expect(f.status(now: hours(31)) == .missed)
    }

    @Test @MainActor func trackerStampsEachMilestoneOnce() {
        let suite = "northstar.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let tracker = NorthStarTracker(defaults: defaults)
        tracker.markLaunch(now: launch)
        tracker.markFirstWorkout(now: hours(1))
        tracker.markFirstWorkout(now: hours(2))   // ignored — first stamp wins
        tracker.markFirstAIRead(now: hours(3))

        #expect(tracker.funnel.firstLaunch == launch)
        #expect(tracker.funnel.firstWorkout == hours(1))
        #expect(tracker.status(now: hours(4)) == .achieved)
    }
}
