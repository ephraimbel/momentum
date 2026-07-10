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
    @Environment(Services.self) private var services
    @Query private var profiles: [UserProfile]
    // Read the just-finished workout from a FRESH context (same rationale as StrengthSaveView): the
    // GPS samples, HR series, and finish-time attachments were written by the background
    // @ModelActor store, and the main context can still hold a stale mid-run copy — which would
    // render a partial route / blank charts here even though the disk data is complete.
    @State private var reader: FinishedWorkoutReader?
    private var workout: Workout? { reader?.workout }

    @State private var title = ""
    @State private var desc = ""
    @State private var sportType: WorkoutType = .run
    @State private var effort: Int?
    @State private var visibility: WorkoutPrivacy = .private
    @State private var celebrating = false
    @State private var confirmDiscard = false
    @FocusState private var focus: Field?
    private enum Field { case title, desc }

    /// Only the GPS disciplines — you can correct a Run to a Walk, but never to Strength (a
    /// strength workout carries a different relationship and is recorded through a different flow).
    private static let cardioTypes = WorkoutType.allCases.filter(\.isGPS)

    var body: some View {
        NavigationStack {
            ScrollView {
                if let workout {
                    // Reveal first, name last: the payoff leads; the editor sits quietly at the bottom.
                    VStack(spacing: Theme.Space.lg) {
                        CardioSummaryContent(workout: workout, distanceUnit: distanceUnit, showsHeader: false)
                        editor
                    }
                    .padding(Theme.Space.md)
                } else if reader != nil {
                    ContentUnavailableView("Workout not found", systemImage: "questionmark")
                } else {
                    ProgressView().padding(.top, Theme.Space.xxl)
                }
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Save \(workout?.type.title.lowercased() ?? "activity")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Discard", role: .destructive) { confirmDiscard = true }
                        .foregroundStyle(Theme.inkSecondary)
                }
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
        .task {
            guard reader == nil else { return }
            let reader = FinishedWorkoutReader(container: context.container, workoutId: workoutId)
            self.reader = reader
            if let workout = reader.workout {
                title = workout.title.isEmpty ? Self.defaultTitle(workout) : workout.title
                desc = workout.note
                sportType = workout.type
                effort = workout.perceivedEffort
                // The share moment starts from the athlete's chosen default (never silently public).
                visibility = profiles.first.map(SocialPrivacy.defaultVisibility) ?? workout.privacy
            }
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
            TextField("Name your \(sportType.title.lowercased())", text: $title)
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
            sportRow
            Divider().overlay(Theme.hairline)
            effortRow
            Divider().overlay(Theme.hairline)
            ShareVisibilityRow(privacy: $visibility, boxed: false, showsHint: true)
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
    }

    /// Correct the discipline if it was logged as the wrong sport (Run ↔ Walk ↔ Hike ↔ Ride).
    private var sportRow: some View {
        HStack {
            Text("Activity").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            Spacer()
            Menu {
                ForEach(Self.cardioTypes) { t in
                    Button { sportType = t; Haptics.selection() } label: { Label(t.title, systemImage: t.systemImage) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: sportType.systemImage)
                    Text(sportType.title).font(.rounded(Theme.FontSize.body, weight: .bold))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(Theme.ink)
            }
        }
    }

    /// Perceived effort (RPE 1–10) — a one-tap meter. Optional; tap the active bar to clear it.
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
        if let reader, let workout = reader.workout {
            reader.commit {
                $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                $0.note = desc.trimmingCharacters(in: .whitespacesAndNewlines)
                $0.type = sportType
                $0.perceivedEffort = effort
                $0.privacy = visibility
                // Recompute on the fresh context so the estimate sees the complete GPS detail.
                $0.calories = CalorieEstimator.kcal(for: $0, bodyMassKg: profiles.first?.bodyMassKg)
            }
            // Subjective adaptation: how it *felt* nudges the plan (no-shame, ≤1/week, protective
            // only). Plan mutations go through the main context; only scalars are read off `workout`.
            if let note = PlanCoaching.adaptToEffort(workout, plan: profiles.first?.plan, in: context) {
                services.notifications.notifyPlanUpdated(title: note.headline, body: note.detail)
                services.notifications.schedulePlannedReminders(profiles.first?.plan)
            }
            // Persist any records this run set (detected against the fresh context, so the samples
            // are complete) — the PR shelf is what the "PRs" stat counts.
            let hits = CardioAchievements.detect(for: workout, distanceUnit: distanceUnit, in: reader.context)
            PersonalRecord.persist(hits.compactMap { hit in
                hit.prType.map { (type: $0, value: hit.value, exercise: nil) }
            }, workout: workout, in: reader.context)
            // Mirror to Apple Health (no-op unless connected) — but never a zero-content recording
            // (a never-locked GPS run finished by accident has nothing worth exporting).
            if workout.durationS >= 60 || (workout.gps?.distanceM ?? 0) > 0 {
                let saved = workout
                Task { await services.health.save(saved) }
            }
        }
        Haptics.success()
        withAnimation(.easeOut(duration: 0.2)) { celebrating = true }
    }

    /// Throw the recording away (an explicit user action — distinct from the never-destroy-on-edit
    /// rule). The workout is already persisted at this point, so deleting it cascades to its GPS
    /// detail, samples, and splits; the recovery marker was cleared when the workout finished.
    private func discard() {
        focus = nil
        reader?.delete()
        Haptics.medium()
        onDone()
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
