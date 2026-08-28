import SwiftUI

/// Read-only workout detail (PRD §7.10) — reuses the summary content, pushed within History's
/// `NavigationStack`. Share is available here too.
struct WorkoutDetailView: View {
    @Bindable var workout: Workout
    var weightUnit: WeightUnit = .default()
    var distanceUnit: DistanceUnit = .auto
    @Environment(CoachPresenter.self) private var coach
    @Environment(\.modelContext) private var context
    /// Content has scrolled under the transparent bar — drives the top scrim below.
    @State private var scrolledUnderBar = false
    /// The full editor (name, story, sport, effort, audience, photos) — Strava's "edit activity".
    @State private var editing = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: Theme.Space.md) {
                // The scene leads here too (2026-08-14): the same full-bleed faded hero the save
                // screens wear, running under the (transparent) navigation bar.
                ActivityHero(workout: workout, canAddPhotos: true)
                // Photos are editable from History too (2026-08-14, Strava parity): the photo you
                // took mid-run often lands on the phone AFTER the save screen is gone, and a
                // memory attached a week later is exactly the point. `WorkoutPhotoSection`
                // re-dirties sync on every mutation, so late photos still publish.
                Group {
                    if workout.type.isStrengthStyle {
                        StrengthSummaryContent(workout: workout, weightUnit: weightUnit,
                                               canEditPhoto: true)
                    } else if workout.type.isTimed {
                        TimedSummaryContent(workout: workout, canEditPhoto: true)
                    } else {
                        CardioSummaryContent(workout: workout, distanceUnit: distanceUnit,
                                             canEditPhoto: true)
                    }
                    askCoachRow
                    // Change your mind later (the save screen's picker, revisitable): flipping the
                    // audience re-dirties the workout so the next publish sweep reconciles the post —
                    // up on share, DOWN on a downgrade to private. The regret path must be as easy
                    // as the share path.
                    if CommunityAccess.enabled {
                        ShareVisibilityRow(privacy: $workout.privacy, boxed: true)
                            .onChange(of: workout.privacy) {
                                // `markEdited`, not a bare `syncedAt = nil`: narrowing Everyone →
                                // Friends leaves the workout SHARED, so the old publish stamp
                                // survived and the sweep did nothing — the server kept serving the
                                // post to everyone. Clearing the stamp re-upserts it at the new
                                // audience. A downgrade all the way to private still keeps its
                                // stamp, which is what makes the sweep delete the post.
                                SocialSyncEngine.markEdited(workout)
                                try? context.save()
                            }
                    }
                }
                .padding(.horizontal, Theme.Space.md)
            }
            .padding(.bottom, Theme.Space.md)
        }
        // The hero draws under the transparent bar; the back button floats over the scene.
        .ignoresSafeArea(edges: .top)
        .toolbarBackground(.hidden, for: .navigationBar)
        // Everything the save editor asked for, askable again for as long as the activity exists.
        // The inline controls below stay: audience and photos are the two things people reach for
        // most, and making them a two-tap trip through a sheet would be worse. This is for the
        // rest — the name, the story, a mis-logged sport, the effort nobody rates mid-cooldown.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = true } label: { Text("Edit") }
                    .accessibilityLabel("Edit activity")
            }
        }
        .sheet(isPresented: $editing) { ActivityEditView(workout: workout) }
        // Same scrim contract as the save screens' chrome: invisible while the hero owns the
        // top, materializing once content scrolls under the bar so text fades out beneath it.
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top > 40
        } action: { _, scrolled in
            withAnimation(.easeOut(duration: 0.18)) { scrolledUnderBar = scrolled }
        }
        .overlay(alignment: .top) {
            LinearGradient(colors: [Theme.background.opacity(0.96),
                                    Theme.background.opacity(0.85),
                                    Theme.background.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 90)
                .ignoresSafeArea(edges: .top)
                .opacity(scrolledUnderBar ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onAppear {
            #if DEBUG
            // `--activity-edit`: open the editor straight away — simctl can't tap a toolbar button.
            if ProcessInfo.processInfo.arguments.contains("--activity-edit"), !editing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { editing = true }
            }
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
            .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask your coach about this workout")
        .id("askCoach")
    }

}
