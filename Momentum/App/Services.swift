import Foundation
import SwiftUI

/// App-wide service container, injected via the SwiftUI environment.
///
/// Per PRD §17: constructor injection, app-wide services live here. The capture
/// engines (`GPSTrackingEngine`, `StrengthSessionEngine`) are *not* here — they are
/// per-session actors owned by their feature view models. This container holds the
/// long-lived, cross-cutting services.
///
/// Phase 0 ships these as protocol-typed stubs so the app compiles and the shape is
/// fixed; later phases swap in live implementations without touching call sites.
@MainActor
@Observable
final class Services {
    let location: any LocationServing
    let motion: any MotionServing
    let health: any HealthServing
    let plan: any PlanEngineServing
    let ai: any AIServing
    let sync: any SyncServing
    let paywall: any PaywallServing
    let notifications: any NotificationServing

    init(
        location: any LocationServing,
        motion: any MotionServing,
        health: any HealthServing,
        plan: any PlanEngineServing,
        ai: any AIServing,
        sync: any SyncServing,
        paywall: any PaywallServing,
        notifications: any NotificationServing
    ) {
        self.location = location
        self.motion = motion
        self.health = health
        self.plan = plan
        self.ai = ai
        self.sync = sync
        self.paywall = paywall
        self.notifications = notifications
    }

    /// The default wiring used by the running app.
    static func live() -> Services {
        Services(
            location: StubLocationService(),
            motion: StubMotionService(),
            health: StubHealthService(),
            plan: StubPlanEngine(),
            ai: StubAIService(),
            sync: StubSyncService(),
            paywall: StubPaywallService(),
            notifications: StubNotificationService()
        )
    }
}

// MARK: - Service protocols (contracts fixed in Phase 0)

protocol LocationServing: AnyObject { var isAuthorized: Bool { get } }
protocol MotionServing: AnyObject { var isAuthorized: Bool { get } }
protocol HealthServing: AnyObject { var isAuthorized: Bool { get } }
protocol PlanEngineServing: AnyObject {}
protocol AIServing: AnyObject {}
protocol SyncServing: AnyObject {}
protocol PaywallServing: AnyObject {
    /// Single source of truth for Pro gating (PRD §10). Stubbed true-for-dev in Phase 0.
    func isEntitled(to feature: Feature) -> Bool
}
protocol NotificationServing: AnyObject {}

// MARK: - Pro gating

/// The single `Feature` enum that is the source of truth for gating (PRD §10/§13.10).
enum Feature: String, CaseIterable, Sendable {
    case aiCoach, fullPlan, programs, aiRead, advancedAnalytics, fullHistory
    case allTemplates, allShareTemplates, cadenceMetronome, voiceCoach, watchPremium
}

// MARK: - Phase 0 stubs

final class StubLocationService: LocationServing { var isAuthorized = false }
final class StubMotionService: MotionServing { var isAuthorized = false }
final class StubHealthService: HealthServing { var isAuthorized = false }
final class StubPlanEngine: PlanEngineServing {}
final class StubAIService: AIServing {}
final class StubSyncService: SyncServing {}
final class StubNotificationService: NotificationServing {}
/// Dev stub: unlocks everything so feature work isn't blocked before Phase 3 wires RevenueCat.
final class StubPaywallService: PaywallServing {
    func isEntitled(to feature: Feature) -> Bool { true }
}
