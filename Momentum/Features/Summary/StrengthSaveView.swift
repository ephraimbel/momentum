import SwiftUI
import SwiftData

/// Strava-style "save your workout" screen, shown after a strength session is finished. The athlete
/// names the workout and adds a description over the volume/PR/exercise breakdown, then Save triggers
/// the completion celebration and returns to the app. (Editing-only; History shows the same content
/// read-only via `StrengthSummaryContent`.)
struct StrengthSaveView: View {
    let workoutId: UUID
    var weightUnit: WeightUnit = .default()
    /// False when the flow that created this workout already booked its completion — funnel event,
    /// review counter, Health mirror, awards, records (the manual-log form does all of that before
    /// presenting this screen). This screen then only names, decorates, and celebrates; booking
    /// twice would double the funnel and write the workout to Apple Health twice.
    var booksCompletion: Bool = true
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

    @Query private var profiles: [UserProfile]

    @State private var title = ""
    @State private var desc = ""
    /// Who sees this session on the community wall — see `CardioSaveView.privacy`.
    @State private var privacy: WorkoutPrivacy = .private
    /// Plays after SAVE — see `CardioSaveView.celebrating` (user call 2026-07-23): quiet arrival,
    /// edit, then Done → the circle-and-check beat draws and dismisses the screen.
    @State private var celebrating = false
    @State private var saveFailed = false
    @State private var discardFailed = false
    @State private var confirmDiscard = false
    /// Content has scrolled under the floating chrome — see `SaveScreenChrome.showsScrim`.
    @State private var scrolledUnderChrome = false
    /// The second discard gate — the point-blank "Are you sure?" (user call 2026-08-14).
    @State private var confirmDiscardFinal = false
    /// Session-level perceived effort — the same 1–10 rating the cardio and timed editors collect
    /// (unified 2026-08-14; strength was the one save screen without it).
    @State private var effort: Int?
    @FocusState private var focus: Field?
    private enum Field { case title, desc }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                if let workout {
                    // The scene leads (user call 2026-08-14): the worked body runs edge-to-edge
                    // from the very top and dissolves into the page; the name and story print
                    // over its tail; the summary follows; the settings close it.
                    VStack(spacing: Theme.Space.lg) {
                        ActivityHero(workout: workout, canAddPhotos: true)
                        Group {
                            titleCard
                            // Reveals on arrival — the celebration moved to Save, nothing covers this.
                            StrengthSummaryContent(workout: workout, weightUnit: weightUnit,
                                                   celebratePRs: true, showsHeader: false,
                                                   canEditPhoto: true, showsPlanLine: true)
                            detailsCard.id("strengthEditor")
                        }
                        .padding(.horizontal, Theme.Space.md)
                    }
                    .padding(.bottom, Theme.Space.md)
                    #if DEBUG
                    // Deterministic sim verification of the lower page (exercise bars, week
                    // tonnage card) — simctl can't scroll a headless sim.
                    .onAppear {
                        if ProcessInfo.processInfo.arguments.contains("--strength-save-scroll") {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                withAnimation { proxy.scrollTo("strengthEditor", anchor: .bottom) }
                            }
                        }
                    }
                    #endif
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
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            // The hero reaches the physical top of the screen; chrome floats over it (the
            // full-screen map's grammar) instead of a navigation bar.
            .ignoresSafeArea(edges: .top)
            .toolbar(.hidden, for: .navigationBar)
            // The chrome's scrim keys off scroll — see CardioSaveView.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top > 40
            } action: { _, scrolled in
                withAnimation(.easeOut(duration: 0.18)) { scrolledUnderChrome = scrolled }
            }
            .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard,
                                titleVisibility: .visible) {
                // Two gates, deliberately — see CardioSaveView.
                Button("Discard", role: .destructive) { confirmDiscardFinal = true }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("Every set you logged will be deleted. This can't be undone.")
            }
            .alert("Are you sure?", isPresented: $confirmDiscardFinal) {
                Button("Yes, discard it", role: .destructive) { discard() }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("There's no way to get this workout back.")
            }
            .alert("Couldn't discard", isPresented: $discardFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Something went wrong deleting this workout. Nothing was deleted — try again.")
            }
        }
        .overlay(alignment: .top) {
            SaveScreenChrome(onDone: { save() }, doneDisabled: workout == nil,
                             showsScrim: scrolledUnderChrome) {
                // Discard sits behind the menu (CardioSaveView's rule). Strength had NO discard
                // at all before 2026-08-14 — an accidental empty session could only be deleted
                // by hunting it down in History afterwards.
                Button("Discard workout", systemImage: "trash", role: .destructive) {
                    confirmDiscard = true
                }
            }
        }
        .overlay {
            if celebrating {
                // The beat is the exit: draws over the screen, then dismisses it. Fades in over
                // the summary instead of appearing whole in one frame (same as CardioSaveView).
                CompletionCelebration(title: "Workout complete") { onDone() }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: celebrating)
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
                effort = workout.perceivedEffort
                // The share moment starts from the athlete's chosen default (never silently
                // public); a workout that already carries a choice (recovery re-save) keeps it.
                if CommunityAccess.enabled {
                    privacy = workout.privacy == .private
                        ? profiles.first.map(SocialPrivacy.defaultVisibility) ?? .private
                        : workout.privacy
                }
            }
        }
    }

    /// The session's name and story printed directly on the page under the hero's fade (user
    /// call 2026-08-14) — no card box; see CardioSaveView's titleCard.
    private var titleCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if let workout { ActivityEyebrow(type: workout.type, date: workout.startedAt) }
            TextField("Name your workout", text: $title)
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
            effortRow
            if CommunityAccess.enabled {
                Divider().overlay(Theme.hairline)
                ShareVisibilityRow(privacy: $privacy, boxed: false, showsHint: true)
            }
        }
        .padding(Theme.Space.md)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// The 1–10 effort scale, identical to the timed editor's (unified 2026-08-14).
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

    /// Delete the session outright — CardioSaveView's exact ordering rule: hold the planned
    /// session BEFORE the delete (the relationship won't resolve afterwards), un-credit it only
    /// once the delete has actually landed.
    private func discard() {
        focus = nil
        let session = reader?.workout?.plannedSession
        if let reader, !reader.delete() { discardFailed = true; return }
        if let reader, let session {
            PlanCoaching.setCompletion(session, done: false, in: reader.context)
        }
        Haptics.medium()
        onDone()
    }

    private func save() {
        focus = nil
        // Commit through the reader's own context (where `workout` lives) so the write persists.
        // Never celebrate a write that didn't land: the title and notes exist only in these fields.
        guard let reader, reader.commit({
            $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.note = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.perceivedEffort = effort
            // Community builds only — the solo app never touches privacy (see CardioSaveView).
            if CommunityAccess.enabled { $0.privacy = privacy }
        }) else { saveFailed = true; return }
        // Remember the last explicit choice as the new default (see CardioSaveView).
        if CommunityAccess.enabled, let p = profiles.first, p.defaultWorkoutVisibility != privacy.rawValue {
            p.defaultWorkoutVisibility = privacy.rawValue
            try? context.save()
        }
        // The celebration starts NOW (same order as CardioSaveView, 2026-08-06): the beat gets an
        // idle main thread; the bookkeeping below waits it out — none of it is on screen.
        celebrating = true
        guard booksCompletion else { return }   // already booked by the creating flow — see the flag
        AppReview.recordWorkoutSaved()   // a KEPT workout — engagement toward the rating ask (not discards)
        // See CardioSaveView: fires on the KEPT workout, and is what advances the north-star funnel.
        if let workout { services.analytics.log(.workoutCompleted(type: workout.type.rawValue)) }
        let capturedReader = reader
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(CompletionCelebration.duration + 0.4))
            // Persist the records this session set (fresh context — the logged sets are complete
            // there). Set math only, no GPS replay — fine on the main actor once the beat is done.
            if let workout = capturedReader.workout {
                let hits = StrengthPRs.detect(for: workout, weightUnit: weightUnit, in: capturedReader.context)
                let persisted = hits.compactMap { hit in
                    hit.prType.map { (type: $0, value: hit.value, exercise: hit.exercise) }
                }
                PersonalRecord.persist(persisted, workout: workout, in: capturedReader.context)
                for record in persisted { services.analytics.log(.prHit(type: record.type.rawValue)) }
                // Session count, tonnage, and streak awards move with every kept session.
                AwardsBook.syncSoon()
                await services.health.save(workout)   // mirror to Apple Health
            }
        }
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
        // Re-dirty for sync. `SyncEngine` states the contract — "an edit clears `syncedAt` to
        // re-sync" — but nothing implemented it, and the finish flow dismisses the live screen
        // (waking Today's throttled sweep) BEFORE this editor appears: the un-named workout was
        // routinely uploaded and stamped, so the title, notes, effort and sport correction the
        // athlete then typed never left the device.
        SocialSyncEngine.markEdited(workout)
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
