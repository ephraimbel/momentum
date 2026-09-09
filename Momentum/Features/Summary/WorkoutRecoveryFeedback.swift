import SwiftUI
import SwiftData

struct WorkoutRecoveryDraft {
    var recovery: Int?
    var pain: Bool?
    var couldContinue: Bool?
    var illness: Bool?
    init() {}
    init(record: WorkoutFeedbackRecord?) {
        recovery = record?.recovery; pain = record?.pain
        couldContinue = record?.couldContinue; illness = record?.illness
    }
    var hasAnswer: Bool { recovery != nil || pain != nil || couldContinue != nil || illness != nil }

    @MainActor
    func persist(for workout: Workout) {
        guard let context = workout.modelContext,
              context.container.schema.entities.contains(where: { $0.name == "WorkoutFeedbackRecord" }) else { return }
        let existing = WorkoutFeedbackRecord.fetch(workoutID: workout.id, in: context)
        guard hasAnswer || existing != nil else { return }
        // An unchanged editor must not replace newer feedback during cloud conflict resolution.
        if let existing, existing.recovery == recovery, existing.pain == pain,
           existing.couldContinue == couldContinue, existing.illness == illness { return }
        let record = existing ?? WorkoutFeedbackRecord(workoutID: workout.id)
        if record.modelContext == nil { context.insert(record) }
        record.submittedAt = Date(); record.recovery = recovery; record.pain = pain
        record.couldContinue = couldContinue; record.illness = illness
        // The hold is durable in the same commit as the feedback, including offline saves.
        if pain == true || illness == true {
            if let profiles = try? context.fetch(FetchDescriptor<UserProfile>()) {
                for profile in profiles {
                    guard let plan = profile.plan else { continue }
                    AdaptivePlanService.initialize(plan, profileID: profile.id, now: Date(), in: context)
                    plan.adaptiveState?.requiresRecoveryCheckin = true
                }
            }
        }
    }
}

struct WorkoutRecoveryFeedback: View {
    @Binding var draft: WorkoutRecoveryDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recovery check-in").font(.rounded(16, weight: .bold))
            Text("A few taps help shape your next week.").font(.rounded(13)).foregroundStyle(Theme.inkSecondary)
            answer("Recovery", selection: $draft.recovery, options: [("Drained", 1), ("Okay", 2), ("Recovered", 3)])
                .accessibilityIdentifier("recovery-rating")
            answer("Pain or unusual discomfort?", selection: $draft.pain, options: [("Yes", true), ("No", false)])
                .accessibilityIdentifier("recovery-pain")
            answer("Feeling ill?", selection: $draft.illness, options: [("Yes", true), ("No", false)])
                .accessibilityIdentifier("recovery-illness")
            answer("Could you have continued?", selection: $draft.couldContinue, options: [("Yes", true), ("No", false)])
                .accessibilityIdentifier("recovery-continue")
            if draft.pain == true || draft.illness == true {
                Text("Rest from running until symptoms resolve. Your coach will ask you to check in before starting another planned run. Persistent or worsening symptoms deserve professional advice.")
                    .font(.rounded(14)).foregroundStyle(Theme.inkSecondary)
            }
        }
    }
    // Explicit labels: SwiftUI's menu Picker hides its label outside a Form. These questions
    // must remain visible, and the entire row must open the answer menu (including its label).
    private func answer<Value: Equatable>(_ title: String, selection: Binding<Value?>,
                                          options: [(String, Value)]) -> some View {
        let selected = options.first { $0.1 == selection.wrappedValue }?.0 ?? "Not answered"
        return Menu {
            Button("Not answered") { selection.wrappedValue = nil }
            ForEach(options.indices, id: \.self) { index in
                Button(options[index].0) { selection.wrappedValue = options[index].1 }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(selected).foregroundStyle(Theme.purple).fixedSize()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.purple)
            }
            .font(.rounded(14)).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(selected)
    }
}
