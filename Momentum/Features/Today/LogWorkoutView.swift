import SwiftUI
import SwiftData

/// Manually log a workout you forgot to track — a run (incl. treadmill), a ride (incl. e-bike/trainer),
/// a walk/hike, or a strength session. Distance + duration for cardio; exercises with sets for lifting.
/// Everything is stored SI, exactly like a captured workout, so it flows into history, streaks, and
/// trends the same way. No GPS trace (it wasn't recorded) — just the numbers the athlete remembers.
struct LogWorkoutView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var library: [Exercise]
    @Query private var profiles: [UserProfile]

    @State private var type: WorkoutType
    @State private var showTypePicker = false

    /// Open pre-set to the activity the athlete is currently looking at (Today's sport), so a lifter
    /// lands on the strength form and a runner on the run form.
    init(initialType: WorkoutType = .run) {
        _type = State(initialValue: initialType)
    }

    @State private var date = Date()
    @State private var hours = 0
    @State private var minutes = 45
    @State private var distanceText = ""
    @State private var indoor = false
    @State private var exercises: [DraftExercise] = [DraftExercise()]
    @State private var effort: Int?
    @State private var notes = ""

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
            return exercises.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.sets.isEmpty }
        }
        if type.isGPS { return distanceMeters > 0 }
        return true   // timed sports need only a duration
    }

    var body: some View {
        NavigationStack {
            Form {
                typeSection
                whenSection
                if type.isGPS {
                    cardioSection
                } else if type.isStrengthStyle {
                    strengthSection
                }
                detailsSection
            }
            .navigationTitle("Add a workout")
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
        }
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
            Toggle(isOn: $indoor) {
                Text(isBike ? "Indoor / trainer" : "Treadmill / indoor")
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
            }
            .tint(Theme.purple)
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
        context.insert(w)
        try? context.save()
        PlanCoaching.creditWorkout(w, to: profiles.first?.plan, in: context)
        Haptics.success()
        dismiss()
    }

    /// Find an existing library/custom exercise by name, else create a custom one so the lift is real.
    private func exerciseRef(named name: String) -> Exercise {
        if let found = library.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return found }
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

        if type.isGPS {
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
            w.strength = s
        }
        return w
    }
}
