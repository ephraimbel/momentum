import Foundation
import SwiftData
import Observation

/// Drives the coach chat. Builds context from the local store and replies via `CoachResponder`
/// (deterministic, always available). When the `coach-chat` Edge Function is wired, the send path
/// can prefer it and fall back to the responder — the moment never blocks (PRD §8.8).
@MainActor
@Observable
final class CoachChatViewModel {
    struct Message: Identifiable {
        enum Role { case coach, user }
        let id = UUID()
        let role: Role
        let text: String
    }

    private(set) var messages: [Message] = []
    private(set) var isResponding = false
    var input = ""

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        messages = [.init(role: .coach,
                          text: "Hey — I'm your coach. Ask me how you're trending, what to do today, or anything about your training.")]
    }

    var canSend: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isResponding }
    var suggestions: [String] { CoachResponder.suggestions }

    func send(_ raw: String? = nil) {
        let text = (raw ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        input = ""
        messages.append(.init(role: .user, text: text))
        isResponding = true

        Task {
            // A brief, natural "thinking" beat (also where a real Edge Function call would await).
            try? await Task.sleep(for: .milliseconds(550))
            let reply = CoachResponder.reply(to: text, context: buildContext())
            isResponding = false
            messages.append(.init(role: .coach, text: reply))
        }
    }

    private func buildContext() -> CoachResponder.Context {
        let workouts = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        let profile = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first
        let plan = profile?.plan
        let today = PlanCoaching.todaySessions(plan, on: Date()).first { $0.status != .completed }
        return CoachResponder.Context(
            insights: ProgressInsights(workouts: workouts),
            stats: ProfileStats(workouts: workouts),
            todaySession: today,
            goal: profile?.goal ?? .generalFitness,
            disciplines: profile?.disciplines ?? [],
            distanceUnit: .auto,
            athlete: athleteSummary(profile)
        )
    }

    /// Decoupled projection of the Athlete Model (the coach's long-term memory) for the responder.
    /// Reads only stable fields so it won't break as that model evolves.
    private func athleteSummary(_ profile: UserProfile?) -> CoachResponder.AthleteSummary? {
        guard let m = profile?.athlete else { return nil }
        let active = m.notes.filter(\.isActive)
        let ordered = active.filter(\.pinned) + active.filter { !$0.pinned }
        let topShare = m.disciplineShare.max { $0.value < $1.value }?.key
        return .init(
            notes: ordered.prefix(5).map(\.text),
            preferredSessionMinutes: Int(m.preferredSessionMinutes.rounded()),
            topDiscipline: topShare.flatMap { WorkoutType(rawValue: $0)?.title },
            overreachACWR: m.overreachThresholdACWR,
            paceTrendPct: m.paceAtEffortTrendPct
        )
    }
}
