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

    /// The default wiring used by the running app. The real app injects the live `PaywallController`
    /// (so `services.paywall` and `@Environment(PaywallController.self)` are the same instance);
    /// previews/tests fall back to the unlock-all stub so feature surfaces stay visible.
    static func live(paywall: any PaywallServing = StubPaywallService()) -> Services {
        Services(
            location: LocationService(),
            motion: MotionService(),
            health: HealthService(),
            plan: StubPlanEngine(),
            ai: AIService(),
            sync: SyncService(),
            paywall: paywall,
            notifications: NotificationService(),
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

@MainActor
protocol HealthServing: AnyObject {
    var isAuthorized: Bool { get }
    /// Request Health read/write permission (opt-in). Returns whether workout-sharing is granted.
    func requestAuthorization() async -> Bool
    /// Save a completed workout to Apple Health (best-effort, de-duplicated, never blocks).
    func save(_ workout: Workout) async
    /// Read the athlete's latest body mass + resting HR (for personalizing estimates). nils if N/A.
    func importedBodyMetrics() async -> (bodyMassKg: Double?, restingHR: Int?)
}
protocol PlanEngineServing: AnyObject {}
@MainActor
protocol SyncServing: AnyObject {
    /// Push dirty (never-synced) workouts to the cloud and stamp them synced (PRD §8.9). No-op until
    /// Supabase is configured.
    func sync(_ workouts: [Workout], in context: ModelContext) async
}

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
@MainActor
protocol NotificationServing: AnyObject {
    /// Ask for local-notification permission (once; no-op if already determined).
    func requestAuthorization()
    /// Resync next-workout reminders to the plan's upcoming sessions (each carries its prescription).
    func schedulePlannedReminders(_ plan: TrainingPlan?)
    /// An immediate, encouraging nudge when the coach adapts the plan.
    func notifyPlanUpdated(title: String, body: String)
    /// The repeating Sunday week-in-review nudge (PRD §24).
    func scheduleWeeklyCheckIn()
    /// A gentle, ≤1/day streak-protection nudge when a real streak is at risk on a planned day (§24).
    func scheduleStreakNudge(streak: Int, isPlannedDayToday: Bool, hasWorkedOutToday: Bool)
}

@MainActor
protocol AthleteModelServing: AnyObject {
    /// Recompute Tier A facts from the profile's history and persist them onto its `AthleteModel`,
    /// upserting this week's `FitnessSnapshot` (see `docs/ATHLETE-MODEL.md`). Pure-local; never blocks.
    func ingest(profile: UserProfile, in context: ModelContext, now: Date)
    /// Seed initial memory notes from onboarding answers. Idempotent.
    func seedOnboarding(for profile: UserProfile, in context: ModelContext)
    /// Record a user correction as a pinned note (the AI must honor it; never auto-retired).
    /// Replaces any existing active pinned user note in the same category.
    func addCorrection(_ text: String, category: MemoryCategory, for profile: UserProfile, in context: ModelContext)
    /// "Forget this" — soft-retire a note so it's no longer surfaced or sent (kept for audit).
    func forget(noteID: UUID, in context: ModelContext)
}

extension AthleteModelServing {
    func ingest(profile: UserProfile, in context: ModelContext) {
        ingest(profile: profile, in: context, now: Date())
    }
}

// MARK: - Pro gating

/// The single `Feature` enum that is the source of truth for gating (PRD §10/§13.10). Everything
/// listed here is a **Pro** capability; "free" is everything else (track all disciplines, basic
/// summaries, manual logging + full library, limited history, the week-1 plan glimpse, basic share).
enum Feature: String, CaseIterable, Sendable, Identifiable {
    case aiCoach, fullPlan, programs, aiRead, advancedAnalytics, fullHistory
    case allTemplates, allShareTemplates, cadenceMetronome, voiceCoach, watchPremium

    var id: String { rawValue }

    /// All current features require Pro (the enum only lists paid capabilities). Kept explicit so a
    /// future free-tier feature can opt out without touching every call site.
    var requiresPro: Bool { true }

    /// The Superwall placement to fire when this locked feature is reached (PRD §10). A later slice
    /// registers these with the SDK for A/B-tested paywalls; the value is the source of truth now.
    var placement: String {
        switch self {
        case .aiRead: "ai_read"
        case .advancedAnalytics: "analytics_locked"
        case .fullHistory: "history_locked"
        case .aiCoach, .fullPlan, .programs, .allTemplates,
             .allShareTemplates, .cadenceMetronome, .voiceCoach, .watchPremium: "full_plan"
        }
    }

    /// Short, human name for the locked surface — used in the paywall's contextual headline.
    var displayName: String {
        switch self {
        case .aiCoach: "the AI coach"
        case .fullPlan: "your full plan"
        case .programs: "programs"
        case .aiRead: "AI reads"
        case .advancedAnalytics: "advanced analytics"
        case .fullHistory: "your full history"
        case .allTemplates: "all templates"
        case .allShareTemplates: "every share style"
        case .cadenceMetronome: "the cadence metronome"
        case .voiceCoach: "the voice coach"
        case .watchPremium: "Watch premium"
        }
    }
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
final class StubHealthService: HealthServing {
    var isAuthorized = false
    func requestAuthorization() async -> Bool { false }
    func save(_ workout: Workout) async {}
    func importedBodyMetrics() async -> (bodyMassKg: Double?, restingHR: Int?) { (nil, nil) }
}
final class StubPlanEngine: PlanEngineServing {}
final class StubSyncService: SyncServing {
    func sync(_ workouts: [Workout], in context: ModelContext) async {}
}
@MainActor
final class StubNotificationService: NotificationServing {
    func requestAuthorization() {}
    func schedulePlannedReminders(_ plan: TrainingPlan?) {}
    func notifyPlanUpdated(title: String, body: String) {}
    func scheduleWeeklyCheckIn() {}
    func scheduleStreakNudge(streak: Int, isPlannedDayToday: Bool, hasWorkedOutToday: Bool) {}
}
/// No-op Athlete Model service for previews/tests that don't exercise learning.
final class StubAthleteModelService: AthleteModelServing {
    func ingest(profile: UserProfile, in context: ModelContext, now: Date) {}
    func seedOnboarding(for profile: UserProfile, in context: ModelContext) {}
    func addCorrection(_ text: String, category: MemoryCategory, for profile: UserProfile, in context: ModelContext) {}
    func forget(noteID: UUID, in context: ModelContext) {}
}
/// Dev stub: unlocks everything so feature work isn't blocked before Phase 3 wires RevenueCat.
final class StubPaywallService: PaywallServing {
    func isEntitled(to feature: Feature) -> Bool { true }
}
