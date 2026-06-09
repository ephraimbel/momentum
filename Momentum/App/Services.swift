import Foundation
import SwiftUI
import SwiftData

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
    let athleteModel: any AthleteModelServing

    init(
        location: any LocationServing,
        motion: any MotionServing,
        health: any HealthServing,
        plan: any PlanEngineServing,
        ai: any AIServing,
        sync: any SyncServing,
        paywall: any PaywallServing,
        notifications: any NotificationServing,
        athleteModel: any AthleteModelServing
    ) {
        self.location = location
        self.motion = motion
        self.health = health
        self.plan = plan
        self.ai = ai
        self.sync = sync
        self.paywall = paywall
        self.notifications = notifications
        self.athleteModel = athleteModel
    }

    /// The default wiring used by the running app.
    static func live() -> Services {
        Services(
            location: LocationService(),
            motion: MotionService(),
            health: StubHealthService(),
            plan: StubPlanEngine(),
            ai: AIService(),
            sync: StubSyncService(),
            paywall: StubPaywallService(),
            notifications: StubNotificationService(),
            athleteModel: AthleteModelService()
        )
    }
}

// MARK: - Service protocols (contracts fixed in Phase 0)

@MainActor
protocol LocationServing: AnyObject {
    var isAuthorized: Bool { get }
    func requestAuthorization()
    /// Live stream of raw fixes; the engine's `GPSProcessor` applies the accept gate.
    func fixes() -> AsyncStream<GPSProcessor.Fix>
    func stop()
}

@MainActor
protocol MotionServing: AnyObject {
    var isAuthorized: Bool { get }
    func requestAuthorization()
    func start()
    func stop()
    var cadenceStepsPerMin: Int? { get }
    var elevationGainM: Double { get }
}

protocol HealthServing: AnyObject { var isAuthorized: Bool { get } }
protocol PlanEngineServing: AnyObject {}
protocol SyncServing: AnyObject {}

@MainActor
protocol AIServing: AnyObject {
    /// The post-workout read (PRD §8.8). Tries the server Edge Function when configured; always
    /// falls back to the deterministic template so the moment never blocks.
    func workoutRead(for workout: Workout, planned: Bool,
                     weightUnit: WeightUnit, distanceUnit: DistanceUnit) async -> WorkoutRead
}
protocol PaywallServing: AnyObject {
    /// Single source of truth for Pro gating (PRD §10). Stubbed true-for-dev in Phase 0.
    func isEntitled(to feature: Feature) -> Bool
}
protocol NotificationServing: AnyObject {}

@MainActor
protocol AthleteModelServing: AnyObject {
    /// Recompute Tier A facts from the profile's history and persist them onto its `AthleteModel`,
    /// upserting this week's `FitnessSnapshot` (see `docs/ATHLETE-MODEL.md`). Pure-local; never blocks.
    func ingest(profile: UserProfile, in context: ModelContext, now: Date)
    /// Seed initial memory notes from onboarding answers. Idempotent.
    func seedOnboarding(for profile: UserProfile, in context: ModelContext)
}

extension AthleteModelServing {
    func ingest(profile: UserProfile, in context: ModelContext) {
        ingest(profile: profile, in: context, now: Date())
    }
}

// MARK: - Pro gating

/// The single `Feature` enum that is the source of truth for gating (PRD §10/§13.10).
enum Feature: String, CaseIterable, Sendable {
    case aiCoach, fullPlan, programs, aiRead, advancedAnalytics, fullHistory
    case allTemplates, allShareTemplates, cadenceMetronome, voiceCoach, watchPremium
}

// MARK: - Phase 0 stubs

final class StubLocationService: LocationServing {
    var isAuthorized = false
    func requestAuthorization() {}
    func fixes() -> AsyncStream<GPSProcessor.Fix> { AsyncStream { $0.finish() } }
    func stop() {}
}
final class StubMotionService: MotionServing {
    var isAuthorized = false
    var cadenceStepsPerMin: Int? = nil
    var elevationGainM: Double = 0
    func requestAuthorization() {}
    func start() {}
    func stop() {}
}
final class StubHealthService: HealthServing { var isAuthorized = false }
final class StubPlanEngine: PlanEngineServing {}
final class StubSyncService: SyncServing {}
final class StubNotificationService: NotificationServing {}
/// No-op Athlete Model service for previews/tests that don't exercise learning.
final class StubAthleteModelService: AthleteModelServing {
    func ingest(profile: UserProfile, in context: ModelContext, now: Date) {}
    func seedOnboarding(for profile: UserProfile, in context: ModelContext) {}
}
/// Dev stub: unlocks everything so feature work isn't blocked before Phase 3 wires RevenueCat.
final class StubPaywallService: PaywallServing {
    func isEntitled(to feature: Feature) -> Bool { true }
}
