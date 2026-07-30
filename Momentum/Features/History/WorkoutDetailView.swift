import SwiftUI

/// Read-only workout detail (PRD §7.10) — reuses the summary content, pushed within History's
/// `NavigationStack`. Share is available here too.
struct WorkoutDetailView: View {
    @Bindable var workout: Workout
    var weightUnit: WeightUnit = .default()
    var distanceUnit: DistanceUnit = .auto
    @Environment(CoachPresenter.self) private var coach
    @Environment(\.modelContext) private var context

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: Theme.Space.md) {
                Group {
                    if workout.type.isStrengthStyle {
                        StrengthSummaryContent(workout: workout, weightUnit: weightUnit)
                    } else if workout.type.isTimed {
                        TimedSummaryContent(workout: workout)
                    } else {
                        CardioSummaryContent(workout: workout, distanceUnit: distanceUnit)
                    }
                }
                askCoachRow
                // Change your mind later (the save screen's picker, revisitable): flipping the
                // audience re-dirties the workout so the next publish sweep reconciles the post —
                // up on share, DOWN on a downgrade to private. The regret path must be as easy
                // as the share path.
                if CommunityAccess.enabled {
                    ShareVisibilityRow(privacy: $workout.privacy, boxed: true)
                        .onChange(of: workout.privacy) {
                            workout.syncedAt = nil
                            try? context.save()
                        }
                }
            }
            .padding(Theme.Space.md)
        }
        .onAppear {
            #if DEBUG
            // Deterministic sim verification of the time-in-zones card (simctl can't scroll).
            if ProcessInfo.processInfo.arguments.contains("--detail-scroll-zones") {
                // Two attempts — the card's id only exists once its async HR series has loaded.
                for delay in [2.0, 4.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        withAnimation { proxy.scrollTo("timeInZones", anchor: .center) }
                    }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--detail-scroll-coach") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation { proxy.scrollTo("askCoach", anchor: .center) }
                }
            }
            // --detail-scroll-reps: frame the guided-run rep breakdown + pace-review card (website shot).
            if ProcessInfo.processInfo.arguments.contains("--detail-scroll-reps") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { proxy.scrollTo("paceReview", anchor: .top) }
                }
            }
            #endif
        }
        }
        .background(Theme.background)
        .navigationTitle(workout.type.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareButton(workout: workout, weightUnit: weightUnit, distanceUnit: distanceUnit)
            }
        }
    }

    /// Debrief with the coach — the discoverable entry (an inline row beats a toolbar glyph;
    /// this replaced the old sparkles button). Opens the chat pre-typed about THIS workout.
    private var askCoachRow: some View {
        Button {
            Haptics.light()
            let when = workout.startedAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            coach.open(prefill: "About my \(workout.type.title.lowercased()) on \(when): how did it go?",
                       workoutID: workout.id)
        } label: {
            HStack(spacing: Theme.Space.md) {
                BrandMark(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ask your coach")
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("How did this one go? What should change?")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
            .padding(Theme.Space.md)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask your coach about this workout")
        .id("askCoach")
    }

}
