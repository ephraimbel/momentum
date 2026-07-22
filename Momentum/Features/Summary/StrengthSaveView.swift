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
    @Query private var profiles: [UserProfile]
    // Read the just-finished workout from a FRESH context. The live session was persisted by a
    // background @ModelActor; the app's main context can still hold a stale copy (Today's @Query
    // cached the workout mid-session with no/partial sets, and SwiftData doesn't merge cross-context
    // to-many appends). A new context faults relationships straight from the store, so the logged
    // sets, muscles worked, and split-based naming all show correctly.
    @State private var reader: FinishedWorkoutReader?
    private var workout: Workout? { reader?.workout }

    @State private var title = ""
    @State private var desc = ""
    /// Plays on ARRIVAL, not on the way out — see `CardioSaveView.celebrating`. The reward for the
    /// session belongs to the moment it ends, not to the dismissal a minute later.
    @State private var celebrating = true
    @State private var saveFailed = false
    @FocusState private var focus: Field?
    private enum Field { case title, desc }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let workout {
                    // Reveal first, name last: the payoff leads; the editor sits quietly at the bottom.
                    VStack(spacing: Theme.Space.lg) {
                        StrengthSummaryContent(workout: workout, weightUnit: weightUnit,
                                               celebratePRs: true, showsHeader: false,
                                               revealDelay: CompletionCelebration.handoff)
                        editor
                    }
                    .padding(Theme.Space.md)
                } else if reader != nil {
                    // The finished workout couldn't be read — never trap the athlete on an endless
                    // spinner; give a plain message and a way out.
                    ContentUnavailableView {
                        Label("Couldn't load this workout", systemImage: "questionmark")
                    } actions: {
                        Button("Close") { onDone() }
                    }
                } else {
                    ProgressView().padding(.top, Theme.Space.xxl)
                }
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            // Not "Save workout": the session was on disk before this screen appeared.
            .navigationTitle(workout?.type.title ?? "Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }.fontWeight(.bold).disabled(workout == nil)
                }
            }
        }
        .overlay {
            if celebrating {
                // Dismisses into the summary underneath — it no longer closes the screen.
                CompletionCelebration(title: "Workout complete") { celebrating = false }
            }
        }
        // The sets are already on disk — only the name and notes failed to write, so say exactly that
        // and keep the athlete on the screen with their text intact rather than dismissing over it.
        .alert("Couldn't save your notes", isPresented: $saveFailed) {
            Button("Try again") { save() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Your workout and every set are safe. The title and notes didn't write — your text is still here.")
        }
        .task {
            guard reader == nil else { return }
            let reader = FinishedWorkoutReader(container: context.container, workoutId: workoutId)
            self.reader = reader
            if let workout = reader.workout {
                title = workout.title.isEmpty ? Self.defaultTitle(workout) : workout.title
                desc = workout.note
                // The share moment starts from the athlete's chosen default (never silently public).
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
            TextField("How did it go — and why did this one matter?", text: $desc, axis: .vertical)
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
        // Never celebrate a write that didn't land: the title and notes exist only in these fields.
        guard let reader, reader.commit({
            $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.note = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        }) else { saveFailed = true; return }
        // Persist the records this session set (fresh context — the logged sets are complete there).
        if let workout = reader.workout {
            let hits = StrengthPRs.detect(for: workout, weightUnit: weightUnit, in: reader.context)
            PersonalRecord.persist(hits.compactMap { hit in
                hit.prType.map { (type: $0, value: hit.value, exercise: hit.exercise) }
            }, workout: workout, in: reader.context)
        }
        if let saved = workout { Task { await services.health.save(saved) } }   // mirror to Apple Health
        // No celebration here any more — it played on arrival, where the moment actually is.
        Haptics.success()
        AppReview.recordWorkoutSaved()   // a KEPT workout — engagement toward the rating ask (not discards)
        onDone()
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
        // Fetch this one workout by id (predicate + limit 1) — let the store do the lookup instead
        // of loading the whole Workout table into memory and scanning it on every save.
        var descriptor = FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutId })
        descriptor.fetchLimit = 1
        self.workout = try? context.fetch(descriptor).first
    }

    @discardableResult
    func commit(title: String, note: String) -> Bool {
        commit { $0.title = title; $0.note = note }
    }

    /// General edit hook: mutate the fresh-context workout, then persist through the same context
    /// (writes made through any other context wouldn't see these relationships resolved).
    ///
    /// Reports success rather than swallowing it. This is the one screen in the app where a dropped
    /// write loses something the athlete typed by hand — a failed `save()` here used to dismiss the
    /// sheet as if it had worked, taking the title, note, sport and effort with it. A nil `workout`
    /// (the initial fetch failed) is the same failure wearing a different hat: the fields render and
    /// accept edits that have nowhere to land.
    @discardableResult
    func commit(_ mutate: (Workout) -> Void) -> Bool {
        guard let workout else { return false }
        mutate(workout)
        do { try context.save(); return true } catch { return false }
    }

    /// Explicit user discard — deletes through the fresh context so the cascade sees the full,
    /// non-stale relationship graph. Reports success: a discard that silently fails leaves the
    /// workout in the list, so the athlete taps Discard again on something they already threw away.
    @discardableResult
    func delete() -> Bool {
        guard let workout else { return false }
        context.delete(workout)
        do { try context.save(); return true } catch { return false }
    }
}
