import SwiftUI
import SwiftData

/// Strava-style "save your run" screen, shown after a cardio workout is finished. The athlete names
/// the activity and adds a description over the route + stats, then Save triggers the completion
/// celebration and returns to the app. (Editing-only entry point; History shows the same content
/// read-only via `CardioSummaryContent`.)
struct CardioSaveView: View {
    let workoutId: UUID
    var distanceUnit: DistanceUnit = .auto
    /// Known from the launch, so the celebration can name the discipline on the very first frame —
    /// the reader hasn't loaded yet at that point, and a ride shouldn't read "Run complete".
    var workoutType: WorkoutType = .run
    /// The athlete's week and the arc this session added, computed at finish. nil (history, crash
    /// recovery, the debug harness) falls back to a plain sweep.
    var weekRing: WeekRing.Reading? = nil
    var onDone: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @Environment(PaywallController.self) private var paywall
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
    /// The map style THIS run renders with — previewed live on the hero map, persisted on Save.
    @State private var mapStyle: MapStyleOption = .persisted
    @State private var initialMapStyle: MapStyleOption = .persisted
    /// Plays after SAVE (user call 2026-07-23, reversing the earlier play-on-arrival order):
    /// arrival goes straight to the summary + editor, and the beat crowns the finished, named
    /// post on the way out — Done → circle-and-check draw → dismiss.
    @State private var celebrating = false
    @State private var saveFailed = false
    @State private var discardFailed = false
    @State private var confirmDiscard = false
    @FocusState private var focus: Field?
    private enum Field { case title, desc }

    /// Only the GPS disciplines — you can correct a Run to a Walk, but never to Strength (a
    /// strength workout carries a different relationship and is recorded through a different flow).
    private static let cardioTypes = WorkoutType.allCases.filter(\.isGPS)

    var body: some View {
        @Bindable var paywall = paywall
        return NavigationStack {
            ScrollView {
                if let workout {
                    // Reveal first, name last: the payoff leads; the editor sits quietly at the bottom.
                    VStack(spacing: Theme.Space.lg) {
                        // The cascade plays on arrival now — the celebration moved to Save, so
                        // nothing covers this screen when it appears.
                        CardioSummaryContent(workout: workout, distanceUnit: distanceUnit,
                                             showsHeader: false, canEditPhoto: true,
                                             mapStyleOverride: mapStyle,
                                             showsVerdict: true)
                        editor
                    }
                    .padding(Theme.Space.md)
                } else if reader != nil {
                    // A dead-end error screen on a fullScreenCover is a trap — Done/Discard both
                    // only raise alerts here, so this state needs its own way out (mirrors
                    // StrengthSaveView's Close).
                    ContentUnavailableView {
                        Label("Workout not found", systemImage: "questionmark")
                    } description: {
                        Text("This session couldn't be loaded.")
                    } actions: {
                        Button("Close") { onDone() }
                    }
                } else {
                    ProgressView().padding(.top, Theme.Space.xxl)
                }
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            // Not "Save run": the recording was already on disk before this screen appeared, so a
            // filing verb described work the athlete wasn't doing and framed their run as paperwork.
            .navigationTitle(workout?.type.title ?? workoutType.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Discard sits behind a menu now. As a standing top-left button it made the
                    // first thing you saw after finishing a run an invitation to throw it away.
                    Menu {
                        Button("Discard recording", systemImage: "trash", role: .destructive) {
                            confirmDiscard = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(Theme.inkSecondary)
                    }
                    .accessibilityLabel("More options")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }.fontWeight(.bold)
                }
            }
        }
        .overlay {
            if celebrating {
                // The ring sweeps across the athlete's week — the arc it travels is this session —
                // and the beat closes the screen when it's done. `sportType`, not `workoutType`:
                // the athlete may have just corrected the discipline in the editor.
                CompletionCelebration(title: "\(sportType.title) complete",
                                      ring: weekRing.map { (from: $0.from, to: $0.to) },
                                      caption: weekCaption) { onDone() }
            }
        }
        // The recording itself is already on disk — only these edits failed to write. Say that
        // plainly and keep the athlete here with their text, rather than dismissing over the loss.
        .alert("Couldn't save your details", isPresented: $saveFailed) {
            Button("Try again") { save() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Your route and every metric are safe. The name, notes and effort didn't write — your text is still here.")
        }
        .alert("Couldn't discard this recording", isPresented: $discardFailed) {
            Button("Try again") { discard() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("It's still in your history. Nothing was deleted.")
        }
        // The save screen is itself a fullScreenCover — RootView's app-level paywall cover cannot
        // present on top of it, so the Pro map-style gate needs its own host here.
        .fullScreenCover(item: $paywall.presentedFeature) { feature in
            PaywallView(feature: feature)
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
                mapStyle = workout.gps?.mapStyle ?? .persisted
                initialMapStyle = mapStyle
                hasRoute = (workout.gps?.routeCoordinates(type: workout.type).count ?? 0) > 1
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

    /// The ring's legend. Without it the sweep is just a shape moving; with it the athlete can see
    /// exactly what they added and what's left. The "week complete" line is the one earned claim
    /// here, and only the session that actually crossed the line gets to make it.
    private var weekCaption: String? {
        guard let ring = weekRing else { return nil }
        // Whole units on both sides. A prescribed week summed to 19.88 mi and the caption read
        // "16 of 19.88 mi this week" — false precision on a target nobody set to two decimals.
        let target = Formatters.wholeDistance(meters: ring.targetM, unit: distanceUnit)
        if ring.closedTheWeek { return "\(target.value) \(target.unit) — week complete" }
        // The completed side FLOORS rather than rounds. Rounding both independently printed
        // "32 of 32 km this week" under a ring visibly short of full, whenever the week landed
        // within half a unit of target. Flooring can only ever understate what's banked.
        let per = distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000
        return "\(Int(ring.completedM / per)) of \(target.value) \(target.unit) this week"
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
            if hasRoute {
                Divider().overlay(Theme.hairline)
                mapStyleRow
            }
            Divider().overlay(Theme.hairline)
            effortRow
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

    /// Computed ONCE when the workout loads — `routeCoordinates` maps every GPS sample, far too
    /// heavy to run per body evaluation (every keystroke while naming the run re-evaluates body).
    @State private var hasRoute = false

    /// The basemap this run's map renders with — previewed live on the hero map above and saved
    /// with the workout (grid tile, History, feed post). Pro styles are the upgrade moment: tapping
    /// one without entitlement opens the paywall instead of applying.
    private var mapStyleRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Map style").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(MapStyleOption.pickable) { option in
                        styleChip(option)
                    }
                }
            }
        }
    }

    private func styleChip(_ option: MapStyleOption) -> some View {
        let locked = option.requiresPro && !paywall.isEntitled(to: .mapStyles)
        let selected = option == mapStyle
        return Button {
            if locked { paywall.present(for: .mapStyles); return }
            withAnimation(.easeOut(duration: 0.15)) { mapStyle = option }
            Haptics.selection()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: locked ? "lock.fill" : option.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(option.label).font(.rounded(Theme.FontSize.caption, weight: .semibold))
            }
            .foregroundStyle(selected ? Theme.background : Theme.ink)
            .padding(.horizontal, Theme.Space.md).padding(.vertical, 7)
            .background(Capsule().fill(selected ? AnyShapeStyle(Theme.ink)
                                       : (locked ? AnyShapeStyle(Theme.route.opacity(0.16)) : AnyShapeStyle(Theme.background))))
            .overlay(Capsule().stroke(selected ? Color.clear : (locked ? Theme.route.opacity(0.45) : Theme.hairline)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(locked ? "\(option.label), Pro style" : option.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
        // Never celebrate a write that didn't land. Title, notes, sport, effort and map style exist
        // only in these fields until the commit succeeds — this used to fall straight through to the
        // celebration and dismiss, taking all five with it, whether the store rejected the write or
        // the workout had never loaded at all.
        guard let reader, let workout = reader.workout else { saveFailed = true; return }
        guard reader.commit({
            $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.note = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.type = sportType
            $0.perceivedEffort = effort
            $0.gps?.mapStyleRaw = mapStyle.rawValue
            // Recompute on the fresh context so the estimate sees the complete GPS detail.
            $0.calories = CalorieEstimator.kcal(for: $0, bodyMassKg: profiles.first?.bodyMassKg)
        }) else { saveFailed = true; return }

        // The saved snapshot must match the chosen basemap (grid tile + History thumb). Re-render
        // off the save path when the style changed (or the finish-time render failed); the tile
        // shows the previous image until the new one lands, and the healer covers a failure.
        if mapStyle != initialMapStyle || workout.gps?.mapSnapshotData == nil {
            let style = mapStyle
            let readerContext = reader.context
            Task { await WorkoutSnapshotHealer.rerender(workout, style: style, context: readerContext) }
        }
        // Subjective adaptation: how it *felt* nudges the plan (no-shame, ≤1/week, protective
        // only). Plan mutations go through the main context; only scalars are read off `workout`.
        if let note = PlanCoaching.adaptToEffort(workout, plan: profiles.first?.plan, in: context) {
            services.notifications.notifyPlanUpdated(title: note.headline, body: note.detail)
            services.notifications.schedulePlannedReminders(profiles.first?.plan)
        }
        // Persist any records this run set (detected against the fresh context, so the samples
        // are complete) — the PR shelf is what the "PRs" stat counts.
        let recordsContext = reader.context
        var records: [(type: PRType, value: Double, exercise: Exercise?)] =
            CardioAchievements.detect(for: workout, distanceUnit: distanceUnit, in: recordsContext)
                .compactMap { hit in hit.prType.map { (type: $0, value: hit.value, exercise: Exercise?.none) } }
        // A first-of-discipline workout earns no "you got better" headline (detect guards on an
        // empty prior), yet its own bests must still SEED the record book — mirror how StrengthPRs
        // records the first lift off a 0 baseline. persist dedupes per (type, workout), so a run
        // that also headlined can never double-log.
        if CardioAchievements.isFirstOfType(workout, in: recordsContext) {
            records += RecordsBook.cardioCandidates(workout)
                .map { (type: $0.type, value: $0.value, exercise: Exercise?.none) }
        }
        PersonalRecord.persist(records, workout: workout, in: recordsContext)
        // Awards read the whole ledger (distance totals, streak, records) — deferred so the
        // walk never delays this dismissal, and the unlock presents on the destination screen.
        AwardsBook.syncSoon()
        // Mirror to Apple Health (no-op unless connected) — but never a zero-content recording
        // (a never-locked GPS run finished by accident has nothing worth exporting).
        if workout.durationS >= 60 || (workout.gps?.distanceM ?? 0) > 0 {
            let saved = workout
            Task { await services.health.save(saved) }
        }
        AppReview.recordWorkoutSaved()   // a KEPT workout — engagement toward the rating ask (not discards)
        // Analytics fires on the KEPT workout, not on finish: a discarded recording is not a
        // completed workout. `workout_completed` is also what advances the north-star funnel — it
        // was declared in the taxonomy but never logged anywhere, so the funnel could never report
        // `.achieved` (fixed 2026-07-25).
        services.analytics.log(.workoutCompleted(type: workout.type.rawValue))
        for record in records { services.analytics.log(.prHit(type: record.type.rawValue)) }
        // The celebration is the exit: it draws over this screen (its own haptic fires — no extra
        // success buzz here) and calls `onDone` when the beat completes or is tapped through.
        celebrating = true
    }

    /// Throw the recording away (an explicit user action — distinct from the never-destroy-on-edit
    /// rule). The workout is already persisted at this point, so deleting it cascades to its GPS
    /// detail, samples, and splits; the recovery marker was cleared when the workout finished.
    private func discard() {
        focus = nil
        // Un-credit the plan before the cascade: `finish` may have marked a planned session complete
        // off this run. A discard must not leave that phantom completion behind — reopen the session
        // and sever the link (the inverse of `PlanCoaching.markComplete`), through the same fresh
        // context so the relationship resolves. Do this before delete, while the link still exists.
        // Hold the planned session BEFORE the delete (the relationship won't resolve afterwards),
        // but un-credit it only once the delete has actually landed. Reversing the credit first meant
        // a failed delete left the plan session reopened while the alert said "Nothing was deleted" —
        // the workout still in History, its plan credit silently gone.
        let session = reader?.workout?.plannedSession
        if let reader, !reader.delete() { discardFailed = true; return }
        if let reader, let session {
            PlanCoaching.setCompletion(session, done: false, in: reader.context)
        }
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
