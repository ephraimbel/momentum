import SwiftUI
import SwiftData

/// Strava-style "save your workout" screen, shown after a strength session is finished. The athlete
/// names the workout and adds a description over the volume/PR/exercise breakdown, then Save triggers
/// the completion celebration and returns to the app. (Editing-only; History shows the same content
/// read-only via `StrengthSummaryContent`.)
struct StrengthSaveView: View {
    let workoutId: UUID
    var weightUnit: WeightUnit = .default()
    var onDone: () -> Void

    @Environment(\.modelContext) private var context
    @Query private var workouts: [Workout]
    private var workout: Workout? { workouts.first { $0.id == workoutId } }

    @State private var title = ""
    @State private var desc = ""
    @State private var celebrating = false
    @FocusState private var focus: Field?
    private enum Field { case title, desc }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let workout {
                    VStack(spacing: Theme.Space.xl) {
                        editor
                        StrengthSummaryContent(workout: workout, weightUnit: weightUnit,
                                               celebratePRs: true, showsHeader: false)
                    }
                    .padding(Theme.Space.md)
                } else {
                    ContentUnavailableView("Workout not found", systemImage: "questionmark")
                }
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Save workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.fontWeight(.bold)
                }
            }
        }
        .overlay {
            if celebrating {
                CompletionCelebration(title: "Workout saved") { onDone() }
            }
        }
        .onAppear {
            guard let workout else { return }
            title = workout.title.isEmpty ? Self.defaultTitle(workout) : workout.title
            desc = workout.note
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            TextField("Name your workout", text: $title)
                .font(.display(24, weight: .black))
                .foregroundStyle(Theme.ink)
                .focused($focus, equals: .title)
                .submitLabel(.done)
            Divider().overlay(Theme.hairline)
            TextField("How did it go?", text: $desc, axis: .vertical)
                .font(.rounded(Theme.FontSize.body, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(2...6)
                .focused($focus, equals: .desc)
        }
        .padding(Theme.Space.lg)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
    }

    private func save() {
        focus = nil
        if let workout {
            workout.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            workout.note = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            try? context.save()
        }
        Haptics.success()
        withAnimation(.easeOut(duration: 0.2)) { celebrating = true }
    }

    /// Names the workout by its split ("Push Day", "Leg Day", …); falls back to time-of-day when
    /// there are no classifiable working sets yet.
    private static func defaultTitle(_ w: Workout) -> String {
        if let session = w.strength {
            let split = StrengthSplit.title(for: session)
            if split != "Strength" { return split }
        }
        let hour = Calendar.current.component(.hour, from: w.startedAt)
        switch hour {
        case 5..<12: return "Morning Workout"
        case 12..<17: return "Afternoon Workout"
        case 17..<21: return "Evening Workout"
        default: return "Night Workout"
        }
    }
}
