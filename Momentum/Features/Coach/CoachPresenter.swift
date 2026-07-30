import Foundation
import Observation

/// App-wide presentation state for the coach chat. One instance lives in the environment and ONE
/// `fullScreenCover` in `RootView` renders it, so every entry point (Today's floating button,
/// Settings, future contextual "ask about this" hooks) opens the same thread — and a nav card tapped
/// inside the chat can dismiss it and steer the app shell.
@MainActor
@Observable
final class CoachPresenter {
    var isPresented = false
    /// Last moment the athlete had the chat open — anything the coach seeded after this badges the
    /// Today button. Persisted so the badge survives launches; updated on both open and close.
    private(set) var lastSeenAt: Date
    private static let lastSeenKey = "coach.lastSeenAt"
    /// Pre-typed input for contextual entry ("About today's tempo run: "). Consumed once on open.
    private(set) var prefill: String?
    /// The workout a contextual entry is about — the debrief grounds in THIS one, not just the latest.
    private(set) var contextWorkoutID: UUID?
    /// A nav-card destination waiting for the shell — set on tap, consumed by `RootView.onChange`.
    var pendingNav: CoachDestination?
    /// Set by the shell when a nav card asked for plan settings; `PlanView` consumes it on appear.
    var wantsPlanSettings = false
    /// Onboarding owns the screen — while it's up, the coach never presents over it (a proactive
    /// seed or stray deep link mid-onboarding would stack covers). Set by `RootView`.
    var isSuspended = false {
        didSet { if isSuspended { isPresented = false } }
    }

    init() {
        lastSeenAt = UserDefaults.standard.object(forKey: Self.lastSeenKey) as? Date ?? .distantPast
    }

    func open(prefill: String? = nil, workoutID: UUID? = nil) {
        guard !isSuspended else { return }
        self.prefill = prefill
        self.contextWorkoutID = workoutID
        isPresented = true
        markSeen()
    }

    func close() {
        prefill = nil
        isPresented = false
        markSeen()   // everything in the thread has been on screen — clear the badge
    }

    private func markSeen() {
        lastSeenAt = Date()
        UserDefaults.standard.set(lastSeenAt, forKey: Self.lastSeenKey)
    }

    /// A nav card was tapped: leave the chat and let the shell route.
    func navigate(_ destination: CoachDestination) {
        isPresented = false
        pendingNav = destination
        markSeen()
    }

    /// The chat consumed the prefill into its input field.
    func consumePrefill() -> String? {
        defer { prefill = nil }
        return prefill
    }

    /// The chat consumed the contextual workout reference.
    func consumeContextWorkout() -> UUID? {
        defer { contextWorkoutID = nil }
        return contextWorkoutID
    }
}

#if DEBUG
import SwiftData

/// `--coach-card` deep-link seeding: a deterministic easeWeek proposal in the thread so the card UI
/// (proposal → Apply → receipt) can be screenshot-verified with no backend. DEBUG-only; never ships.
@MainActor
enum CoachDemo {
    static func seedProposalIfNeeded(in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<ChatMessage>())) ?? []
        // Idempotent AND deterministic: an open easeWeek proposal means we already seeded. Any
        // OTHER thread state (a proactive seed from a previous demo launch, old receipts) would
        // block or bury the verification card — clear it. DEBUG-only; never ships.
        guard !existing.contains(where: { $0.card?.kind == .easeWeek && $0.cardState == .proposed }) else { return }
        for m in existing { context.delete(m) }
        context.insert(ChatMessage(role: .coach,
            text: "Hey, I'm your coach. Ask me how you're trending, what to do today, or to change up your plan."))
        context.insert(ChatMessage(role: .user, text: "This week feels way too hard, can we ease it?"))
        let card = CoachCardPayload(kind: .easeWeek, label: "Ease this week")
        context.insert(ChatMessage(role: .coach,
            text: "Heard. I can trim your upcoming sessions about 15% and soften the hard work to easy, so you absorb the block instead of fighting it.",
            card: card))
        try? context.save()
    }
}
#endif
