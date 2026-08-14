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
    /// False when the flow that created this workout already booked its completion — funnel event,
    /// review counter, Health mirror, awards, records (the manual-log form does all of that before
    /// presenting this screen). This screen then only names, decorates, and celebrates; booking
    /// twice would double the funnel and write the workout to Apple Health twice.
    var booksCompletion: Bool = true
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
    /// Who sees this activity on the community wall — the share moment (docs/SOCIAL-LAYER.md).
    /// Seeded from the athlete's default; only rendered/committed when `CommunityAccess.enabled`,
    /// so the solo app keeps every workout private exactly as before.
    @State private var privacy: WorkoutPrivacy = .private
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
    /// Content has scrolled under the floating chrome — see `SaveScreenChrome.showsScrim`.
    @State private var scrolledUnderChrome = false
    /// The second discard gate — the point-blank "Are you sure?" (user call 2026-08-14).
    @State private var confirmDiscardFinal = false
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
                    // The scene leads (user call 2026-08-14): the route runs edge-to-edge from the
                    // very top and dissolves into the page; the name and story print over its tail;
                    // the summary follows; the settings close it.
                    VStack(spacing: Theme.Space.lg) {
                        ActivityHero(workout: workout, mapStyleOverride: mapStyle, canAddPhotos: true)
                        Group {
                            titleCard
                            // The cascade plays on arrival now — the celebration moved to Save, so
                            // nothing covers this screen when it appears.
                            CardioSummaryContent(workout: workout, distanceUnit: distanceUnit,
                                                 showsHeader: false, canEditPhoto: true,
                                                 mapStyleOverride: mapStyle,
                                                 showsVerdict: true)
                            detailsCard
                        }
                        .padding(.horizontal, Theme.Space.md)
                    }
                    .padding(.bottom, Theme.Space.md)
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
            #if DEBUG
            // --save-bottom: open pre-scrolled to the editor (route-avatar offer verification —
            // simctl can't scroll). Same trick as Settings' --settings-bottom. --save-center lands
            // mid-page — the analysis charts (pace/speed, splits, HR, elevation) live there.
            .defaultScrollAnchor(ProcessInfo.processInfo.arguments.contains("--save-bottom") ? .bottom
                                 : ProcessInfo.processInfo.arguments.contains("--save-center") ? .center : .top)
            #endif
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            // The hero reaches the physical top of the screen; chrome floats over it (the
            // full-screen map's grammar) instead of a navigation bar.
            .ignoresSafeArea(edges: .top)
            .toolbar(.hidden, for: .navigationBar)
            // The chrome's scrim keys off scroll: invisible while the hero owns the top,
            // materializing once content slides under the clock.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top > 40
            } action: { _, scrolled in
                withAnimation(.easeOut(duration: 0.18)) { scrolledUnderChrome = scrolled }
            }
        }
        .overlay(alignment: .top) {
            SaveScreenChrome(onDone: { save() }, showsScrim: scrolledUnderChrome) {
                // Discard sits behind the menu — as a standing button it made the first thing
                // you saw after finishing a run an invitation to throw it away.
                Button("Discard recording", systemImage: "trash", role: .destructive) {
                    confirmDiscard = true
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
                // Stored distance, NOT the samples relationship — filtering `samples` faulted
                // every LocationSample of a long run on the main actor right as the summary
                // presented (audit 2026-08-11; the earlier fix here had already banished the
                // Kalman replay for the same reason). A route worth a map moved somewhere.
                hasRoute = (workout.gps?.distanceM ?? 0) > 0
                // The share moment starts from the athlete's chosen default (never silently
                // public); a workout that already carries a choice (recovery re-save) keeps it.
                if CommunityAccess.enabled {
                    privacy = workout.privacy == .private
                        ? profiles.first.map(SocialPrivacy.defaultVisibility) ?? .private
                        : workout.privacy
                }
            }
        }
        .confirmationDialog("Discard this \(workout?.type.title.lowercased() ?? "activity")?",
                            isPresented: $confirmDiscard, titleVisibility: .visible) {
            // Two gates, deliberately (user call 2026-08-14): the sheet states the stakes, the
            // alert asks point-blank. A recording is unrecoverable — one slip must not erase it.
            Button("Discard", role: .destructive) { confirmDiscardFinal = true }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("This permanently deletes the recording — it won't be saved to your history.")
        }
        .alert("Are you sure?", isPresented: $confirmDiscardFinal) {
            Button("Yes, discard it", role: .destructive) { discard() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("There's no way to get this \(workout?.type.title.lowercased() ?? "activity") back.")
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

    /// The activity's name and story printed directly on the page under the hero's fade (user
    /// call 2026-08-14) — no card box; the eyebrow names the sport and the moment, the title
    /// sets the page's voice, the description sits quietly beneath a hairline.
    private var titleCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if let workout { ActivityEyebrow(type: sportType, date: workout.startedAt) }
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
            sportRow
            if hasRoute {
                Divider().overlay(Theme.hairline)
                mapStyleRow
            }
            Divider().overlay(Theme.hairline)
            effortRow
            if CommunityAccess.enabled {
                Divider().overlay(Theme.hairline)
                ShareVisibilityRow(privacy: $privacy, boxed: false, showsHint: true)
            }
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
            // The chosen audience — community builds only; the solo app never touches privacy,
            // so a previously-shared workout can't be silently downgraded by a flagless build.
            if CommunityAccess.enabled { $0.privacy = privacy }
            // Recompute on the fresh context so the estimate sees the complete GPS detail.
            $0.calories = CalorieEstimator.kcal(for: $0, bodyMassKg: profiles.first?.bodyMassKg)
        }) else { saveFailed = true; return }
        // Remember the last explicit choice as the new default (Strava's model): the next save
        // seeds from it, so a habitual sharer isn't re-flipping the picker every run.
        if CommunityAccess.enabled, let p = profiles.first, p.defaultWorkoutVisibility != privacy.rawValue {
            p.defaultWorkoutVisibility = privacy.rawValue
            try? context.save()
        }

        // The celebration starts NOW — before any of the post-save bookkeeping below. It used to
        // come last, after a synchronous record scan that Kalman-replays every prior run's
        // samples, so the Done tap froze and the check-and-glow beat started late and dropped
        // frames (2026-08-06 user report: "didn't show the full animation"). The beat needs an
        // idle main thread more than the bookkeeping needs to be first; nothing below is visible.
        celebrating = true
        if booksCompletion {
            AppReview.recordWorkoutSaved()   // a KEPT workout — engagement toward the rating ask (not discards)
            // Analytics fires on the KEPT workout, not on finish: a discarded recording is not a
            // completed workout. `workout_completed` is also what advances the north-star funnel — it
            // was declared in the taxonomy but never logged anywhere, so the funnel could never report
            // `.achieved` (fixed 2026-07-25).
            services.analytics.log(.workoutCompleted(type: workout.type.rawValue))
        }

        // The heavy tail waits out the beat, then runs its detection OFF the main actor. The task
        // holds the reader, so the screen dismissing underneath never cancels or orphans it.
        let styleChanged = mapStyle != initialMapStyle || workout.gps?.mapSnapshotData == nil
        let style = mapStyle
        let readerContext = reader.context
        let container = context.container
        let workoutId = workout.id
        let unit = distanceUnit
        let plan = profiles.first?.plan
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(CompletionCelebration.duration + 0.4))
            // The saved snapshot must match the chosen basemap (grid tile + History thumb) —
            // re-rendered after the beat so the Mapbox snapshotter can't steal its frames; the
            // tile shows the previous image until the new one lands, and the healer covers a
            // failure.
            if styleChanged {
                Task { await WorkoutSnapshotHealer.rerender(workout, style: style, context: readerContext) }
            }
            // Everything below is completion BOOKING — already done by the creating flow when
            // `booksCompletion` is false (the snapshot above is presentation, so it stays).
            guard booksCompletion else { return }
            // Subjective adaptation: how it *felt* nudges the plan (no-shame, ≤1/week, protective
            // only). Plan mutations go through the main context; only scalars are read off `workout`.
            if let note = PlanCoaching.adaptToEffort(workout, plan: plan, in: context) {
                services.notifications.notifyPlanUpdated(title: note.headline, body: note.detail)
                services.notifications.schedulePlannedReminders(plan)
            }
            // Records, detected on a background context (the scan replays the whole history);
            // only the typed values hop back, and the shelf write stays on the reader's context.
            let detected: [(type: PRType, value: Double)] = await Task.detached(priority: .utility) {
                let ctx = ModelContext(container)
                var d = FetchDescriptor<Workout>(predicate: #Predicate { $0.id == workoutId })
                d.fetchLimit = 1
                guard let w = (try? ctx.fetch(d))?.first else { return [] }
                var records = CardioAchievements.detect(for: w, distanceUnit: unit, in: ctx)
                    .compactMap { hit in hit.prType.map { (type: $0, value: hit.value) } }
                // A first-of-discipline workout earns no "you got better" headline (detect guards
                // on an empty prior), yet its own bests must still SEED the record book — mirror
                // how StrengthPRs records the first lift off a 0 baseline. persist dedupes per
                // (type, workout), so a run that also headlined can never double-log.
                if CardioAchievements.isFirstOfType(w, in: ctx) {
                    records += RecordsBook.cardioCandidates(w).map { (type: $0.type, value: $0.value) }
                }
                return records
            }.value
            PersonalRecord.persist(detected.map { (type: $0.type, value: $0.value, exercise: Exercise?.none) },
                                   workout: workout, in: readerContext)
            for record in detected { services.analytics.log(.prHit(type: record.type.rawValue)) }
            // Awards read the whole ledger (distance totals, streak, records) — after the records
            // land, so a record set just now counts toward an unlock.
            AwardsBook.syncSoon()
            // Mirror to Apple Health (no-op unless connected) — but never a zero-content recording
            // (a never-locked GPS run finished by accident has nothing worth exporting).
            if workout.durationS >= 60 || (workout.gps?.distanceM ?? 0) > 0 {
                await services.health.save(workout)
            }
        }
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
