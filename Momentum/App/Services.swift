import Foundation
import CoreLocation
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
    let ai: any AIServing
    let sync: any SyncServing
    let paywall: any PaywallServing
    let notifications: any NotificationServing
    let athleteModel: any AthleteModelServing
    let analytics: any AnalyticsServing
    let voiceCoach: any VoiceCoachServing
    let presence: any PresenceServing
    let social: any SocialBackending

    init(
        location: any LocationServing,
        motion: any MotionServing,
        health: any HealthServing,
        ai: any AIServing,
        sync: any SyncServing,
        paywall: any PaywallServing,
        notifications: any NotificationServing,
        athleteModel: any AthleteModelServing,
        analytics: any AnalyticsServing = StubAnalyticsService(),
        voiceCoach: any VoiceCoachServing = StubVoiceCoachService(),
        presence: any PresenceServing = StubPresenceService(),
        social: any SocialBackending = StubSocialBackend()
    ) {
        self.location = location
        self.motion = motion
        self.health = health
        self.ai = ai
        self.sync = sync
        self.paywall = paywall
        self.notifications = notifications
        self.athleteModel = athleteModel
        self.analytics = analytics
        self.voiceCoach = voiceCoach
        self.presence = presence
        self.social = social
    }

    /// The default wiring used by the running app. The real app injects the live `PaywallController`
    /// (so `services.paywall` and `@Environment(PaywallController.self)` are the same instance);
    /// previews/tests fall back to the unlock-all stub so feature surfaces stay visible.
    static func live(paywall: any PaywallServing = StubPaywallService()) -> Services {
        // Built first so the sync sweep reports rejected uploads through the *same* analytics
        // instance the rest of the app logs to, rather than a second one with its own buffer.
        let analytics = AnalyticsService()
        return Services(
            location: LocationService(),
            motion: MotionService(),
            health: HealthService(),
            ai: AIService(),
            sync: SyncService(analytics: analytics),
            paywall: paywall,
            notifications: NotificationService(),
            athleteModel: AthleteModelService(),
            analytics: analytics,
            voiceCoach: VoiceCoachService(),
            presence: LivePresenceService(),
            social: SupabaseSocialBackend(paywall: paywall)
        )
    }
}

// MARK: - Service protocols (contracts fixed in Phase 0)

@MainActor
protocol LocationServing: AnyObject {
    var isAuthorized: Bool { get }
    /// The last one-shot fix, if we have one. On the protocol (2026-08-28) so every surface can
    /// share the SAME service: onboarding's location grant has to reach Today's map, and it can't
    /// if each screen owns a private `LocationService` whose `lastLocation` nobody else sees.
    var lastLocation: CLLocationCoordinate2D? { get }
    /// Request the real system permission. Completion runs on the main actor only after iOS has
    /// resolved the prompt (or immediately when the choice was already made).
    func requestAuthorization(completion: ((Bool) -> Void)?)
    /// Ask for a single fresh fix — used to open/recenter the home map on the athlete.
    func refreshLocation()
    /// The most-recent coordinate the system knows, however stale — for framing non-critical UI
    /// (map-style previews) around the athlete's area. Never used for tracking (no accuracy gate).
    var lastCoordinate: CLLocationCoordinate2D? { get }
    /// Live stream of raw fixes; the engine's `GPSProcessor` applies the accept gate.
    func fixes() -> AsyncStream<GPSProcessor.Fix>
    func stop()
}

extension LocationServing {
    func requestAuthorization() { requestAuthorization(completion: nil) }
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
    /// `includeEnergy: false` skips the active-energy sample — for a workout whose calorie number
    /// was READ from Health in the first place (writing it back would double-count the Move ring).
    func save(_ workout: Workout, includeEnergy: Bool) async
    /// The wearable's own active-energy total (kcal) inside one already-known Momentum workout
    /// window. nil = no samples (absent, never zero); this never discovers a workout.
    func measuredActiveEnergy(start: Date, end: Date) async -> Double?
    /// Read the athlete's latest body mass + resting HR signals. nils if unavailable.
    func currentBodyMetrics() async -> (bodyMassKg: Double?, restingHR: Int?)
    /// Read recovery signals wearables mirror into Health — HRV, resting HR, and last night's sleep,
    /// each with a personal baseline (for the readiness card). `.empty` if unavailable/unauthorized.
    func recoverySignals() async -> RecoverySignals
    /// The device-measured VO₂max from Apple Health (Watch/Garmin), preferred over our pace estimate.
    func measuredVO2Max() async -> Double?
    // No workout import. Health is read for signals only — sleep, HRV, resting heart rate, body
    // mass — never for workouts. Connecting it must not backfill a journal, so there is deliberately
    // no API here that turns a HealthKit sample into a `Workout`.
    /// Heart rate inside one already-known Momentum workout window — used for time-in-zones when a
    /// wearable wrote the signal but Momentum did not capture it locally. Never discovers a workout.
    func heartRateSeries(start: Date, end: Date) async -> [(date: Date, bpm: Double)]
    /// Daily step totals for the trailing window (oldest → newest, one point per day, zeros kept so
    /// gaps read honestly). Empty when Health is unavailable/unauthorized — the Trends steps card
    /// shows its quiet connect line instead of a fabricated flatline.
    func dailySteps(daysBack: Int) async -> [(day: Date, steps: Double)]
}

extension HealthServing {
    /// The common save — every calorie the workout carries is ours to mirror.
    func save(_ workout: Workout) async { await save(workout, includeEnergy: true) }
}

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
    /// Open the paywall for a locked feature (no-op when already entitled) — presentation is the
    /// other half of gating, so surfaces that hold only the protocol (service-layer callers like
    /// the summary's plan-proposal card) can gate-and-present without reaching for the concrete
    /// `PaywallController`. Added 2026-07-22 when the first such caller appeared.
    func present(for feature: Feature)
}
@MainActor
protocol NotificationServing: AnyObject {
    /// Ask for local-notification permission (once; no-op if already determined). `completion` runs
    /// on the main thread once the system prompt is RESOLVED (or immediately if already determined),
    /// so a flow can advance only after the prompt is dismissed — never stacking another prompt on it.
    func requestAuthorization(completion: ((Bool) -> Void)?)
    /// Resync next-workout reminders to the plan's upcoming sessions (each carries its prescription).
    func schedulePlannedReminders(_ plan: TrainingPlan?)
    /// The repeating Sunday week-in-review nudge (PRD §24).
    func scheduleWeeklyCheckIn()
    /// A gentle, ≤1/day streak-protection nudge when a real streak is at risk on a planned day (§24).
    func scheduleStreakNudge(streak: Int, isPlannedDayToday: Bool, hasWorkedOutToday: Bool)
}

extension NotificationServing {
    /// Fire-and-forget convenience — request without waiting on the prompt.
    func requestAuthorization() { requestAuthorization(completion: nil) }
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
    /// Warm the speech stack (synthesizer + voice lookup) before the first cue, so the opening line
    /// of a workout lands on the beat. Optional: the default does nothing.
    func prepare()
}

extension VoiceCoachServing {
    func prepare() {}
}

// MARK: - Pro gating

/// The single `Feature` enum that is the source of truth for gating (PRD §10/§13.10). Everything
/// listed here is a **Pro** capability; "free" is everything else (track all disciplines, basic
/// summaries, manual logging + full library, limited history, the week-1 plan glimpse, basic share).
enum Feature: String, CaseIterable, Sendable, Identifiable {
    case aiCoach, fullPlan, programs, aiRead, advancedAnalytics, fullHistory
    case allTemplates, allShareTemplates, cadenceMetronome, voiceCoach, watchPremium
    case mapStyles, routeReplay, fuel

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
        case .routeReplay: "route_replay"
        case .fuel: "fuel_locked"
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
        case .routeReplay: "route replay"
        case .fuel: "the fuel journal"
        }
    }

    /// A capitalized headline for the Pro lock card (the WHAT).
    var lockTitle: String {
        switch self {
        case .aiCoach: "The AI coach"
        case .fullPlan: "Your full plan"
        case .programs: "Programs"
        case .aiRead: "AI reads"
        case .advancedAnalytics: "Advanced trends"
        case .fullHistory: "Your full history"
        case .allTemplates: "All templates"
        case .allShareTemplates: "Every share style"
        case .cadenceMetronome: "Cadence metronome"
        case .voiceCoach: "Voice coach"
        case .watchPremium: "Watch premium"
        case .mapStyles: "All map styles"
        case .routeReplay: "Route replay"
        case .fuel: "Fuel your training"
        }
    }

    /// A one-line value prop for the Pro lock card (the WHY).
    var lockBlurb: String {
        switch self {
        case .aiCoach: "A real coach, on demand"
        case .fullPlan: "Every week, adapting as you train"
        case .programs: "Structured programs for any goal"
        case .aiRead: "AI reads every workout for you"
        case .advancedAnalytics: "Fitness, fatigue and form over time"
        case .fullHistory: "Your whole training history"
        case .allTemplates: "Every workout template"
        case .allShareTemplates: "Every way to share"
        case .cadenceMetronome: "Lock your cadence, every run"
        case .voiceCoach: "Live cues while you run"
        case .watchPremium: "The full experience on your wrist"
        case .mapStyles: "Every map style"
        case .routeReplay: "Relive every turn of your route"
        case .fuel: "AI meal logging, keyed to your plan"
        }
    }
}

// MARK: - Phase 0 stubs

@MainActor
/// Dev stub: unlocks everything so feature work isn't blocked before Phase 3 wires RevenueCat.
final class StubPaywallService: PaywallServing {
    func isEntitled(to feature: Feature) -> Bool { true }
    func present(for feature: Feature) {}   // everything's entitled — there's never a wall to show
}
/// No-op voice coach for previews/tests.
@MainActor
final class StubVoiceCoachService: VoiceCoachServing {
    var isEnabled = false
    func announce(_ text: String) {}
    func stop() {}
}
