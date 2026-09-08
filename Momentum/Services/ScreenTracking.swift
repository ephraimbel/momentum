import SwiftUI

/// Foreground-visit analytics with a closed screen vocabulary. Clean background transitions
/// emit an end immediately; iOS grants no guarantee of network delivery. Abrupt process endings
/// are recovered only if the athlete launches again, so SQL also retains unclosed screen trails.
/// Abandoned/timed-out durations are lower bounds, not measured durations or crash diagnoses.
/// Session UUIDs group events within one install; they contain no device or health information.

// MARK: - The vocabulary

/// Every screen the funnel can name. **Closed on purpose.** A free-form string would let call sites
/// invent `"Today"`, `"today"` and `"TodayView"` for one room, and a funnel that splits one screen
/// across three labels is worse than no funnel — the drop it was built to find averages away across
/// the spellings. Adding a screen means adding a case here, which is also the list a reader can
/// scan to see what the app does and does not measure.
enum AppScreen: String, CaseIterable, Sendable {
    // The door.
    case welcome                 = "welcome"
    /// The account sheet — sign in AND sign up, which share one screen.
    case signIn                  = "sign_in"
    /// Onboarding's own per-beat drop-off is `onboarding_step`, which carries the beat name; this is
    /// the one coarse marker that puts the flow on the same path timeline as every other screen.
    case onboarding              = "onboarding"
    case planReveal              = "plan_reveal"

    // The five tabs.
    case today                   = "today"
    case plan                    = "plan"
    case progress                = "progress"
    case fuel                    = "fuel"
    case profile                 = "profile"

    // Progress is three rooms behind one tab, and they convert very differently.
    case progressTrends          = "progress_trends"
    case progressHistory         = "progress_history"
    case progressHealth          = "progress_health"

    // Money.
    case paywall                 = "paywall"

    // Plan.
    case planBuilder             = "plan_builder"
    case planSettings            = "plan_settings"
    case planSession             = "plan_session"
    case yourPlans               = "your_plans"
    case managePlan              = "manage_plan"
    case addSession              = "add_session"

    // Capture — the habit itself.
    case workoutRecorder         = "workout_recorder"
    case workoutSave             = "workout_save"
    case workoutDetail           = "workout_detail"
    case sportPicker             = "sport_picker"
    case workoutLibrary          = "workout_library"

    // Fuel.
    case mealPhoto               = "meal_photo"
    case mealDetail              = "meal_detail"
    case fuelHealth              = "fuel_health"

    // Everything else worth a number.
    case coachChat               = "coach_chat"
    case settings                = "settings"
    case awards                  = "awards"
    case share                   = "share"
    case notificationsInbox      = "notifications_inbox"
    case community               = "community"
}

// MARK: - The tracker

/// Owns the current session and turns screen entries into events. Lives on `Services` (built beside
/// the `AnalyticsService` it reports through) and reaches views through `\.screenTracker`.
@MainActor
final class ScreenTracker {

    /// Observed lifecycle reason. Background includes app switching and locking the phone;
    /// abandoned means no clean end was saved, not a confirmed crash.
    enum EndReason: String {
        /// The app went to the background — the ordinary way a session ends.
        case background
        /// The previous session never closed: the process died while it was still in the foreground
        /// (crash, force-quit, jetsam). Discovered and closed on the next launch.
        case abandoned
        /// A new session began while the old one was still open and long stale — the app came back
        /// without ever having backgrounded cleanly.
        case timedOut = "timed_out"
    }

    /// How long a gap makes the next screen a NEW session. Thirty minutes is the industry-standard
    /// inactivity window; it matters here only for the odd case where the app is resumed without a
    /// clean background transition, since the ordinary path closes the session on backgrounding.
    static let inactivityWindow: TimeInterval = 30 * 60

    /// A session in flight, persisted on every screen view so a process death can be reconstructed
    /// on the next launch. Small and rewritten a few times a minute — cheap.
    private struct OpenSession: Codable {
        let id: String
        let startedAt: Date
        var lastScreen: String
        var views: Int
        var lastSeenAt: Date
    }

    private let analytics: any AnalyticsServing
    private let defaults: UserDefaults
    private let key = "com.momentum.analytics.openSession"

    private var current: OpenSession?
    private var visible: [(id: UUID, screen: AppScreen)] = []
    private var backgrounded = false

    /// Presentation ownership matters: a sheet can disappear without the tab underneath receiving
    /// another onAppear. Restore the most recent surviving surface when its child goes away.
    func appeared(_ screen: AppScreen, id: UUID, at now: Date = Date()) {
        if let index = visible.firstIndex(where: { $0.id == id }) {
            visible[index].screen = screen
            if index == visible.count - 1 { enter(screen, at: now) }
        } else {
            visible.append((id, screen))
            enter(screen, at: now)
        }
    }

    func disappeared(id: UUID, at now: Date = Date()) {
        let wasTop = visible.last?.id == id
        visible.removeAll { $0.id == id }
        if wasTop, let screen = visible.last?.screen { enter(screen, at: now) }
    }

    func sceneChanged(_ phase: ScenePhase, at now: Date = Date()) {
        switch phase {
        case .background:
            backgrounded = true
            endSession(at: now)
        case .active:
            let returning = backgrounded
            backgrounded = false
            if returning, let screen = visible.last?.screen { enter(screen, at: now) }
        default: break // Permission dialogs / Control Center do not end the visit.
        }
    }
    /// Consecutive appearances of the same surface do not inflate view counts. A different
    /// intervening screen or a new foreground visit creates another view.
    private var lastView: (screen: AppScreen, at: Date)?

    /// - Parameter recoverStaleSession: pass false in tests that assert on a clean slate.
    init(analytics: any AnalyticsServing,
         defaults: UserDefaults = .standard,
         recoverStaleSession: Bool = true) {
        self.analytics = analytics
        self.defaults = defaults
        if recoverStaleSession { closeStaleSession() }
    }

    /// Record that the athlete is now looking at `screen`. Opens a session if none is running.
    func enter(_ screen: AppScreen, at now: Date = Date()) {
        guard !backgrounded else { return }
        // One view, however many times SwiftUI decides to call onAppear for it.
        if let last = lastView, last.screen == screen,
           now.timeIntervalSince(last.at) <= Self.inactivityWindow {
            return
        }
        lastView = (screen, now)

        // A session left open across a long gap belongs to an earlier visit, not this one.
        if let open = current, now.timeIntervalSince(open.lastSeenAt) > Self.inactivityWindow {
            emitEnd(open, reason: .timedOut, at: open.lastSeenAt)
            current = nil
        }

        var session = current ?? OpenSession(id: Self.mintID(), startedAt: now,
                                             lastScreen: screen.rawValue, views: 0, lastSeenAt: now)
        session.views += 1
        session.lastScreen = screen.rawValue
        session.lastSeenAt = now
        current = session
        persist(session)

        analytics.log(.screenViewed(screen: screen.rawValue,
                                    session: session.id,
                                    sequence: session.views))
    }

    /// Close on backgrounding while delivery can still be attempted. Offline tails remain queued;
    /// there is no guarantee of delivery if the athlete never returns.
    func endSession(reason: EndReason = .background, at now: Date = Date()) {
        guard let open = current else { return }
        current = nil
        lastView = nil
        defaults.removeObject(forKey: key)
        emitEnd(open, reason: reason, at: now)
    }

    // MARK: - Internals

    /// A session that was still open when the process died. Closed at `lastSeenAt`, NOT at recovery
    /// time — the athlete's session ended when the app did, and stamping it `now` would report every
    /// crashed session as lasting until the athlete happened to reopen the app, which could be days.
    private func closeStaleSession() {
        guard let data = defaults.data(forKey: key),
              let stale = try? JSONDecoder().decode(OpenSession.self, from: data) else { return }
        defaults.removeObject(forKey: key)
        emitEnd(stale, reason: .abandoned, at: stale.lastSeenAt)
    }

    private func emitEnd(_ session: OpenSession, reason: EndReason, at end: Date) {
        let duration = max(0, end.timeIntervalSince(session.startedAt))
        analytics.log(.sessionEnded(lastScreen: session.lastScreen,
                                    views: session.views,
                                    durationS: Int(duration.rounded()),
                                    reason: reason.rawValue,
                                    session: session.id))
    }

    /// Takes the session rather than reading `current`, so this can never be handed an Optional to
    /// encode — a top-level `null` in the queue would decode back as a session that isn't there.
    private func persist(_ session: OpenSession) {
        defaults.set(try? JSONEncoder().encode(session), forKey: key)
    }

    /// Full random UUID: truncated tokens have birthday collisions over long-lived installs.
    /// Stored with the open visit and queued events, never derived from a device identifier.
    private static func mintID() -> String {
        UUID().uuidString.lowercased()
    }

    /// Test seam: the id of the session in flight, if any.
    var currentSessionID: String? { current?.id }
}

// MARK: - Environment + the modifier

private struct ScreenTrackerKey: EnvironmentKey {
    /// **Optional, defaulting to nil — not a live no-op tracker.** `EnvironmentKey.defaultValue` is
    /// nonisolated, so it cannot build a `@MainActor` tracker without an `assumeIsolated` that would
    /// be a lie off the main actor. Optional also gives the behaviour we want for free: a `#Preview`
    /// or a detached view that never received the real tracker renders normally and counts nothing,
    /// rather than trapping the way `@Environment(Services.self)` does when the container is absent.
    static let defaultValue: ScreenTracker? = nil
}

extension EnvironmentValues {
    var screenTracker: ScreenTracker? {
        get { self[ScreenTrackerKey.self] }
        set { self[ScreenTrackerKey.self] = newValue }
    }
}

extension View {
    /// Mark this view as `screen` for the funnel. One line per surface, on the view that owns the
    /// screen — the tab root, the sheet's content, the pushed destination.
    ///
    /// Fires on `onAppear`, so returning from a pushed screen counts as re-entering the one behind
    /// it. That is deliberate: the path is what the athlete actually looked at, in order.
    func trackScreen(_ screen: AppScreen) -> some View {
        modifier(ScreenTrackingModifier(screen: screen))
    }
}

private struct ScreenTrackingModifier: ViewModifier {
    @Environment(\.screenTracker) private var tracker
    @State private var identity = UUID()
    let screen: AppScreen

    func body(content: Content) -> some View {
        content
            .onAppear { tracker?.appeared(screen, id: identity) }
            .onChange(of: screen) { _, value in tracker?.appeared(value, id: identity) }
            .onDisappear { tracker?.disappeared(id: identity) }
    }
}
