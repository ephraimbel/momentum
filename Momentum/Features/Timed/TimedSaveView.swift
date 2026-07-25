import SwiftUI
import SwiftData

/// "Save your session" for a timed activity — name it, add a note and effort over the duration, then
/// Save triggers the completion celebration. (Editing entry point; History shows the same content
/// read-only via `TimedSummaryContent`.)
struct TimedSaveView: View {
    let workoutId: UUID
    var onDone: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @Query private var workouts: [Workout]
    private var workout: Workout? { workouts.first { $0.id == workoutId } }

    @State private var title = ""
    @State private var desc = ""
    @State private var effort: Int?
    /// Plays after SAVE — see `CardioSaveView.celebrating` (user call 2026-07-23).
    @State private var celebrating = false
    @State private var confirmDiscard = false
    @State private var saveFailed = false
    @State private var discardFailed = false
    @FocusState private var focus: Field?
    private enum Field { case title, desc }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let workout {
                    VStack(spacing: Theme.Space.lg) {
                        TimedSummaryContent(workout: workout, showsHeader: false, canEditPhoto: true)
                        editor
                    }
                    .padding(Theme.Space.md)
                } else {
                    ContentUnavailableView("Workout not found", systemImage: "questionmark")
                }
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            // Not "Save …": the session was on disk before this screen appeared.
            .navigationTitle(workout?.type.title ?? "Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Discard", role: .destructive) { confirmDiscard = true }
                        .foregroundStyle(Theme.inkSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }.fontWeight(.bold)
                        .disabled(workout == nil)   // mirrors StrengthSaveView — no confirming a ghost
                }
            }
        }
        .overlay {
            if celebrating {
                // The beat is the exit: draws over the screen, then dismisses it.
                CompletionCelebration(title: "\(workout?.type.title ?? "Session") complete") { onDone() }
            }
        }
        .alert("Couldn't save your details", isPresented: $saveFailed) {
            Button("Try again") { save() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Your session is safe. The name, notes and effort didn't write — your text is still here.")
        }
        .alert("Couldn't discard this session", isPresented: $discardFailed) {
            Button("Try again") { discard() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("It's still in your history. Nothing was deleted.")
        }
        .onAppear {
            guard let workout else { return }
            title = workout.title.isEmpty ? Self.defaultTitle(workout) : workout.title
            desc = workout.note
            effort = workout.perceivedEffort
            // The share moment starts from the athlete's chosen default (never silently public).
        }
        .confirmationDialog("Discard this \(workout?.type.title.lowercased() ?? "activity")?",
                            isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { discard() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("This permanently deletes the recording — it won't be saved to your history.")
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            TextField("Name your \(workout?.type.title.lowercased() ?? "session")", text: $title)
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
            Divider().overlay(Theme.hairline)
            effortRow
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
    }

    private var effortRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("Effort").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                Spacer()
                Text(effortLabel).font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            }
            HStack(spacing: 6) {
                ForEach(1...10, id: \.self) { i in
                    Capsule()
                        .fill((effort ?? 0) >= i ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.hairline))
                        .frame(height: 10)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) { effort = (effort == i ? nil : i) }
                            Haptics.selection()
                        }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Perceived effort")
            .accessibilityValue(effort.map { "\($0) of 10" } ?? "not rated")
        }
    }

    private var effortLabel: String {
        guard let e = effort else { return "Tap to rate" }
        switch e {
        case 1...2: return "Easy"
        case 3...4: return "Steady"
        case 5...6: return "Moderate"
        case 7...8: return "Hard"
        default: return "Max"
        }
    }

    private func save() {
        focus = nil
        // Never celebrate a write that didn't land — the title, notes and effort live only in these
        // fields, and dismissing over a failed save discards what the athlete just typed. A nil
        // workout (query miss) must fail loudly too, not fall through to the success haptic.
        guard let workout else { saveFailed = true; return }
        workout.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        workout.note = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        workout.perceivedEffort = effort
        do { try context.save() } catch { saveFailed = true; return }
        let saved = workout
        Task { await services.health.save(saved) }   // mirror to Apple Health
        // Timed sessions move the streak, session-count, and time-of-day awards (deferred).
        AwardsBook.syncSoon()
        AppReview.recordWorkoutSaved()   // a KEPT workout — engagement toward the rating ask (not discards)
        // See CardioSaveView: fires on the KEPT workout, and is what advances the north-star funnel.
        services.analytics.log(.workoutCompleted(type: saved.type.rawValue))
        // The celebration is the exit: its own haptic fires (no extra success buzz), and it calls
        // `onDone` when the beat completes or is tapped through.
        celebrating = true
    }

    private func discard() {
        focus = nil
        // A silent failure here dismissed anyway, leaving the workout in History for the athlete to
        // discard a second time.
        if let workout {
            // `finish` may have auto-credited a planned session (yoga/pilates days match by
            // discipline) — a discard must not leave that phantom completion on the plan board.
            // Hold the session before the delete (the link won't resolve afterwards), un-credit
            // only once the delete lands (CardioSaveView's exact ordering rule).
            let credited = workout.plannedSession
            context.delete(workout)
            do { try context.save() } catch { discardFailed = true; return }
            if let credited { PlanCoaching.setCompletion(credited, done: false, in: context) }
        }
        Haptics.medium()
        onDone()
    }

    /// "Morning Tennis" / "Evening Yoga" — a friendly default keyed to time of day.
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
