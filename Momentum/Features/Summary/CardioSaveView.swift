import SwiftUI
import SwiftData

/// Strava-style "save your run" screen, shown after a cardio workout is finished. The athlete names
/// the activity and adds a description over the route + stats, then Save triggers the completion
/// celebration and returns to the app. (Editing-only entry point; History shows the same content
/// read-only via `CardioSummaryContent`.)
struct CardioSaveView: View {
    let workoutId: UUID
    var distanceUnit: DistanceUnit = .auto
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
                        CardioSummaryContent(workout: workout, distanceUnit: distanceUnit, showsHeader: false)
                    }
                    .padding(Theme.Space.md)
                } else {
                    ContentUnavailableView("Workout not found", systemImage: "questionmark")
                }
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Save \(workout?.type.title.lowercased() ?? "activity")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.fontWeight(.bold)
                }
            }
        }
        .overlay {
            if celebrating {
                CompletionCelebration(title: "\(workout?.type.title ?? "Run") saved") { onDone() }
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
            TextField("Name your run", text: $title)
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

    /// "Morning Run" / "Evening Ride" — a friendly default keyed to time of day.
    private static func defaultTitle(_ w: Workout) -> String {
        let hour = Calendar.current.component(.hour, from: w.startedAt)
        let part: String
        switch hour {
        case 5..<12: part = "Morning"
        case 12..<17: part = "Afternoon"
        case 17..<21: part = "Evening"
        default: part = "Night"
        }
        return "\(part) \(w.type.title)"
    }
}
