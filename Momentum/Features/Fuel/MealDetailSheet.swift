import SwiftUI
import SwiftData

/// Editing is a value draft: Cancel never changes the journal and a failed save stays open.
struct MealDetailSheet: View {
    @Bindable var meal: Meal
    var isNew = false
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var eatenAt = Date()
    @State private var items: [MealItem] = []
    @State private var entry = NutritionEntry()
    @State private var originalEntry = NutritionEntry()
    @State private var totalsMode = false
    @State private var numbersDirty = false
    @State private var loaded = false
    @State private var addItemText = ""
    @State private var addItemMiss = false
    @State private var showingDetails = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false
    @State private var detent: PresentationDetent = .medium
    private enum Input: Hashable { case name, nutrient(Nutrient), addItem }
    @FocusState private var focused: Input?

    private var nutrition: NutritionValues {
        totalsMode ? entry.parsed().values : .sum(items.map(\.exactNutrition))
    }
    private var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this meal a name." }
        if totalsMode {
            if let error = entry.parsed().error { return error }
            if isNew && nutrition.values.isEmpty { return "Enter at least one nutrition amount. Leave unknown values blank." }
        } else if items.isEmpty { return "Add a food, enter totals, or delete this meal." }
        return nil
    }
    private var editedNumbers: Bool { numbersDirty || entry != originalEntry }
    private var verdict: HealthScore.Verdict? {
        guard !totalsMode else {
            guard let k = nutrition.integer(.kcal), k > 0,
                  nutrition[.carbs] != nil, nutrition[.protein] != nil, nutrition[.fat] != nil else { return nil }
            return HealthScore.aggregate([.init(name: name, kcal: k, carbsG: nutrition.integer(.carbs) ?? 0,
                proteinG: nutrition.integer(.protein) ?? 0, fatG: nutrition.integer(.fat) ?? 0,
                sodiumMg: nutrition.integer(.sodium) ?? 0, fiberG: nutrition.integer(.fiber),
                sugarG: nutrition.integer(.sugar), satFatG: nutrition.integer(.saturatedFat),
                potassiumMg: nutrition.integer(.potassium), nova: nil)])
        }
        return HealthScore.aggregate(items.map(\.healthFacts))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    TextField("Meal name", text: $name, axis: .vertical)
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .accessibilityIdentifier("meal-name")
                        .focused($focused, equals: .name)
                    if let note = meal.note, !editedNumbers, !note.isEmpty {
                        Text(note).font(.rounded(Theme.FontSize.caption)).foregroundStyle(Theme.inkSecondary)
                    }
                    if !totalsMode, let verdict { scoreHero(verdict) }
                    if totalsMode {
                        Text("Enter the amounts for everything you ate. Blank means unknown; 0 means none.")
                            .font(.rounded(Theme.FontSize.caption)).foregroundStyle(Theme.inkSecondary)
                        fieldCard([.carbs, .kcal, .protein, .fat, .sodium, .fluids])
                        Button {
                            focused = nil
                            showingDetails.toggle()
                        } label: {
                            HStack {
                                Text("Fiber, sugars & minerals")
                                Spacer()
                                Image(systemName: showingDetails ? "chevron.up" : "chevron.down")
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .accessibilityIdentifier("meal-more-nutrients")
                        .accessibilityValue(showingDetails ? "Expanded" : "Collapsed")
                        if showingDetails {
                            fieldCard([.fiber, .sugar, .saturatedFat, .potassium, .magnesium, .iron, .calcium])
                        }
                        if let verdict { scoreHero(verdict) }
                    } else {
                        itemsCard
                        Button("Set totals by hand", action: switchToTotals)
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        NutritionFactsView(rows: items.map(\.exactNutrition))
                    }
                    DatePicker("Eaten", selection: $eatenAt, in: ...max(Date(), meal.eatenAt),
                               displayedComponents: [.date, .hourAndMinute])
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .accessibilityIdentifier("meal-eaten-at")
                    if let validationMessage {
                        Text(validationMessage).font(.rounded(Theme.FontSize.caption))
                            .foregroundStyle(Theme.inkSecondary)
                            .accessibilityIdentifier("meal-validation")
                    }
                    if !isNew {
                        Button("Delete meal", role: .destructive) { confirmingDelete = true }
                            .font(.rounded(Theme.FontSize.body, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.md)
                    }
                }
                .foregroundStyle(Theme.ink)
                .padding(Theme.Space.lg)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            .navigationTitle(isNew ? "Add nutrition" : "Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).fontWeight(.bold).disabled(validationMessage != nil)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = nil } }
            }
            .onAppear(perform: load)
            .onChange(of: focused) { _, active in if active != nil { detent = .large } }
            .alert("Couldn’t save changes", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "Your draft is still here. Please try again.") }
            .confirmationDialog("Delete this meal?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete meal", role: .destructive, action: delete)
            } message: { Text("Its nutrition will be removed from your daily totals.") }
        }
        .tint(Theme.Fuel.protein)
        .presentationDetents([.medium, .large], selection: $detent)
    }

    private func scoreHero(_ verdict: HealthScore.Verdict) -> some View {
        HStack(spacing: Theme.Space.md) {
            HealthScoreGauge(verdict: verdict, diameter: 74)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("HEALTH SCORE").font(.rounded(10, weight: .bold)).tracking(1.2)
                if let line = HealthScore.driversLine(verdict.drivers) {
                    Text(line).font(.rounded(Theme.FontSize.caption)).foregroundStyle(Theme.inkSecondary)
                }
                Text(editedNumbers || meal.source == "manual" ? "Your numbers · approximate score" : "Estimated nutrition · editable portions")
                    .font(.rounded(Theme.FontSize.label)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(Theme.Space.md)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func fieldCard(_ fields: [Nutrient]) -> some View {
        VStack(spacing: 0) {
            ForEach(fields) { field in
                HStack {
                    Text(field.label).font(.rounded(Theme.FontSize.body, weight: .semibold))
                    Spacer(minLength: 8)
                    TextField("—", text: Binding(get: { entry.fields[field] ?? "" }, set: { entry.fields[field] = $0 }))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                        .frame(width: 96).focused($focused, equals: .nutrient(field))
                        .accessibilityLabel(field.label)
                        .accessibilityIdentifier("nutrition-\(field.rawValue)")
                    Text(field.unit).font(.rounded(Theme.FontSize.caption)).foregroundStyle(Theme.inkSecondary)
                        .frame(width: 34, alignment: .leading)
                }
                .padding(Theme.Space.md)
                if field != fields.last { Divider().overlay(Theme.hairline) }
            }
        }
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var itemsCard: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name).font(.rounded(Theme.FontSize.body, weight: .semibold))
                    if let basis = item.servingDescription {
                        Text("Per serving: \(basis)").font(.rounded(Theme.FontSize.label)).foregroundStyle(Theme.inkSecondary)
                    }
                    HStack {
                        Text("\(item.kcal) kcal · \(item.carbsG) g carbs")
                            .font(.rounded(Theme.FontSize.label)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                        Spacer(minLength: 4)
                        Button { adjust(item, delta: -0.5) } label: {
                            Image(systemName: "minus").frame(width: 44, height: 44).contentShape(Rectangle())
                        }.accessibilityLabel("Less \(item.name)")
                        Text(item.portionLabel).font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                        Button { adjust(item, delta: 0.5) } label: {
                            Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle())
                        }.accessibilityLabel("More \(item.name)")
                    }
                }
                .padding(.horizontal, Theme.Space.md).padding(.top, Theme.Space.sm)
                .contextMenu { Button("Remove item", role: .destructive) { remove(item) } }
                Divider()
            }
            HStack {
                TextField("Add an item — banana, 2 eggs…", text: $addItemText)
                    .font(.rounded(Theme.FontSize.caption)).focused($focused, equals: .addItem).submitLabel(.done)
                    .onSubmit(addItem).onChange(of: addItemText) { addItemMiss = false }
                Button(action: addItem) { Image(systemName: "plus.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel("Add food to meal")
            }.padding(.horizontal, Theme.Space.md)
            if addItemMiss {
                Text("Not in the offline pantry. Enter its label in a separate meal using Add nutrition.")
                    .font(.rounded(Theme.FontSize.label)).foregroundStyle(Theme.inkSecondary).padding(Theme.Space.md)
            }
            Text("≈\(nutrition.integer(.kcal) ?? 0) kcal · \(nutrition.integer(.carbs) ?? 0) g carbs · \(nutrition.integer(.protein) ?? 0) g protein")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Space.md)
        }
        .buttonStyle(.plain)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        name = meal.text; eatenAt = meal.eatenAt; items = meal.items
        entry = NutritionEntry(meal.nutrition); originalEntry = entry
        totalsMode = items.isEmpty
        if totalsMode || isNew { detent = .large }
    }
    private func addItem() {
        guard let foods = FuelLocalResolver.composeItems(addItemText) else { addItemMiss = true; return }
        items.append(contentsOf: foods); numbersDirty = true; addItemText = ""
        Haptics.light()
    }
    private func adjust(_ item: MealItem, delta: Double) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        if delta < 0, item.qty <= 0.5 { remove(item); return }
        items[index] = item.scaled(to: max(0.25, item.qty + delta))
        numbersDirty = true
        Haptics.light()
    }
    private func remove(_ item: MealItem) {
        items.removeAll { $0.id == item.id }; numbersDirty = true
        // Stay empty: resurrecting the stored totals here counted food the athlete removed.
        Haptics.light()
    }
    private func switchToTotals() {
        entry = NutritionEntry(.sum(items.map(\.exactNutrition)))
        numbersDirty = true; totalsMode = true; detent = .large
    }
    private func save() {
        guard validationMessage == nil else { return }
        let changes = {
            meal.text = name.trimmingCharacters(in: .whitespacesAndNewlines)
            meal.eatenAt = eatenAt
            if isNew || editedNumbers {
                if totalsMode { meal.itemsData = nil; meal.nutrition = nutrition }
                else { meal.items = items }
                meal.source = "manual"; meal.note = nil; meal.confidence = nil
            }
        }
        do {
            if isNew {
                changes()
                let saved = Meal()
                saved.text = meal.text; saved.eatenAt = meal.eatenAt
                FuelLocalResolver.copyNumbers(from: meal, to: saved)
                try MealNutritionStore.insert(saved, in: context)
            } else {
                try MealNutritionStore.update(meal, in: context, changes: changes)
            }
            Haptics.success(); onSaved(); dismiss()
        } catch { errorMessage = "Your draft is still here. Please try saving again." }
    }
    private func delete() {
        do {
            try MealNutritionStore.delete(meal, in: context)
            Haptics.medium(); dismiss()
        } catch { errorMessage = "This meal could not be deleted. Please try again." }
    }
}
