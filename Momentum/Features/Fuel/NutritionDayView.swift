import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct NutritionFactsView: View {
    let rows: [NutritionValues]
    var waterMl: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("NUTRITION").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                .foregroundStyle(Theme.inkSecondary)
            ForEach(Nutrient.allCases) { field in
                let food = NutritionCoverage.summarize(rows, field: field)
                let coverage = field == .fluids && waterMl > 0
                    ? NutritionCoverage(total: (food.total ?? 0) + waterMl,
                                        known: rows.isEmpty ? 1 : food.known, count: rows.isEmpty ? 1 : food.count)
                    : food
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(field.label).font(.rounded(Theme.FontSize.body, weight: .semibold))
                        if coverage.total == nil {
                            Text("Not recorded").font(.rounded(Theme.FontSize.label)).foregroundStyle(Theme.inkSecondary)
                        } else if !coverage.isComplete {
                            Text("Partial · \(coverage.known) of \(coverage.count) \(coverage.count == 1 ? "food" : "foods")")
                                .font(.rounded(Theme.FontSize.label)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                        }
                    }
                    Spacer(minLength: Theme.Space.sm)
                    Text(coverage.total.map { "\(NutritionEntry.text($0, field: field)) \(field.unit)" } ?? "—")
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("daily-\(field.rawValue)")
                if field != Nutrient.allCases.last { Divider() }
            }
            Text("Totals reflect recorded food and water. Missing nutrients stay unknown, and estimates remain approximate.")
                .font(.rounded(Theme.FontSize.caption)).foregroundStyle(Theme.inkSecondary)
        }
        .foregroundStyle(Theme.ink)
        .padding(Theme.Space.md)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

struct NutritionDaySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var day = Date()
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .padding(Theme.Space.lg).accessibilityIdentifier("nutrition-day")
                NutritionDayView(day: day)
            }
            .background(Theme.background)
            .navigationTitle("Daily nutrition").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(Theme.Fuel.protein)
    }
}

private struct NutritionDayView: View {
    @Query private var meals: [Meal]
    @Query private var water: [WaterEntry]
    @State private var editing: Meal?

    init(day: Date) {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        _meals = Query(filter: #Predicate<Meal> { $0.eatenAt >= start && $0.eatenAt < end },
                       sort: \Meal.eatenAt)
        _water = Query(filter: #Predicate<WaterEntry> { $0.drankAt >= start && $0.drankAt < end })
    }

    var body: some View {
        let rows = meals.filter { !$0.isDeleted }
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text(rows.isEmpty ? "No meals recorded for this day." : "\(rows.count) \(rows.count == 1 ? "entry" : "entries") recorded")
                    .font(.rounded(Theme.FontSize.caption)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                NutritionFactsView(rows: rows.flatMap(\.nutritionRows), waterMl: water.filter { !$0.isDeleted }.map(\.amountMl).reduce(0, +))
                if !rows.isEmpty {
                    Text("MEALS").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                    ForEach(rows) { meal in
                        Button { editing = meal } label: {
                            HStack {
                                Text(meal.journalTitle).multilineTextAlignment(.leading)
                                Spacer()
                                Text(meal.kcal.map { "\($0) kcal" } ?? "—").monospacedDigit()
                                Image(systemName: "chevron.right")
                            }
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                            .padding(.vertical, Theme.Space.sm)
                        }.foregroundStyle(Theme.ink)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.lg).padding(.bottom, Theme.Space.xxl)
        }
        .sheet(item: $editing) { MealDetailSheet(meal: $0) }
    }
}

struct NutritionCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
