import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// FUEL — the fueling readout + meal log (pillar decision 2026-07-16). One page that answers
/// "am I fueled for the work?": the deterministic `FuelReadiness` readout up top (carbs vs the
/// session that's driving the target, energy/protein/sodium floors), a one-sentence-or-photo
/// composer, and today's meals. The AI (`FuelEstimator` → meal-estimate Edge Function) only
/// estimates a meal's numbers — every target and verdict is engine math.
///
/// Framing rules carried from the engine: floors, never ceilings; no diet/weight language;
/// every number reads ≈. A meal logs instantly offline and estimates when it can.
struct FuelView: View {
    /// false when tab-hosted (RootView) — the tab bar is the way out, so no Done button. true when
    /// presented as a sheet (previews/one-off entry points).
    var showsDone = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Meal.eatenAt, order: .reverse) private var meals: [Meal]
    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]
    @Query private var profiles: [UserProfile]

    @State private var draft = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var estimating: Set<UUID> = []
    @State private var editing: Meal?
    @FocusState private var composing: Bool
    private let estimator = FuelEstimator()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    readoutHeader
                    if readout.refuelDue { refuelBanner }
                    composer
                    todaysMeals
                    weekStrip
                    Text(FuelingGuide.Guidance.disclaimer)
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, Theme.Space.sm)
                }
                .padding(Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxl)
            }
            .background(Theme.background)
            .navigationTitle("Fuel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.fontWeight(.semibold)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .sheet(item: $editing) { MealEditSheet(meal: $0) }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        photoData = WorkoutPhotoSection.downscaled(data)
                    }
                    photoItem = nil
                }
            }
        }
    }

    // MARK: Readout (engine inputs mapped from the store — the engine itself stays pure)

    private var readout: FuelReadiness.DayReadout {
        let now = Date()
        let mealInputs = meals.prefix(80).map {
            FuelReadiness.MealInput(eatenAt: $0.eatenAt, kcal: $0.kcal, carbsG: $0.carbsG,
                                    proteinG: $0.proteinG, sodiumMg: $0.sodiumMg)
        }
        let cal = Calendar.current
        let sessions: [FuelReadiness.SessionInput] = (profiles.first?.plan?.sessions ?? [])
            .filter { $0.discipline == .running && $0.status != .completed }
            .filter { cal.isDate($0.date, inSameDayAs: now) || cal.isDate($0.date, inSameDayAs: now.addingTimeInterval(86_400)) }
            .compactMap { s in
                FuelingGuide.estimatedDurationS(distanceM: s.targetDistanceM, paceSPerKm: s.targetPaceSPerKm,
                                                durationS: s.targetDurationS)
                    .map { FuelReadiness.SessionInput(date: s.date, durationS: $0, isRace: s.runType == .race) }
            }
        let today: [FuelReadiness.WorkoutInput] = workouts.prefix(20)
            .filter { cal.isDate($0.startedAt, inSameDayAs: now) }
            .map { FuelReadiness.WorkoutInput(endedAt: $0.startedAt.addingTimeInterval($0.durationS),
                                              durationS: $0.durationS, kcal: $0.calories.map(Int.init)) }
        return FuelReadiness.readout(meals: Array(mealInputs), sessions: sessions,
                                     workoutsToday: today, bodyMassKg: profiles.first?.bodyMassKg, now: now)
    }

    // MARK: Header — the judgment, then the numbers

    private var readoutHeader: some View {
        let r = readout
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(r.headline)
                .font(.display(22, weight: .bold)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            // Carbs — the readiness bar. Earned iridescence exactly when the floor is met.
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text("≈\(r.carbsG) g").font(.display(28, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                    Text("of \(r.carbsFloorG)–\(r.carbsHighG) g carbs")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    Spacer(minLength: 0)
                    if r.pendingCount > 0 {
                        Text("\(r.pendingCount) estimating…")
                            .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface)
                        Capsule()
                            .fill(r.status == .fueled ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.ink))
                            .frame(width: geo.size.width * min(1, CGFloat(r.carbsG) / CGFloat(max(1, r.carbsFloorG))))
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
            }
            // The floors — quiet, ≈, never a ceiling.
            HStack(spacing: 0) {
                floorCell("≈\(r.kcal)", "of \(r.kcalFloor)+ kcal")
                floorCell("≈\(r.proteinG) g", "of \(r.proteinFloorG)+ protein")
                floorCell("≈\(r.sodiumMg)", "of \(r.sodiumFloorMg)+ mg sodium")
            }
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
    }

    private func floorCell(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label).font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var refuelBanner: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.purple)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.purple.opacity(0.1)))
            Text("Recovery window is open — carbs + protein within the hour do the most good.")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.purple.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.purple.opacity(0.25)))
    }

    // MARK: Composer — one sentence and/or a photo; logging never blocks

    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                TextField("What did you eat?", text: $draft, axis: .vertical)
                    .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(1...3)
                    .focused($composing)
                    .submitLabel(.send)
                    .onSubmit(log)
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: photoData == nil ? "camera" : "camera.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(photoData == nil ? Theme.inkSecondary : Theme.purple)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.surface))
                }
                .accessibilityLabel(photoData == nil ? "Add a plate photo" : "Photo attached")
                Button(action: log) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.background)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(canLog ? Theme.ink : Theme.inkTertiary))
                }
                .buttonStyle(.plain)
                .disabled(!canLog)
                .accessibilityLabel("Log meal")
            }
            if photoData != nil {
                Text("Photo attached — the estimate will read the plate.")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
    }

    private var canLog: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photoData != nil
    }

    private func log() {
        guard canLog else { return }
        let meal = Meal()
        meal.text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        meal.photoData = photoData
        context.insert(meal)
        try? context.save()
        Haptics.success()
        let label = readout.drivingSession
        draft = ""
        photoData = nil
        composing = false
        estimating.insert(meal.id)
        Task {
            if let e = await estimator.estimate(text: meal.text, photoJPEG: meal.photoData,
                                                sessionLabel: label, durationS: nil) {
                FuelEstimator.apply(e, to: meal)
                try? context.save()
            }
            estimating.remove(meal.id)
        }
    }

    // MARK: Today's meals

    private var todayMeals: [Meal] {
        meals.filter { Calendar.current.isDateInToday($0.eatenAt) }
    }

    @ViewBuilder
    private var todaysMeals: some View {
        let rows = todayMeals
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("TODAY").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Theme.inkTertiary)
                VStack(spacing: 0) {
                    ForEach(rows) { meal in
                        mealRow(meal)
                        if meal.id != rows.last?.id {
                            Rectangle().fill(Theme.hairline).frame(height: 0.5)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
            }
        }
    }

    private func mealRow(_ meal: Meal) -> some View {
        Button { editing = meal } label: {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                if let photo = meal.photoData, let ui = UIImage(data: photo) {
                    Image(uiImage: ui).resizable().scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Space.sm) {
                        Text(meal.text.isEmpty ? "Photo meal" : meal.text)
                            .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Text(meal.eatenAt.formatted(date: .omitted, time: .shortened))
                            .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    }
                    if estimating.contains(meal.id) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Estimating…").font(.rounded(Theme.FontSize.label, weight: .medium))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    } else if let carbs = meal.carbsG {
                        Text(numbersLine(meal, carbs: carbs))
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Theme.inkSecondary)
                    } else {
                        Text("Couldn't estimate — tap to set the numbers")
                            .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.purple)
                    }
                    if let note = meal.note, !note.isEmpty {
                        Text(note).font(.rounded(Theme.FontSize.label, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary).lineLimit(2)
                    }
                }
            }
            .padding(Theme.Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Meal: \(meal.text.isEmpty ? "photo" : meal.text)")
    }

    private func numbersLine(_ meal: Meal, carbs: Int) -> String {
        var parts = ["≈\(carbs) g carbs"]
        if let kcal = meal.kcal { parts.append("\(kcal) kcal") }
        if let p = meal.proteinG { parts.append("\(p) g protein") }
        if let s = meal.sodiumMg { parts.append("\(s) mg sodium") }
        return parts.joined(separator: " · ")
    }

    // MARK: The week, at a glance — filled dot = that day met the easy floor

    private var weekStrip: some View {
        let cal = Calendar.current
        let kg = profiles.first?.bodyMassKg ?? FuelReadiness.fallbackMassKg
        let easyFloor = Int(FuelReadiness.carbsPerKgEasy * kg)
        let days: [(String, Bool, Bool)] = (0..<7).reversed().map { back in
            let day = cal.date(byAdding: .day, value: -back, to: Date())!
            let dayMeals = meals.filter { cal.isDate($0.eatenAt, inSameDayAs: day) }
            let carbs = dayMeals.compactMap(\.carbsG).reduce(0, +)
            let letter = day.formatted(.dateTime.weekday(.narrow))
            return (letter, !dayMeals.isEmpty, carbs >= easyFloor)
        }
        return HStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 5) {
                    Circle()
                        .fill(day.2 ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(day.1 ? Theme.inkTertiary : Theme.surface))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Theme.hairline, lineWidth: day.1 ? 0 : 1))
                    Text(day.0).font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, Theme.Space.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last seven days of fueling")
    }
}

// MARK: - Manual numbers (the athlete always outranks the estimate)

/// Set or correct a meal's numbers by hand — `source` becomes "manual", which a later AI estimate
/// never overwrites. Also the meal's delete affordance.
private struct MealEditSheet: View {
    @Bindable var meal: Meal
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var carbs = ""
    @State private var kcal = ""
    @State private var protein = ""
    @State private var sodium = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if !meal.text.isEmpty {
                        Text(meal.text).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    }
                    VStack(spacing: 0) {
                        numberRow("Carbs", unit: "g", text: $carbs)
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                        numberRow("Energy", unit: "kcal", text: $kcal)
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                        numberRow("Protein", unit: "g", text: $protein)
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                        numberRow("Sodium", unit: "mg", text: $sodium)
                    }
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
                    Button(role: .destructive) {
                        context.delete(meal)
                        try? context.save()
                        Haptics.medium()
                        dismiss()
                    } label: {
                        Text("Delete meal").font(.rounded(Theme.FontSize.body, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.top, Theme.Space.md)
                }
                .padding(Theme.Space.lg)
            }
            .background(Theme.background)
            .navigationTitle("Edit meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.fontWeight(.bold) }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                carbs = meal.carbsG.map(String.init) ?? ""
                kcal = meal.kcal.map(String.init) ?? ""
                protein = meal.proteinG.map(String.init) ?? ""
                sodium = meal.sodiumMg.map(String.init) ?? ""
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func numberRow(_ label: String, unit: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            Spacer()
            TextField("—", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                .foregroundStyle(Theme.ink)
                .frame(width: 90)
            Text(unit).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .frame(width: 32, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 12)
    }

    private func save() {
        meal.carbsG = Int(carbs)
        meal.kcal = Int(kcal)
        meal.proteinG = Int(protein)
        meal.sodiumMg = Int(sodium)
        meal.source = "manual"
        try? context.save()
        Haptics.success()
        dismiss()
    }
}
