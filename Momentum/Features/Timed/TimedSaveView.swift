import SwiftUI
import SwiftData

/// "Save your session" for a timed activity — name it, add a note and effort over the duration, then
/// Save triggers the completion celebration. (Editing entry point; History shows the same content
/// read-only via `TimedSummaryContent`.)
struct TimedSaveView: View {
    let workoutId: UUID
    /// False when the flow that created this workout already booked its completion (funnel event,
    /// review counter, Health mirror, awards — the manual-log form does all of that before
    /// presenting this screen). This screen then only names, decorates, and celebrates.
    var booksCompletion: Bool = true
    var onDone: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @Query private var workouts: [Workout]
    @Query private var profiles: [UserProfile]
    private var workout: Workout? { workouts.first { $0.id == workoutId } }

    @State private var title = ""
    @State private var desc = ""
    @State private var effort: Int?
    /// The calorie readout — Health-measured when the Watch has numbers for the window, estimated
    /// otherwise, and always the athlete's to overtype (owner ask 2026-07-30).
    @State private var kcal: Double?
    /// True while the shown number is the wearable's own measurement. Cleared the moment the
    /// athlete types their own — and used to keep a Health-sourced number from being mirrored BACK
    /// into Health as a second energy sample (double-counting the Move ring).
    @State private var kcalFromHealth = false
    /// The athlete typed this number themselves (this screen or a prior save) — the subtitle says so.
    @State private var kcalEdited = false
    /// Stationary e-bike console readouts (owner ask 2026-08-05): distance and elevation typed
    /// off the machine, avg speed computed from them. Meters/SI in state; converted at display.
    @State private var rideDistanceM: Double = 0
    @State private var rideElevationM: Double = 0
    private var showsRideDetails: Bool { workout?.type.tracksDistance == true }
    private var distanceUnit: DistanceUnit { DistanceUnit.auto.resolved() }
    /// Who sees this session on the community wall — see `CardioSaveView.privacy`.
    @State private var privacy: WorkoutPrivacy = .private
    /// Plays after SAVE — see `CardioSaveView.celebrating` (user call 2026-07-23).
    @State private var celebrating = false
    @State private var confirmDiscard = false
    /// Content has scrolled under the floating chrome — see `SaveScreenChrome.showsScrim`.
    @State private var scrolledUnderChrome = false
    /// The second discard gate — the point-blank "Are you sure?" (user call 2026-08-14).
    @State private var confirmDiscardFinal = false
    @State private var saveFailed = false
    @State private var discardFailed = false
    @FocusState private var focus: Field?
    private enum Field { case title, desc }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let workout {
                    // The scene leads (user call 2026-08-14): the sport's glyph band runs from the
                    // very top and dissolves into the page; the name and story print over its
                    // tail; the summary follows; the settings close it.
                    VStack(spacing: Theme.Space.lg) {
                        ActivityHero(workout: workout, canAddPhotos: true)
                        Group {
                            titleCard
                            TimedSummaryContent(workout: workout, showsHeader: false, canEditPhoto: true,
                                                showsCalories: false, showsPlanLine: true)
                            detailsCard
                        }
                        .padding(.horizontal, Theme.Space.md)
                    }
                    .padding(.bottom, Theme.Space.md)
                } else {
                    ContentUnavailableView("Workout not found", systemImage: "questionmark")
                }
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            // Not "Save …": the session was on disk before this screen appeared.
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
        }
        .overlay(alignment: .top) {
            SaveScreenChrome(onDone: { save() }, doneDisabled: workout == nil,
                             showsScrim: scrolledUnderChrome) {
                // Discard sits behind the menu — as a standing button it made the first thing
                // you saw after finishing an invitation to throw it away.
                Button("Discard session", systemImage: "trash", role: .destructive) {
                    confirmDiscard = true
                }
            }
        }
        .overlay {
            if celebrating {
                // The beat is the exit: draws over the screen, then dismisses it. Fades in over
                // the summary instead of appearing whole in one frame (same as CardioSaveView).
                CompletionCelebration(title: "\(workout?.type.title ?? "Session") complete") { onDone() }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: celebrating)
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
            prefillCalories(workout)
            // Recovery re-save of an e-bike session keeps its earlier console readouts.
            rideDistanceM = workout.gps?.distanceM ?? 0
            rideElevationM = workout.gps?.elevationGainM ?? 0
            // The share moment starts from the athlete's chosen default (never silently
            // public); a workout that already carries a choice (recovery re-save) keeps it.
            if CommunityAccess.enabled {
                privacy = workout.privacy == .private
                    ? profiles.first.map(SocialPrivacy.defaultVisibility) ?? .private
                    : workout.privacy
            }
        }
        .confirmationDialog("Discard this \(workout?.type.title.lowercased() ?? "activity")?",
                            isPresented: $confirmDiscard, titleVisibility: .visible) {
            // Two gates, deliberately — see CardioSaveView.
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

    /// The session's name and story printed directly on the page under the hero's fade (user
    /// call 2026-08-14) — no card box; see CardioSaveView's titleCard.
    private var titleCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if let workout { ActivityEyebrow(type: workout.type, date: workout.startedAt) }
            TextField("Name your \(workout?.type.title.lowercased() ?? "session")", text: $title)
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
            if showsRideDetails {
                Divider().overlay(Theme.hairline)
                distanceRow
                Divider().overlay(Theme.hairline)
                elevationRow
                if let speed = avgSpeedText {
                    Divider().overlay(Theme.hairline)
                    readonlyRow("Avg speed", speed, subtitle: "From distance and duration")
                }
            }
            Divider().overlay(Theme.hairline)
            calorieRow
            if CommunityAccess.enabled {
                Divider().overlay(Theme.hairline)
                ShareVisibilityRow(privacy: $privacy, boxed: false, showsHint: true)
            }
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

    // MARK: Ride details — the stationary e-bike's console readouts

    /// Distance off the machine — tap to type. Half-unit precision is plenty for a console readout.
    private var distanceRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Distance")
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                Text("From the console — tap to enter")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
            TypableNumber(display: rideDistanceM > 0
                            ? Formatters.distanceNumeral(rideDistanceM / perUnit) : "—",
                          minWidth: 58, axID: "ride-distance-value") { typed in
                guard let v = Double(typed.replacingOccurrences(of: ",", with: ".")), v > 0 else { return }
                rideDistanceM = min(v, 500) * perUnit
            }
            Text(distanceUnit == .imperial ? "MI" : "KM")
                .font(.rounded(Theme.FontSize.label, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
        }
    }

    /// Elevation gain, for consoles that simulate climbs. Optional — most readouts won't have one.
    private var elevationRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Elevation gain")
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                Text("If your console shows one")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
            TypableNumber(display: rideElevationM > 0
                            ? "\(Int((rideElevationM * elevationPerUnit).rounded()))" : "—",
                          minWidth: 58, axID: "ride-elevation-value") { typed in
                guard let v = Double(typed.filter(\.isNumber)), v > 0 else { return }
                rideElevationM = min(v, 20_000) / elevationPerUnit
            }
            Text(distanceUnit == .imperial ? "FT" : "M")
                .font(.rounded(Theme.FontSize.label, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
        }
    }

    private func readonlyRow(_ label: String, _ value: String, subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                Text(subtitle)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
            Text(value)
                .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                .foregroundStyle(Theme.ink)
        }
    }

    /// Meters per display unit for distance entry.
    private var perUnit: Double { distanceUnit == .imperial ? Formatters.metersPerMile : 1000 }
    /// Display units per meter for elevation entry (ft when imperial).
    private var elevationPerUnit: Double { distanceUnit == .imperial ? 3.28084 : 1 }

    /// Avg speed the moment both numbers exist — computed, never typed, so it can't disagree.
    private var avgSpeedText: String? {
        guard rideDistanceM > 0, let w = workout, w.durationS > 0 else { return nil }
        return Formatters.speed(ms: CardioMetrics.averageSpeedMS(distanceM: rideDistanceM,
                                                                 durationS: w.durationS),
                                unit: distanceUnit)
    }

    /// Calories over the session — tap the number to type your own. The subtitle is honest about
    /// where the number came from: the Watch's measurement, our estimate, or the athlete's own entry.
    private var calorieRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Calories")
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                Text(kcalFromHealth ? "From Apple Health"
                     : kcalEdited ? "Your entry"
                     : "Estimated — tap to adjust")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
            TypableNumber(display: kcal.map { "\(Int($0))" } ?? "—", minWidth: 58,
                          axID: "calorie-value") { typed in
                guard let v = Double(typed.filter(\.isNumber)), v > 0 else { return }
                kcal = min(v, 9_999)
                kcalFromHealth = false
                kcalEdited = true
            }
            Text("KCAL")
                .font(.rounded(Theme.FontSize.label, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
        }
    }

    /// Seed the calorie readout, then try to upgrade it to the Watch's own measurement. The finish
    /// path (`WorkoutRunner`) has already stamped the deterministic estimate on the workout — so a
    /// stored value only counts as the ATHLETE'S OWN when it differs from what the estimator would
    /// say (a recovery re-save of their edit). Their number always stands; the estimate yields to
    /// a Health measurement over the session window.
    private func prefillCalories(_ workout: Workout) {
        let estimate = CalorieEstimator.kcal(for: workout, bodyMassKg: profiles.first?.bodyMassKg)
        let existing = workout.calories
        kcal = (existing ?? 0) > 0 ? existing : estimate
        if let existing, existing > 0, existing != estimate {   // athlete-entered — keep it
            kcalEdited = true
            return
        }
        let start = workout.startedAt
        let duration = workout.durationS > 0 ? workout.durationS : workout.elapsedS
        let end = start.addingTimeInterval(max(1, duration))
        Task {
            if let measured = await services.health.measuredActiveEnergy(start: start, end: end),
               measured >= 1 {
                kcal = measured.rounded()
                kcalFromHealth = true
            }
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
        workout.calories = kcal
        // The e-bike's console readouts ride a sample-less GPSDetail — exactly how a manually
        // logged indoor ride stores them — so distance, avg speed and elevation flow into Trends,
        // records and Health like any ride. No samples, no snapshot → nothing ever renders a map.
        if showsRideDetails, rideDistanceM > 0 {
            let gps = workout.gps ?? GPSDetail()
            gps.distanceM = rideDistanceM
            gps.elevationGainM = rideElevationM
            if workout.durationS > 0 {
                gps.avgSpeedMS = CardioMetrics.averageSpeedMS(distanceM: rideDistanceM,
                                                              durationS: workout.durationS)
            }
            workout.gps = gps
        }
        // Community builds only — the solo app never touches privacy (see CardioSaveView). The
        // remembered-default write rides the same `context.save()` below.
        if CommunityAccess.enabled {
            workout.privacy = privacy
            if let p = profiles.first, p.defaultWorkoutVisibility != privacy.rawValue {
                p.defaultWorkoutVisibility = privacy.rawValue
            }
        }
        // Re-dirty for sync, for the same reason `FinishedWorkoutReader.commit` does
        // (StrengthSaveView): the finish flow dismisses the live screen — waking Today's throttled
        // sweep — BEFORE this editor appears, so the un-named workout has usually been uploaded and
        // stamped already. Without this, the title, note and effort typed here never leave the
        // device. Cardio and strength both route through `commit`; this screen writes directly, and
        // was the one path that never cleared it.
        workout.syncedAt = nil
        do { try context.save() } catch { saveFailed = true; return }
        let saved = workout
        if booksCompletion {
            // Mirror to Apple Health — but a Health-measured calorie number stays out of the mirror
            // (its samples are already there; writing them again would double the Move ring).
            let energyIsOurs = !kcalFromHealth
            Task { await services.health.save(saved, includeEnergy: energyIsOurs) }
            // Timed sessions move the streak, session-count, and time-of-day awards (deferred).
            AwardsBook.syncSoon()
            AppReview.recordWorkoutSaved()   // a KEPT workout — engagement toward the rating ask (not discards)
            // See CardioSaveView: fires on the KEPT workout, and is what advances the north-star funnel.
            services.analytics.log(.workoutCompleted(type: saved.type.rawValue))
        }
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
