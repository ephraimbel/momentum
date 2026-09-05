import SwiftUI
import SwiftData

struct HydrationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var day = Date()
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                    .padding(Theme.Space.lg)
                HydrationDayView(day: day)
            }
            .background(Theme.background)
            .navigationTitle("Water").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(Theme.Fuel.sodium)
    }
}

private struct HydrationDayView: View {
    let day: Date
    @Query private var entries: [WaterEntry]
    @Environment(\.modelContext) private var context
    @State private var amount = "250"
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    init(day: Date) {
        self.day = day
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        _entries = Query(filter: #Predicate<WaterEntry> { $0.drankAt >= start && $0.drankAt < end },
                         sort: \WaterEntry.drankAt, order: .reverse)
    }
    private var parsedAmount: Double? {
        var draft = NutritionEntry()
        draft.fields[.fluids] = amount
        let parsed = draft.parsed()
        guard parsed.error == nil, let value = parsed.values[.fluids], value > 0 else { return nil }
        return value
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("\(WaterEntry.total(entries, on: day).formatted()) ml")
                        .font(.display(32, weight: .bold)).monospacedDigit()
                        .accessibilityIdentifier("water-total")
                    Text("Water logged").font(.rounded(Theme.FontSize.caption)).foregroundStyle(Theme.inkSecondary)
                    Text("Your daily fluid total also includes drinks recorded with meals.")
                        .font(.rounded(Theme.FontSize.caption)).foregroundStyle(Theme.inkSecondary)
                }
                HStack {
                    TextField("Amount", text: $amount).keyboardType(.decimalPad).focused($focused)
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).monospacedDigit()
                        .accessibilityIdentifier("water-amount")
                    Text("ml").font(.rounded(Theme.FontSize.caption)).foregroundStyle(Theme.inkSecondary)
                    Button("Log water", action: log).font(.rounded(Theme.FontSize.caption, weight: .bold))
                        .disabled(parsedAmount == nil).frame(minHeight: 44)
                }.padding(Theme.Space.md).raised(RoundedRectangle(cornerRadius: Theme.Radius.card))
                if entries.isEmpty {
                    Text("No water logged for this day.").font(.rounded(Theme.FontSize.caption)).foregroundStyle(Theme.inkSecondary)
                }
                ForEach(entries) { entry in
                    HStack {
                        Image(systemName: "drop.fill").foregroundStyle(Theme.Fuel.sodium)
                        VStack(alignment: .leading) {
                            Text("\(entry.amountMl.formatted()) ml").font(.rounded(Theme.FontSize.body, weight: .semibold)).monospacedDigit()
                            Text(entry.drankAt.formatted(date: .omitted, time: .shortened))
                                .font(.rounded(Theme.FontSize.label)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                        }
                        Spacer()
                        Button(role: .destructive) { delete(entry) } label: {
                            Image(systemName: "trash").frame(width: 44, height: 44)
                        }.accessibilityLabel("Delete \(entry.amountMl.formatted()) milliliters of water")
                    }
                    Divider()
                }
            }.foregroundStyle(Theme.ink).padding(Theme.Space.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = false } } }
        .alert("Couldn’t save water", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "Please try again.") }
    }
    private func log() {
        guard let value = parsedAmount else { return }
        let date = Calendar.current.isDateInToday(day) ? Date() : Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        let entry = WaterEntry(amountMl: value, drankAt: date)
        context.insert(entry)
        do { try context.save(); focused = false; Haptics.success() }
        catch { context.delete(entry); errorMessage = "Your water wasn’t saved. Please try again." }
    }
    private func delete(_ entry: WaterEntry) {
        do {
            try context.save()
            context.delete(entry)
            do { try context.save(); Haptics.light() }
            catch { context.rollback(); throw error }
        } catch { errorMessage = "This water entry could not be deleted. Please try again." }
    }
}
