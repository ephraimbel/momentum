import SwiftUI
import SwiftData

/// Manually log a workout you forgot to track — a run (incl. treadmill), a ride (incl. e-bike/trainer),
/// a walk/hike, or a strength session. Distance + duration for cardio; exercises with sets for lifting.
/// Everything is stored SI, exactly like a captured workout, so it flows into history, streaks, and
/// trends the same way. No GPS trace (it wasn't recorded) — just the numbers the athlete remembers.
struct LogWorkoutView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(Services.self) private var services   // records → Health mirror → funnel, same as a tracked save
    @Query private var library: [Exercise]
    @Query private var profiles: [UserProfile]

    @State private var type: WorkoutType
    @State private var showTypePicker = false

    /// Draft-return mode (the log composer's per-card editor): Save hands the form's values BACK
    /// to the caller instead of writing a workout — the composer folds them into its card and
    /// nothing saves until the athlete confirms the whole receipt.
    private let onDraftReturn: ((LogWorkoutPrefill) -> Void)?

    /// Open pre-set to the activity the athlete is currently looking at (Today's sport), so a lifter
    /// lands on the strength form and a runner on the run form. With a `prefill` (the log composer's
    /// card editor), every field opens holding the parse — this form is the receipt's editor.
    init(initialType: WorkoutType = .run, prefill: LogWorkoutPrefill? = nil,
         onDraftReturn: ((LogWorkoutPrefill) -> Void)? = nil) {
        self.onDraftReturn = onDraftReturn
        _type = State(initialValue: prefill?.type ?? initialType)
        guard let p = prefill else { return }
        _date = State(initialValue: p.date)
        _hours = State(initialValue: Int(p.durationS) / 3600)
        _minutes = State(initialValue: (Int(p.durationS) % 3600) / 60)
        _indoor = State(initialValue: p.indoor)
        _effort = State(initialValue: p.effort)
        if p.distanceM > 0 {
            let unit = DistanceUnit.auto.resolved()
            let v = unit == .imperial ? p.distanceM / Formatters.metersPerMile : p.distanceM / 1000
            _distanceText = State(initialValue: String(format: v.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", v))
        }
        if !p.exercises.isEmpty {
            let unit = WeightUnit.default()
            _exercises = State(initialValue: p.exercises.map { line in
                var draft = DraftExercise()
                draft.name = line.name
                draft.sets = (0..<max(1, line.sets)).map { _ in
                    var set = DraftSet()
                    set.reps = line.reps
                    if let kg = line.weightKg {
                        // Snap to the nearest half — real plates come in halves, and unit
                        // round-trips otherwise leave "185.0" / "225.1" in the field.
                        let w = ((unit == .lb ? kg / Formatters.kgPerLb : kg) * 2).rounded() / 2
                        set.weightText = String(format: w.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", w)
                    }
                    return set
                }
                return draft
            })
        }
    }

    @State private var date = Date()
    @State private var saving = false   // one save per tap (see save())
    @State private var hours = 0
    @State private var minutes = 45
    @State private var distanceText = ""
    @State private var indoor = false
    @State private var exercises: [DraftExercise] = [DraftExercise()]
    @State private var effort: Int?
    @State private var notes = ""
    @State private var saveFailed = false
    /// The just-logged workout, now open on the SAME structured post-activity page a tracked one
    /// gets (user ask 2026-08-14): name it, describe it, attach photos, adjust effort — one page,
    /// every path. The booking below already ran, so the page presents with
    /// `booksCompletion: false` and only names, decorates, and celebrates.
    @State private var reviewing: PresentedWorkout?

    private var distanceUnit: DistanceUnit { DistanceUnit.auto.resolved() }
    private var weightUnit: WeightUnit { .default() }
    private var durationS: Double { Double(hours * 3600 + minutes * 60) }
    private var isBike: Bool { [.ride, .mountainBikeRide, .gravelRide, .eBikeRide].contains(type) }

    private var distanceMeters: Double {
        let v = Double(distanceText.replacingOccurrences(of: ",", with: ".")) ?? 0
        return distanceUnit == .imperial ? v * Formatters.metersPerMile : v * 1000
    }

    private var canSave: Bool {
        guard durationS > 0 else { return false }
        if type.isStrengthStyle {
            // Direct saves need at least one named exercise; the composer's card editor doesn't —
            // a duration-only lift is a real lift there (the receipt's own rule).
            return onDraftReturn != nil
                || exercises.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.sets.isEmpty }
        }
        // Same relaxation for cardio: the composer logs "walked 30 min" without a distance, so
        // its card editor can't demand one. Direct adds keep the stricter typed-flow rule.
        // Outdoor GPS sports demand a distance on direct adds; the stationary e-bike offers the
        // field but never requires it — "30 min e-bike" with no console readout is a real session.
        if type.isGPS { return onDraftReturn != nil || distanceMeters > 0 }
        return true   // timed sports need only a duration
    }

    var body: some View {
        NavigationStack {
            Form {
                typeSection
                whenSection
                if type.tracksDistance {
                    cardioSection
                } else if type.isStrengthStyle {
                    strengthSection
                }
                // Effort + notes belong to the structured save page that now follows a direct
                // add (2026-08-14) — collecting them here too was double entry in one flow. The
                // composer's card editor keeps them: its receipt has no page after.
                if onDraftReturn != nil { detailsSection }
            }
            .navigationTitle(onDraftReturn == nil ? "Add a workout" : "Adjust workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save).fontWeight(.bold).disabled(!canSave)
                }
            }
            .sheet(isPresented: $showTypePicker) {
                SportPicker(selection: $type) { showTypePicker = false }
            }
            .alert("Couldn't save your workout", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Something went wrong writing to storage. Everything you entered is still here — try Save again.")
            }
            // The logged workout's structured page (the same one a tracked workout finishes on),
            // presented over this form; its Done/celebration closes both.
            .fullScreenCover(item: $reviewing) { presented in
                reviewScreen(presented)
            }
        }
    }

    /// Route the just-logged workout to its discipline's save page — the same routing
    /// `WorkoutRunner.saveScreen` uses for a tracked workout, minus the completion booking
    /// (already done in `save()`).
    @ViewBuilder
    private func reviewScreen(_ presented: PresentedWorkout) -> some View {
        Group {
            if presented.type.isStrengthStyle {
                StrengthSaveView(workoutId: presented.id, booksCompletion: false) { closeReview() }
            } else if presented.type.isTimed {
                TimedSaveView(workoutId: presented.id, booksCompletion: false) { closeReview() }
            } else {
                // The athlete's explicit unit choice, like WorkoutRunner passes it — bare `.auto`
                // would silently ignore a metric/imperial preference on this one path.
                CardioSaveView(workoutId: presented.id,
                               distanceUnit: DistanceUnit(rawValue: profiles.first?.distanceUnit ?? "auto") ?? .auto,
                               workoutType: presented.type, booksCompletion: false) { closeReview() }
            }
        }
        // This review editor is itself presented inside a cover, so the root host cannot reach it.
        // See `NestedPaywallHost.swift`.
        .nestedPaywallHost()
    }

    private func closeReview() {
        reviewing = nil
        dismiss()
    }

    // MARK: Sections

    private var typeSection: some View {
        Section {
            Button { showTypePicker = true } label: {
                HStack {
                    Image(systemName: type.systemImage).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                        .frame(width: 30)
                    Text(type.title).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text("Change").font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.purple)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                }
            }
        }
    }

    private var whenSection: some View {
        Section("When") {
            DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                .font(.rounded(Theme.FontSize.body, weight: .medium))
            // One tap for the everyday lengths — the steppers below still handle anything odd.
            // Reaching 45 minutes used to be nine taps on a stepper, and this form is exactly where
            // an athlete lands when the composer couldn't work out how long they trained.
            QuickDurationRow(selected: durationS > 0 ? durationS : nil) { picked in
                hours = Int(picked) / 3600
                minutes = (Int(picked) % 3600) / 60
            }
            .padding(.vertical, 2)
            .listRowSeparator(.hidden)
            Stepper(value: $hours, in: 0...12) {
                HStack {
                    Text("Hours").font(.rounded(Theme.FontSize.body, weight: .medium))
                    Spacer()
                    Text("\(hours)").monospacedDigit().foregroundStyle(Theme.inkSecondary)
                }
            }
            Stepper(value: $minutes, in: 0...59, step: 5) {
                HStack {
                    Text("Minutes").font(.rounded(Theme.FontSize.body, weight: .medium))
                    Spacer()
                    Text("\(minutes)").monospacedDigit().foregroundStyle(Theme.inkSecondary)
                }
            }
        }
    }

    private var cardioSection: some View {
        Section {
            HStack {
                Text("Distance").font(.rounded(Theme.FontSize.body, weight: .medium))
                Spacer()
                TextField("0.0", text: $distanceText)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                    .frame(width: 90)
                Text(distanceUnit == .imperial ? "mi" : "km").foregroundStyle(Theme.inkTertiary)
            }
            // The e-bike IS the indoor trainer (stationary by definition, 2026-08-05) — no toggle.
            if type.isGPS {
                Toggle(isOn: $indoor) {
                    Text(isBike ? "Indoor / trainer" : "Treadmill / indoor")
                        .font(.rounded(Theme.FontSize.body, weight: .medium))
                }
                .tint(Theme.purple)
            }
            if let pace = paceOrSpeedPreview {
                HStack {
                    Text("Avg \(isBike ? "speed" : "pace")").foregroundStyle(Theme.inkTertiary)
                    Spacer()
                    Text(pace).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                }
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
            }
        } footer: {
            Text("No GPS route is recorded for a workout you add by hand — just your distance and time.")
        }
    }

    private var paceOrSpeedPreview: String? {
        guard durationS > 0, distanceMeters > 0 else { return nil }
        if isBike {
            let kmh = (distanceMeters / durationS) * 3.6
            let val = distanceUnit == .imperial ? kmh / 1.609344 : kmh
            return String(format: "%.1f %@", val, distanceUnit == .imperial ? "mph" : "km/h")
        }
        return Formatters.pace(secPerKm: durationS / (distanceMeters / 1000), unit: distanceUnit)
    }

    private var strengthSection: some View {
        Group {
            ForEach($exercises) { $ex in
                Section {
                    TextField("Exercise — e.g. Bench Press", text: $ex.name)
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .autocorrectionDisabled()
                    ForEach($ex.sets) { $set in
                        HStack(spacing: Theme.Space.sm) {
                            Text("\(setNumber($set.wrappedValue, in: ex))")
                                .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                                .frame(width: 16)
                            Stepper(value: $set.reps, in: 1...50) {
                                Text("\(set.reps) reps").font(.rounded(Theme.FontSize.body, weight: .medium))
                                    .monospacedDigit().lineLimit(1).fixedSize()
                            }
                            Spacer(minLength: Theme.Space.sm)
                            TextField("0", text: $set.weightText)
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                                .frame(width: 50)
                            Text(weightUnit.rawValue).foregroundStyle(Theme.inkTertiary).font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        }
                    }
                    .onDelete { ex.sets.remove(atOffsets: $0) }
                    Button {
                        ex.sets.append(DraftSet(reps: ex.sets.last?.reps ?? 8, weightText: ex.sets.last?.weightText ?? ""))
                    } label: {
                        Label("Add set", systemImage: "plus.circle.fill").font(.rounded(Theme.FontSize.caption, weight: .semibold))
                            .foregroundStyle(Theme.purple)
                    }
                } header: {
                    Text("Exercise \(exerciseIndex(ex) + 1)")
                }
            }
            Section {
                Button { exercises.append(DraftExercise()) } label: {
                    Label("Add exercise", systemImage: "plus").font(.rounded(Theme.FontSize.body, weight: .bold))
                        .foregroundStyle(Theme.purple)
                }
            }
        }
    }

    private var detailsSection: some View {
        Section("Details — optional") {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    Text("Effort").font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
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
            .padding(.vertical, 4)
            TextField("Notes — how did it feel?", text: $notes, axis: .vertical)
                .font(.rounded(Theme.FontSize.body, weight: .medium)).lineLimit(1...4)
        }
    }

    private var effortLabel: String {
        guard let e = effort else { return "Tap to rate" }
        switch e {
        case 1...2: return "Easy"
        case 3...4: return "Steady"
        case 5...6: return "Moderate"
        case 7...8: return "Hard"
        default:    return "Max"
        }
    }

    private func exerciseIndex(_ ex: DraftExercise) -> Int { exercises.firstIndex { $0.id == ex.id } ?? 0 }
    private func setNumber(_ set: DraftSet, in ex: DraftExercise) -> Int { (ex.sets.firstIndex { $0.id == set.id } ?? 0) + 1 }

    // MARK: Save

    private func save() {
        // One save per tap: the toolbar Save stays hittable through the dismissal animation,
        // and a double-tap used to run this whole pipeline twice — duplicate workout, double
        // plan credit, double records entry (audit 2026-08-11). Re-armed only on a rolled-back
        // save so a genuine retry still works.
        guard !saving else { return }
        saving = true
        // Card-editor mode: the values go back to the composer's receipt, not to storage.
        if let onDraftReturn {
            onDraftReturn(currentDraft())
            Haptics.success()
            dismiss()
            return
        }
        let inputs = exercises.map { draft in
            LogWorkoutBuilder.ExerciseInput(
                name: draft.name,
                sets: draft.sets.map { LogWorkoutBuilder.SetInput(reps: $0.reps, weightKg: $0.weightKg(unit: weightUnit)) })
        }
        // Resolve each name once per save: the `library` @Query snapshot doesn't refresh mid-save,
        // so two sections naming the same NEW exercise would otherwise create twin custom rows.
        var resolved: [String: Exercise] = [:]
        let cachedRef: (String) -> Exercise = { name in
            let key = name.lowercased()
            if let hit = resolved[key] { return hit }
            let e = exerciseRef(named: name)
            resolved[key] = e
            return e
        }
        let w = LogWorkoutBuilder.make(type: type, date: date, durationS: durationS, distanceM: distanceMeters,
                                       indoor: indoor, effort: effort, note: notes,
                                       exercises: inputs, resolveExercise: cachedRef)
        // A logged workout is a real workout: same calorie estimate and plan credit as a tracked one
        // (otherwise a treadmill run leaves today's planned session open and shows a blank calorie
        // stat forever). Deliberately no pace recalibration — hand-entered numbers are too coarse
        // to move the plan's fitness model.
        w.calories = CalorieEstimator.kcal(for: w, bodyMassKg: profiles.first?.bodyMassKg)
        // A logged workout is a post like any tracked one: it takes the athlete's default
        // visibility (their own last explicit choice). Community builds only — solo stays private.
        if CommunityAccess.enabled, let p = profiles.first {
            w.privacy = SocialPrivacy.defaultVisibility(p)
        }
        context.insert(w)
        // Never report success on a write that didn't land (the finish-flow save screens'
        // rule) — the hand-typed workout would vanish while the screen buzzed "saved".
        do { try context.save() } catch {
            context.delete(w)   // roll back the orphaned insert so a retry can't double-log
            saveFailed = true
            saving = false      // the write never landed — let them tap Save again
            return
        }
        PlanCoaching.creditWorkout(w, to: profiles.first?.plan, in: context)
        // …and it earns records, reaches Apple Health, and counts in the funnel like a tracked one.
        // None of that used to happen here, so a hand-logged personal best simply never existed.
        RecordsBook.record(w, in: context)
        services.analytics.log(.workoutCompleted(type: w.type.rawValue))
        if w.durationS >= 60 || (w.gps?.distanceM ?? 0) > 0 {
            let saved = w
            Task { await services.health.save(saved) }
        }
        AppReview.recordWorkoutSaved()
        // A logged workout moves streak/session/distance awards like a tracked one (deferred).
        AwardsBook.syncSoon()
        Haptics.success()
        // On to the structured post-activity page (see `reviewing`) — not a bare dismiss. The
        // form captured the numbers; the page is where the workout becomes theirs: title,
        // description, photos, effort, and the same summary a tracked session earns.
        reviewing = PresentedWorkout(id: w.id, type: w.type)
    }

    /// The form's current values as a prefill — what draft-return hands back to the composer.
    /// Consecutive identical sets collapse into one uniform line ("4×8 · 185"); a hand-varied
    /// set breaks into its own line, so nothing the athlete typed is flattened away.
    private func currentDraft() -> LogWorkoutPrefill {
        var lines: [LogWorkoutPrefill.ExerciseLine] = []
        if type.isStrengthStyle {
            for ex in exercises {
                let name = ex.name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                var runs: [(reps: Int, weightKg: Double?, count: Int)] = []
                for set in ex.sets {
                    let kg = set.weightKg(unit: weightUnit)
                    if let last = runs.last, last.reps == set.reps, last.weightKg == kg {
                        runs[runs.count - 1].count += 1
                    } else {
                        runs.append((set.reps, kg, 1))
                    }
                }
                for r in runs {
                    lines.append(.init(name: name, sets: r.count, reps: r.reps, weightKg: r.weightKg))
                }
            }
        }
        return LogWorkoutPrefill(type: type, date: date, durationS: durationS,
                                 distanceM: type.tracksDistance ? distanceMeters : 0,
                                 indoor: indoor, effort: effort, exercises: lines)
    }

    /// Find an existing library/custom exercise by name, else create a custom one so the lift is real.
    /// Shorthand-aware ("bench press" → Barbell Bench Press) so voice logs never mint doubles.
    private func exerciseRef(named name: String) -> Exercise {
        if let found = ExerciseNameMatch.find(name, in: library) { return found }
        let e = Exercise()
        e.name = name
        e.isCustom = true
        context.insert(e)
        return e
    }
}

/// A drafted exercise while filling the form — becomes a `WorkoutExercise` on save.
private struct DraftExercise: Identifiable {
    let id = UUID()
    var name: String = ""
    var sets: [DraftSet] = [DraftSet()]
}

private struct DraftSet: Identifiable {
    let id = UUID()
    var reps: Int = 8
    var weightText: String = ""

    func weightKg(unit: WeightUnit) -> Double? {
        guard let v = Double(weightText.replacingOccurrences(of: ",", with: ".")), v > 0 else { return nil }
        return unit == .lb ? v * Formatters.kgPerLb : v
    }
}

/// Builds a `Workout` from manual-entry values, stored SI exactly like a captured session so it flows
/// into history, streaks, and trends the same way. Pulled out of the view so it's unit-testable.
enum LogWorkoutBuilder {
    struct SetInput { var reps: Int; var weightKg: Double? }
    struct ExerciseInput { var name: String; var sets: [SetInput] }

    static func make(type: WorkoutType, date: Date, durationS: Double, distanceM: Double,
                     indoor: Bool, effort: Int?, note: String,
                     exercises: [ExerciseInput], resolveExercise: (String) -> Exercise) -> Workout {
        let isBike: Bool = [.ride, .mountainBikeRide, .gravelRide, .eBikeRide].contains(type)
        let w = Workout()
        w.type = type
        w.startedAt = date
        w.durationS = durationS
        w.elapsedS = durationS
        w.perceivedEffort = effort
        var noteParts: [String] = []
        if indoor, type.isGPS { noteParts.append(isBike ? "Indoor ride" : "Treadmill") }
        let userNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userNote.isEmpty { noteParts.append(userNote) }
        w.note = noteParts.joined(separator: " · ")

        // GPS sports always carry the payload; the stationary e-bike carries one only when a
        // console distance was actually entered — a duration-only e-bike stays a plain timed
        // session like a swim.
        if type.isGPS || (type.tracksDistance && distanceM > 0) {
            let gps = GPSDetail()
            gps.distanceM = distanceM
            if durationS > 0, distanceM > 0 {
                if isBike { gps.avgSpeedMS = CardioMetrics.averageSpeedMS(distanceM: distanceM, durationS: durationS) }
                else { gps.avgPaceSPerKm = CardioMetrics.averagePaceSPerKm(distanceM: distanceM, durationS: durationS) }
            }
            w.gps = gps
        } else if type.isStrengthStyle {
            let s = StrengthSession()
            var totalVol = 0.0, totalSets = 0, order = 0
            for ex in exercises {
                let name = ex.name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !ex.sets.isEmpty else { continue }
                let we = WorkoutExercise()
                we.order = order; order += 1
                we.exercise = resolveExercise(name)
                for (j, si) in ex.sets.enumerated() {
                    let set = SetEntry()
                    set.index = j
                    set.reps = si.reps
                    set.weightKg = si.weightKg
                    set.type = .working
                    set.isComplete = true
                    we.sets.append(set)
                    totalSets += 1
                    totalVol += (si.weightKg ?? 0) * Double(si.reps)
                }
                s.exercises.append(we)
            }
            s.totalSets = totalSets
            s.totalVolumeKg = totalVol
            // A duration-only lift ("lifted for an hour", no sets given) matches the HealthKit
            // import shape — type .strength, no StrengthSession — which every surface already
            // handles. An empty session object would be a third shape for nothing.
            if !s.exercises.isEmpty { w.strength = s }
        }
        return w
    }
}
