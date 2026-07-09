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
    @Environment(Services.self) private var services
    // Read the just-finished workout from a FRESH context. The live session was persisted by a
    // background @ModelActor; the app's main context can still hold a stale copy (Today's @Query
    // cached the workout mid-session with no/partial sets, and SwiftData doesn't merge cross-context
    // to-many appends). A new context faults relationships straight from the store, so the logged
    // sets, muscles worked, and split-based naming all show correctly.
    @State private var reader: FinishedWorkoutReader?
    private var workout: Workout? { reader?.workout }

    @State private var title = ""
    @State private var desc = ""
    @State private var celebrating = false
    @FocusState private var focus: Field?
    private enum Field { case title, desc }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let workout {
                    // Reveal first, name last: the payoff leads; the editor sits quietly at the bottom.
                    VStack(spacing: Theme.Space.lg) {
                        StrengthSummaryContent(workout: workout, weightUnit: weightUnit,
                                               celebratePRs: true, showsHeader: false)
                        editor
                    }
                    .padding(Theme.Space.md)
                } else {
                    ProgressView().padding(.top, Theme.Space.xxl)
                }
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Save workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.fontWeight(.bold).disabled(workout == nil)
                }
            }
        }
        .overlay {
            if celebrating {
                CompletionCelebration(title: "Workout saved") { onDone() }
            }
        }
        .task {
            guard reader == nil else { return }
            let reader = FinishedWorkoutReader(container: context.container, workoutId: workoutId)
            self.reader = reader
            if let workout = reader.workout {
                title = workout.title.isEmpty ? Self.defaultTitle(workout) : workout.title
                desc = workout.note
            }
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
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
    }

    private func save() {
        focus = nil
        // Commit through the reader's own context (where `workout` lives) so the write persists.
        reader?.commit(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                       note: desc.trimmingCharacters(in: .whitespacesAndNewlines))
        // Persist the records this session set (fresh context — the logged sets are complete there).
        if let reader, let workout = reader.workout {
            let hits = StrengthPRs.detect(for: workout, weightUnit: weightUnit, in: reader.context)
            PersonalRecord.persist(hits.compactMap { hit in
                hit.prType.map { (type: $0, value: hit.value, exercise: hit.exercise) }
            }, workout: workout, in: reader.context)
        }
        if let saved = workout { Task { await services.health.save(saved) } }   // mirror to Apple Health
        Haptics.success()
        withAnimation(.easeOut(duration: 0.2)) { celebrating = true }
    }

    /// Names the workout by its split ("Push Day", "Leg Day", …); falls back to time-of-day when
    /// there are no classifiable working sets yet.
    private static func defaultTitle(_ w: Workout) -> String {
        // Crossfit/HIIT name themselves by the sport — split-naming ("Push Day") is for weight training.
        if w.type != .strength, w.type.isStrengthStyle { return w.type.title }
        // Prefer the plan's intended split (so a half-finished day still names itself by the plan).
        if let planned = w.plannedSession, planned.discipline == .strength {
            let split = StrengthSplit.title(forPlanned: planned)
            if split != "Strength" { return split }
        }
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

/// Loads one finished workout in a private `ModelContext` (retained for the view's lifetime) so its
/// relationships are read — and edits written — fresh against the store, bypassing any stale
/// main-context cache left over from observing the workout while it was still being captured.
@Observable
final class FinishedWorkoutReader {
    let workout: Workout?
    let context: ModelContext   // retained so `workout`'s faults stay resolvable; save views
    // also detect + persist PRs through it (same-context rule for relationship reads)

    init(container: ModelContainer, workoutId: UUID) {
        let context = ModelContext(container)
        self.context = context
        self.workout = (try? context.fetch(FetchDescriptor<Workout>()))?.first { $0.id == workoutId }
    }

    func commit(title: String, note: String) {
        commit { $0.title = title; $0.note = note }
    }

    /// General edit hook: mutate the fresh-context workout, then persist through the same context
    /// (writes made through any other context wouldn't see these relationships resolved).
    func commit(_ mutate: (Workout) -> Void) {
        guard let workout else { return }
        mutate(workout)
        try? context.save()
    }

    /// Explicit user discard — deletes through the fresh context so the cascade sees the full,
    /// non-stale relationship graph.
    func delete() {
        guard let workout else { return }
        context.delete(workout)
        try? context.save()
    }
}
