import SwiftUI
import SwiftData

/// The look-back journal (top-right calendar on Fuel), built for months of data:
/// **search** (always visible — meal words, item names, even the coach note) over a year's window,
/// **month headers** (static — they scroll with their days; user call 2026-07-16) with a
/// logged-days count for orientation, then each day with its Σ line
/// and meals in the same row language as the main page. Read-first, but tapping a meal opens the
/// same portion editor (fixing history is legitimate; totals update live). The iridescent dot
/// beside a date marks a day that met the easy carb floor — earned, as always.
struct FuelHistoryView: View {
    @Query(sort: \Meal.eatenAt, order: .reverse) private var meals: [Meal]
    @Query private var profiles: [UserProfile]
    @State private var editing: Meal?
    @State private var query = ""

    /// The browsing window — a full training year. The footer says so when there's more beyond it.
    private static let windowDays = 365

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                if months.isEmpty {
                    emptyState
                        .reveal(0.05)
                } else {
                    ForEach(months, id: \.month) { entry in
                        Section {
                            ForEach(entry.days, id: \.day) { day in
                                daySection(day)
                            }
                        } header: {
                            monthHeader(entry)
                        }
                    }
                    if truncated, query.isEmpty {
                        Text("Showing the last year.")
                            .font(.rounded(Theme.FontSize.label, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, Theme.Space.sm)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
            .animation(Motion.standard, value: months.map(\.month))
        }
        .background(Theme.background)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search meals — “pasta”, “gel”…")
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $editing) { MealDetailSheet(meal: $0) }
    }

    // MARK: Window → search → months → days (all lazy-rendered; grouping is plain string/date work)

    private var window: [Meal] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.windowDays,
                                           to: Calendar.current.startOfDay(for: Date())) ?? .distantPast
        return meals.filter { $0.eatenAt >= cutoff }
    }

    private var truncated: Bool { meals.count > window.count }

    /// Case-insensitive across the athlete's words, the AI's item names, and the note — "pasta"
    /// finds "big pasta dinner" and "Cooked Pasta ×2" alike.
    private var filtered: [Meal] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return window }
        return window.filter {
            $0.text.localizedCaseInsensitiveContains(q)
                || $0.journalTitle.localizedCaseInsensitiveContains(q)
                || ($0.note?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var months: [(month: Date, days: [(day: Date, rows: [Meal])])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.eatenAt) }
            .map { (day: $0.key, rows: $0.value.sorted { $0.eatenAt > $1.eatenAt }) }
        return Dictionary(grouping: byDay) { cal.dateInterval(of: .month, for: $0.day)?.start ?? $0.day }
            .map { (month: $0.key, days: $0.value.sorted { $0.day > $1.day }) }
            .sorted { $0.month > $1.month }
    }

    // MARK: Month header — the orientation rail (static: it scrolls with its days)

    private func monthHeader(_ entry: (month: Date, days: [(day: Date, rows: [Meal])])) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(monthTitle(entry.month))
                .font(.display(15, weight: .bold)).tracking(0.6)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
            Text("\(entry.days.count) day\(entry.days.count == 1 ? "" : "s") logged")
                .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.inkTertiary)
        }
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity)
    }

    /// "JULY" for this year, "JULY 2025" once the journal crosses a year line.
    private func monthTitle(_ month: Date) -> String {
        let cal = Calendar.current
        let sameYear = cal.component(.year, from: month) == cal.component(.year, from: Date())
        return (sameYear ? month.formatted(.dateTime.month(.wide))
                         : month.formatted(.dateTime.month(.wide).year())).uppercased()
    }

    // MARK: One day

    private func daySection(_ entry: (day: Date, rows: [Meal])) -> some View {
        let carbs = entry.rows.compactMap(\.carbsG).reduce(0, +)
        let kg = profiles.first?.bodyMassKg ?? FuelReadiness.fallbackMassKg
        let metEasyFloor = carbs >= Int(FuelReadiness.carbsPerKgEasy * kg)
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: 7) {
                Text(dayTitle(entry.day))
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Theme.inkTertiary)
                if metEasyFloor {
                    Circle().fill(AnyShapeStyle(IridescentMaterial()))
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Fueled day")
                }
                Spacer(minLength: 0)
                Text(sumLine(entry.rows, carbs: carbs))
                    .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.inkTertiary)
            }
            VStack(spacing: 0) {
                ForEach(entry.rows) { meal in
                    row(meal)
                    if meal.id != entry.rows.last?.id {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        }
    }

    /// "TODAY" / "YESTERDAY" / "MONDAY, JUL 14" — the same section voice as the main page.
    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "TODAY" }
        if cal.isDateInYesterday(day) { return "YESTERDAY" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased()
    }

    private func sumLine(_ rows: [Meal], carbs: Int) -> String {
        let kcal = rows.compactMap(\.kcal).reduce(0, +)
        return "≈\(carbs) g carbs · \(kcal.formatted()) kcal"
    }

    private func row(_ meal: Meal) -> some View {
        Button { editing = meal } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.sm) {
                    Text(meal.journalTitle)
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Text(meal.eatenAt.formatted(date: .omitted, time: .shortened))
                        .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
                if let numbers = meal.journalNumbersText {
                    numbers
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                } else {
                    Text("No numbers — tap to set them")
                        .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.purple)
                }
                if let note = meal.note, !note.isEmpty {
                    Text(note).font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary).lineLimit(2)
                }
            }
            .padding(Theme.Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Meal: \(meal.text)")
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: query.isEmpty ? "fork.knife" : "magnifyingglass")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            Text(query.isEmpty ? "Your journal builds here — every day you log meals."
                               : "No meals match \u{201C}\(query)\u{201D}.")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.xxl)
    }
}
