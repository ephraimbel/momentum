import SwiftUI
import SwiftData

/// The fueling adjuster (top-left on Fuel — the plan adjuster's sibling): choose how the daily
/// energy target is set. **Fuel for training** keeps the classic floors; **Leaner** runs a gentle
/// deficit that never raids the work (RED-S guard: never below basal headroom, always funds the
/// day's real burn, pauses on race/long days); **Build** adds a small surplus; **Custom** is the
/// athlete's own numbers. Everything is deterministic engine math (Mifflin-St Jeor × a daily-life
/// base + the day's REAL training burn — no survey "activity levels"), and the preview rolls live
/// as choices change. Carbs stay KEYED to training — and since 2026-07-22 the goal tunes the g/kg
/// within the easy/moderate tiers (Leaner trims, Build adds); long runs and race eve never move.
struct FuelGoalsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]
    /// Today's training burn, for the preview — "TODAY THAT MEANS" must equal the dashboard's
    /// headline exactly. It used to preview the BASE target (workouts excluded), so switching
    /// goals showed a number the Fuel page then contradicted by the day's burn — reads as a bug
    /// no footnote can save. Newest-first + capped to mirror the page's builder input.
    @Query(FuelGoalsSheet.recentWorkouts) private var todaysWorkouts: [Workout]
    private static var recentWorkouts: FetchDescriptor<Workout> {
        var d = FetchDescriptor<Workout>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        d.fetchLimit = 20
        return d
    }

    @State private var kind: FuelReadiness.GoalInput.Kind = .fuel
    @State private var massKg: Double = FuelReadiness.fallbackMassKg
    @State private var heightCm: Double = FuelReadiness.fallbackHeightCm
    @State private var age: Int = FuelReadiness.fallbackAge
    @State private var sex: String?
    @State private var customKcal = ""
    @State private var customProtein = ""
    @State private var customCarbs = ""
    @State private var customFat = ""
    @State private var customSodium = ""
    @State private var saveFailed = false
    @State private var loaded = false

    private var usesPounds: Bool { profiles.first?.weightUnit == "lb" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    goalPicker.reveal(0)
                    aboutYou.reveal(0.06)
                    if kind == .custom {
                        customCard
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    preview.reveal(0.12)
                    Text("Leaner never dips below your resting burn's headroom, always funds the day's training, and pauses on race and long-session days. \(FuelingGuide.Guidance.disclaimer)")
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .reveal(0.18)
                }
                .padding(Theme.Space.lg)
                .animation(Motion.standard, value: kind)
            }
            .background(Theme.background)
            .navigationTitle("Fueling goals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.fontWeight(.bold) }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear(perform: load)
            .alert("Couldn't save your goals", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Something went wrong writing to storage. Your choices are still here — try Save again.")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: The four ways to aim

    private var goalPicker: some View {
        VStack(spacing: 0) {
            goalRow(.fuel, fuelForTitle, fuelForLine)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            goalRow(.leaner, "Leaner", "A gentle deficit that never raids training. Your Fuel bar leads with protein to protect muscle; carbs ease on lighter days.")
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            goalRow(.build, "Build", "A small surplus for strength and rebuild blocks — your Fuel bar leads with protein.")
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            goalRow(.custom, "Custom", "Your numbers, your call, protein-led. Training burn still adds on top.")
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
    }

    /// The default option wears the plan the athlete actually made: "Fuel for the Austin
    /// Marathon" (named plan) → "Fuel for your half marathon" (dated race) → "Fuel for training".
    private var fuelForTitle: String {
        if let name = profiles.first?.plan?.name, !name.isEmpty {
            let article = name.lowercased().hasPrefix("the ") ? "" : "the "
            return "Fuel for \(article)\(name)"
        }
        if let m = profiles.first?.raceDistanceM, m > 0 {
            let label = RaceDistance.nearest(toMeters: m).label
            // "Half marathon" reads as "your half marathon"; digit labels (5K, 10K) keep their case.
            let spoken = label.contains(where: \.isNumber) ? label : label.lowercased()
            return "Fuel for your \(spoken)"
        }
        return "Fuel for training"
    }

    private var fuelForLine: String {
        if let race = profiles.first?.raceDate {
            let weeks = max(0, Calendar.current.dateComponents([.weekOfYear], from: Date(), to: race).weekOfYear ?? 0)
            if weeks > 0 {
                return "Floors that fund the work — \(weeks) week\(weeks == 1 ? "" : "s") out. The default."
            }
        }
        return "Floors that fund the work — the default."
    }

    private func goalRow(_ k: FuelReadiness.GoalInput.Kind, _ title: String, _ line: String) -> some View {
        let on = kind == k
        return Button {
            withAnimation(Motion.standard) { select(k) }
            Haptics.light()
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(on ? Theme.ink : Theme.inkTertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(line).font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityIdentifier("goal-\(k.rawValue)")
    }

    // MARK: About you (drives the math; saves back to the one profile)

    private var aboutYou: some View {
        VStack(spacing: 0) {
            stepperRow("Weight", value: weightLabel,
                       minus: { massKg = max(30, massKg - (usesPounds ? 0.4536 : 0.5)) },
                       plus: { massKg = min(200, massKg + (usesPounds ? 0.4536 : 0.5)) })
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            stepperRow("Height", value: heightLabel,
                       minus: { heightCm = max(120, heightCm - (usesPounds ? 2.54 : 1)) },
                       plus: { heightCm = min(230, heightCm + (usesPounds ? 2.54 : 1)) })
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            stepperRow("Age", value: "\(age)",
                       minus: { age = max(14, age - 1) },
                       plus: { age = min(90, age + 1) })
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            HStack {
                Text("Sex").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                Spacer()
                ForEach(["female", "male"], id: \.self) { s in
                    let on = sex == s
                    Button {
                        withAnimation(Motion.standard) { sex = on ? nil : s }
                        Haptics.light()
                    } label: {
                        Text(s.capitalized)
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                            .foregroundStyle(on ? Theme.background : Theme.inkSecondary)
                            .padding(.horizontal, Theme.Space.sm + 2).padding(.vertical, 6)
                            .background(Capsule().fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.background.opacity(0.7))))
                            .overlay(Capsule().stroke(Theme.hairline, lineWidth: on ? 0 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 10)
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
    }

    private var weightLabel: String {
        usesPounds ? "\(Int((massKg * 2.20462).rounded())) lb" : String(format: "%.1f kg", massKg)
    }

    private var heightLabel: String {
        if usesPounds {
            let inches = Int((heightCm / 2.54).rounded())
            return "\(inches / 12)′\(inches % 12)″"
        }
        return "\(Int(heightCm.rounded())) cm"
    }

    private func stepperRow(_ label: String, value: String,
                            minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            Spacer()
            HStack(spacing: 2) {
                stepButton("minus", label: "Less \(label)") { minus(); Haptics.light() }
                Text(value)
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                    .animation(Motion.standard, value: value)
                    .frame(minWidth: 64)
                stepButton("plus", label: "More \(label)") { plus(); Haptics.light() }
            }
            .padding(3)
            .background(Capsule().fill(Theme.background.opacity(0.7)))
            .overlay(Capsule().stroke(Theme.hairline))
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 7)
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Custom numbers

    private var customCard: some View {
        VStack(spacing: 0) {
            numberRow("Energy", unit: "kcal", text: $customKcal)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            numberRow("Protein", unit: "g", text: $customProtein)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            numberRow("Carbs", unit: "g", text: $customCarbs)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            numberRow("Fat", unit: "g", text: $customFat)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            numberRow("Sodium", unit: "mg", text: $customSodium)
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
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

    // MARK: Live preview — the same engine the page runs

    /// The SAME inputs the Fuel page's headline runs (plan + today's workouts) — the preview and
    /// the dashboard must never disagree about today's number. Meals stay out: they drive
    /// consumed totals, not targets.
    private var previewReadout: FuelReadiness.DayReadout {
        FuelReadoutBuilder.readout(meals: [], plan: profiles.first?.plan,
                                   workouts: Array(todaysWorkouts),
                                   profile: profiles.first,
                                   goalOverride: stagedGoal, massOverride: massKg)
    }

    /// BASE targets (no training burn) — what a custom goal should prefill from: custom numbers
    /// are an every-day base, and burn adds on top later. Prefilling from the burn-inclusive
    /// preview would bake today's workout into every future day.
    private var basePrefillReadout: FuelReadiness.DayReadout {
        FuelReadoutBuilder.readout(meals: [], plan: profiles.first?.plan, workouts: [],
                                   profile: profiles.first,
                                   goalOverride: stagedGoal, massOverride: massKg)
    }

    private var stagedGoal: FuelReadiness.GoalInput {
        .init(kind: kind, heightCm: heightCm,
              birthYear: Calendar.current.component(.year, from: Date()) - age,
              isMale: sex == "male" ? true : (sex == "female" ? false : nil),
              customKcal: Int(customKcal), customProteinG: Int(customProtein),
              customCarbsG: Int(customCarbs), customFatG: Int(customFat),
              customSodiumMg: Int(customSodium))
    }

    private var preview: some View {
        let r = previewReadout
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("TODAY THAT MEANS")
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(r.kcalFloor.formatted())
                    .font(.display(26, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text(r.kcalIsGoal ? "kcal goal" : "kcal floor")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
            Text("protein \(r.proteinFloorG) g · carbs ≈\(r.carbsFloorG) g · fat \(r.fatFloorG) g · sodium \(r.sodiumFloorMg.formatted()) mg")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
                .contentTransition(.numericText())
            Text(kind == .custom && Int(customCarbs) != nil
                 ? "Includes today's training — your custom base rises on days you train."
                 : "Carbs stay keyed to your training — big sessions raise them, your goal tunes the lighter days. Today's training is already counted above.")
                .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = r.goalNote {
                Text(note)
                    .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                    .transition(.opacity)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        .animation(Motion.standard, value: r)
    }

    // MARK: Load / select / save

    private func load() {
        guard !loaded, let p = profiles.first else { return }
        loaded = true
        kind = p.fuelGoalKind.flatMap { FuelReadiness.GoalInput.Kind(rawValue: $0) } ?? .fuel
        massKg = p.bodyMassKg ?? FuelReadiness.fallbackMassKg
        heightCm = p.heightCm ?? FuelReadiness.fallbackHeightCm
        age = p.birthYear.map { max(14, Calendar.current.component(.year, from: Date()) - $0) }
            ?? FuelReadiness.fallbackAge
        sex = p.sex
        customKcal = p.fuelCustomKcal.map(String.init) ?? ""
        customProtein = p.fuelCustomProteinG.map(String.init) ?? ""
        customCarbs = p.fuelCustomCarbsG.map(String.init) ?? ""
        customFat = p.fuelCustomFatG.map(String.init) ?? ""
        customSodium = p.fuelCustomSodiumMg.map(String.init) ?? ""
    }

    /// Entering custom prefills the fields from the current computed targets — edit from a real
    /// starting point, never a blank form.
    private func select(_ k: FuelReadiness.GoalInput.Kind) {
        kind = k
        guard k == .custom, customKcal.isEmpty else { return }
        let r = basePrefillReadout
        customKcal = String(r.kcalFloor)
        customProtein = String(r.proteinFloorG)
        customCarbs = String(r.carbsFloorG)
        customFat = String(r.fatFloorG)
        customSodium = String(r.sodiumFloorMg)
    }

    private func save() {
        guard let p = profiles.first else { dismiss(); return }
        p.fuelGoalKind = kind.rawValue
        p.bodyMassKg = massKg
        p.heightCm = heightCm
        p.birthYear = Calendar.current.component(.year, from: Date()) - age
        p.sex = sex
        p.fuelCustomKcal = kind == .custom ? Int(customKcal) : p.fuelCustomKcal
        p.fuelCustomProteinG = kind == .custom ? Int(customProtein) : p.fuelCustomProteinG
        p.fuelCustomCarbsG = kind == .custom ? Int(customCarbs) : p.fuelCustomCarbsG
        p.fuelCustomFatG = kind == .custom ? Int(customFat) : p.fuelCustomFatG
        p.fuelCustomSodiumMg = kind == .custom ? Int(customSodium) : p.fuelCustomSodiumMg
        // Fuel targets drive every ring on the dashboard — a silently-failed save with a success
        // buzz means the athlete eats to goals that revert on next launch.
        do { try context.save() } catch {
            context.rollback()
            saveFailed = true
            return
        }
        Haptics.success()
        dismiss()
    }
}
