import SwiftUI
import SwiftData

/// The look-back journal (top-right calendar on Fuel): every logged day, newest first — the day's
/// Σ line, then its meals in the same row language as the main page. Read-first, but tapping a
/// meal opens the same portion editor (fixing history is legitimate; totals update live). The
/// iridescent dot beside a date marks a day that met the easy carb floor — earned, as always.
struct FuelHistoryView: View {
    @Query(sort: \Meal.eatenAt, order: .reverse) private var meals: [Meal]
    @Query private var profiles: [UserProfile]
    @State private var editing: Meal?

    /// The browsing window — enough to see a training block's story without grouping years of
    /// rows on every render. The footer says so when there's more beyond it.
    private static let windowDays = 60

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                if days.isEmpty {
                    emptyState
                        .reveal(0.05)
                } else {
                    ForEach(Array(days.enumerated()), id: \.element.day) { i, entry in
                        daySection(entry)
                            .reveal(min(0.24, Double(i) * 0.05))
                    }
                    if truncated {
                        Text("Showing the last \(Self.windowDays) days.")
                            .font(.rounded(Theme.FontSize.label, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, Theme.Space.sm)
                    }
                }
            }
            .padding(Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { MealDetailSheet(meal: $0) }
    }

    // MARK: Days (grouped in-window; the window keeps render work bounded)

    private var window: [Meal] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.windowDays,
                                           to: Calendar.current.startOfDay(for: Date())) ?? .distantPast
        return meals.filter { $0.eatenAt >= cutoff }
    }

    private var truncated: Bool { meals.count > window.count }

    private var days: [(day: Date, rows: [Meal])] {
        Dictionary(grouping: window) { Calendar.current.startOfDay(for: $0.eatenAt) }
            .map { (day: $0.key, rows: $0.value.sorted { $0.eatenAt > $1.eatenAt }) }
            .sorted { $0.day > $1.day }
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
        return "≈\(carbs) g carbs · \(kcal) kcal"
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
                if let numbers = meal.journalNumbersLine {
                    Text(numbers)
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.inkSecondary)
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
            Image(systemName: "fork.knife")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            Text("Your journal builds here — every day you log meals.")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.xxl)
    }
}
