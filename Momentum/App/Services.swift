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
    let analytics: any AnalyticsServing
    let voiceCoach: any VoiceCoachServing
    let presence: any PresenceServing
    let spots: any SpotsProviding
    let social: any SocialBackending

    init(
        location: any LocationServing,
        motion: any MotionServing,
        health: any HealthServing,
        plan: any PlanEngineServing,
        ai: any AIServing,
        sync: any SyncServing,
        paywall: any PaywallServing,
        notifications: any NotificationServing,
        athleteModel: any AthleteModelServing,
        analytics: any AnalyticsServing = StubAnalyticsService(),
        voiceCoach: any VoiceCoachServing = StubVoiceCoachService(),
        presence: any PresenceServing = StubPresenceService(),
        spots: any SpotsProviding = StubSpotsProvider(),
        social: any SocialBackending = StubSocialBackend()
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
        self.analytics = analytics
        self.voiceCoach = voiceCoach
        self.presence = presence
        self.spots = spots
        self.social = social
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
            athleteModel: AthleteModelService(),
            analytics: AnalyticsService(),
            voiceCoach: VoiceCoachService(),
            presence: LivePresenceService(),
            spots: CachingSpotsProvider(wrapping: MapboxSpotsProvider()),
            social: SupabaseSocialBackend(paywall: paywall)
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
    /// Read recovery signals wearables mirror into Health — HRV, resting HR, and last night's sleep,
    /// each with a personal baseline (for the readiness card). `.empty` if unavailable/unauthorized.
    func recoverySignals() async -> RecoverySignals
    /// The device-measured VO₂max from Apple Health (Watch/Garmin), preferred over our pace estimate.
    func measuredVO2Max() async -> Double?
    /// Import workouts from other sources (Apple Watch, Garmin via Health, …) into our store.
    /// De-duplicated; skips our own writes. Returns the number newly imported.
    @discardableResult
    func importExternalWorkouts(into context: ModelContext, since: Date?) async -> Int
    /// Estimate the athlete's current running baseline (fitness + load) from their recent Health run
    /// history — the onboarding "it already understands me" import. nil when there isn't enough.
    func runningBaseline() async -> BaselineEstimator.RunningBaseline?
    /// The full heart-rate series for a workout window (Watch/Garmin runs carry one) — time-in-zones.
    func heartRateSeries(start: Date, end: Date) async -> [(date: Date, bpm: Double)]
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

@MainActor
protocol VoiceCoachServing: AnyObject {
    /// User/Pro toggle. When false, `announce` is a no-op.
    var isEnabled: Bool { get set }
    /// Speak a short coaching cue (ducks other audio). Cue text comes from `CoachingCueBuilder`.
    func announce(_ text: String)
    /// Stop any in-flight speech and release the audio session.
    func stop()
}

// MARK: - Pro gating

/// The single `Feature` enum that is the source of truth for gating (PRD §10/§13.10). Everything
/// listed here is a **Pro** capability; "free" is everything else (track all disciplines, basic
/// summaries, manual logging + full library, limited history, the week-1 plan glimpse, basic share).
enum Feature: String, CaseIterable, Sendable, Identifiable {
    case aiCoach, fullPlan, programs, aiRead, advancedAnalytics, fullHistory
    case allTemplates, allShareTemplates, cadenceMetronome, voiceCoach, watchPremium
    case mapStyles

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
        case .mapStyles: "map_styles"
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
        case .mapStyles: "all map styles"
        }
    }
}

// MARK: - Phase 0 stubs

final class StubPlanEngine: PlanEngineServing {}
@MainActor
/// Dev stub: unlocks everything so feature work isn't blocked before Phase 3 wires RevenueCat.
final class StubPaywallService: PaywallServing {
    func isEntitled(to feature: Feature) -> Bool { true }
}
/// No-op voice coach for previews/tests.
@MainActor
final class StubVoiceCoachService: VoiceCoachServing {
    var isEnabled = false
    func announce(_ text: String) {}
    func stop() {}
}
