import SwiftUI
import SwiftData

/// Edit an activity you already saved (2026-08-22, Strava parity).
///
/// The save editor is a one-shot moment at the end of a workout, and the athlete is rarely in the
/// mood to write there: the photo is still uploading off the watch, the name is whatever the app
/// suggested, and the audience was whatever the default happened to be. Everything on that screen
/// is editable here, afterwards, for as long as the activity exists — including the audience, which
/// is the one people most often want back.
///
/// **Staging:** the text fields, sport, effort and audience are staged and land on Save; Cancel
/// throws them away. Photos are the deliberate exception — `WorkoutPhotoSection` writes straight
/// through, exactly as it does on the save screens and on the detail page, so a photo is attached
/// the moment it is picked and is never lost to a mistaken Cancel.
///
/// **Propagation:** Save routes through `SocialSyncEngine.markEdited`, which re-dirties sync and —
/// for a workout that is still shared — clears the publish stamp so the sweep UPSERTS the updated
/// post. Without that an edit to an already-published activity stayed on the device forever.
struct ActivityEditView: View {
    @Bindable var workout: Workout

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]

    // Staged edits. Seeded once from the workout, committed by `save()`.
    @State private var title = ""
    @State private var desc = ""
    @State private var sportType: WorkoutType = .run
    @State private var effort: Int?
    @State private var privacy: WorkoutPrivacy = .private
    @State private var loaded = false
    @State private var saveFailed = false
    /// Cancel with typed-but-unsaved text asks before throwing it away.
    @State private var confirmDiscard = false

    @FocusState private var focus: Field?
    private enum Field { case title, desc }

    /// Only the GPS disciplines may be corrected into one another — the same rule the save editor
    /// uses, for the same reason: a strength workout carries a different relationship entirely and
    /// a timed session has no route, so "correcting" either into a run would describe a workout
    /// that never happened.
    private static let cardioTypes = WorkoutType.allCases.filter(\.isGPS)
    private var canChangeSport: Bool { workout.type.isGPS }

    /// Has the athlete actually changed a STAGED field? Photos are excluded on purpose — they
    /// write through the moment they're picked, so they can never be "unsaved". Drives both the
    /// Save button's enablement and the discard guard, so the two can never disagree about
    /// whether there is anything to lose.
    private var hasUnsavedChanges: Bool {
        guard loaded else { return false }
        return title.trimmingCharacters(in: .whitespacesAndNewlines) != workout.title
            || desc.trimmingCharacters(in: .whitespacesAndNewlines) != workout.note
            || sportType != workout.type
            || effort != workout.perceivedEffort
            || (CommunityAccess.enabled && privacy != workout.privacy)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Space.lg) {
                    titleCard
                    detailsCard
                    // Writes immediately (see the note on this type) — that is why it sits below
                    // the staged fields rather than among them.
                    WorkoutPhotoSection(workout: workout, canEdit: true)
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.top, Theme.Space.md)
                .padding(.bottom, Theme.Space.xl)
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Never discard typed work on a single tap. A long note is the thing people
                    // most regret losing here, and Cancel sat one thumb-width from Save.
                    Button("Cancel") {
                        if hasUnsavedChanges { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Quiet when there is nothing to save — a live Save that does nothing teaches
                    // the athlete their tap didn't register.
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!hasUnsavedChanges)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focus = nil }
                }
            }
            // The activity itself is untouched — only these fields failed to write. Say so and keep
            // the athlete here with their text, the same contract the save editor honors.
            .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard,
                                titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Any photos you added are already saved.")
            }
            .alert("Couldn't save your changes", isPresented: $saveFailed) {
                Button("Try again") { save() }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("Your activity and every metric are safe. The name, notes and audience didn't write — your text is still here.")
            }
        }
        .onAppear(perform: seed)
    }

    // MARK: Fields

    /// Name and story, in the save editor's own voice so the two screens read as one surface.
    private var titleCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ActivityEyebrow(type: sportType, date: workout.startedAt)
            TextField("Name your \(sportType.title.lowercased())", text: $title)
                .font(.display(30, weight: .black))
                .foregroundStyle(Theme.ink)
                .focused($focus, equals: .title)
                .submitLabel(.done)
            Divider().overlay(Theme.hairline).padding(.vertical, 2)
            TextField("How did it go — and why did this one matter?", text: $desc, axis: .vertical)
                .font(.rounded(Theme.FontSize.body, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(2...6)
                .focused($focus, equals: .desc)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if canChangeSport {
                sportRow
                Divider().overlay(Theme.hairline)
            }
            effortRow
            if CommunityAccess.enabled {
                Divider().overlay(Theme.hairline)
                ShareVisibilityRow(privacy: $privacy, boxed: false, showsHint: true)
            }
        }
        .padding(Theme.Space.md)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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

    // MARK: Commit

    /// Seed the staged fields once. Guarded: `onAppear` fires again when the sheet returns from a
    /// photo picker, and re-seeding there would silently discard everything typed so far.
    private func seed() {
        guard !loaded else { return }
        loaded = true
        title = workout.title
        desc = workout.note
        sportType = workout.type
        effort = workout.perceivedEffort
        privacy = workout.privacy
    }

    private func save() {
        focus = nil
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        workout.title = trimmedTitle
        workout.note = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        workout.type = sportType
        workout.perceivedEffort = effort
        // Community builds only, exactly as the save editor gates it: a flagless build must never
        // silently downgrade an audience the athlete chose in a build that had the picker.
        if CommunityAccess.enabled { workout.privacy = privacy }
        // The sport drives the estimate, so a Run corrected to a Hike has to be re-costed or the
        // calorie figure keeps describing the workout the athlete just said this wasn't.
        workout.calories = CalorieEstimator.kcal(for: workout, bodyMassKg: profiles.first?.bodyMassKg)
        // Re-dirty for sync AND, while still shared, drop the publish stamp so the sweep upserts the
        // updated post. This is the whole point of the screen: an edit that never leaves the device
        // is not an edit.
        SocialSyncEngine.markEdited(workout)
        do { try context.save() } catch { saveFailed = true; return }
        Haptics.success()
        dismiss()
    }
}
