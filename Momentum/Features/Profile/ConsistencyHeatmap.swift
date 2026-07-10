import SwiftUI

/// A GitHub-style consistency grid for the last `weeks` weeks. Inactive days are a clean light grid;
/// active days reveal **one** cohesive iridescent sheet that flows across the whole grid (earned
/// accent — consistency is progress). Doing it as a single masked sheet (the `MuscleMapView`
/// technique) — rather than filling each 13px square with its own gradient — is what makes active
/// days read as a vivid, intentional accent instead of muddy per-square pastels. Shared by the
/// Profile surfaces. Color is never the sole carrier — a single VoiceOver summary names the
/// active-day count (PRD §13.4).
///
/// `showsAxes` adds the frame that makes the data legible at a glance (the GitHub treatment):
/// month labels above the columns, weekday hints down the left, and a quiet ring on today.
struct ConsistencyHeatmap: View {
    let countingDays: Set<Int>
    var weeks: Int = 16
    var cell: CGFloat = 13
    var spacing: CGFloat = 3
    var showsAxes: Bool = false

    var body: some View {
        let today = StreakCalculator.localDay(Date())
        let windowDays = weeks * 7
        let activeDays = (0..<windowDays).filter { countingDays.contains(today - $0) }.count
        HStack(alignment: .top, spacing: spacing * 2) {
            if showsAxes { weekdayGutter }
            VStack(alignment: .leading, spacing: spacing * 2) {
                if showsAxes { monthLabels }
                grid(today: today)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Consistency")
        .accessibilityValue("\(activeDays) of \(windowDays) days active in the last \(weeks) weeks")
    }

    private func grid(today: Int) -> some View {
        ZStack {
            // Baseline: every day as a faint, clean square so the grid structure always reads.
            cells(today: today) { _ in Theme.inkTertiary.opacity(0.12) }
            // Active days: a single iridescent gradient spanning the whole grid, revealed only through
            // the active squares — so they share one flowing accent (periwinkle → peach) and stand out.
            Rectangle().fill(IridescentMaterial())
                .mask(cells(today: today) { day in countingDays.contains(day) ? Color.white : Color.clear })
            // Today: a quiet ink ring anchors "now" at the bottom-right of the story.
            if showsAxes { todayRing(today: today) }
        }
    }

    // MARK: Axes

    /// Weekday hints down the left — every other row, GitHub-style, so the gutter stays quiet.
    private var weekdayGutter: some View {
        VStack(spacing: spacing) {
            ForEach(0..<7, id: \.self) { row in
                Text(row.isMultiple(of: 2) ? "" : weekdayLetter(row: row))
                    .font(.rounded(9, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                    .frame(width: 12, height: cell)
            }
        }
        .padding(.top, 12 + spacing * 2)   // clear the month-label row
    }

    /// Every column's row `r` is the same weekday (columns are exactly 7 days apart).
    private func weekdayLetter(row: Int) -> String {
        let date = Calendar.current.startOfDay(for: Date())
            .addingTimeInterval(TimeInterval(-(6 - row) * 86_400))
        let symbol = Calendar.current.shortWeekdaySymbols[
            Calendar.current.component(.weekday, from: date) - 1]
        return String(symbol.prefix(1))
    }

    /// A month label above the first column of each new month (the GitHub rule).
    private var monthLabels: some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return HStack(spacing: spacing) {
            ForEach(0..<weeks, id: \.self) { col in
                Text(monthLabel(col: col, formatter: formatter) ?? "")
                    .font(.rounded(9, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                    .fixedSize()   // keep the full "Apr" — it overflows its column, GitHub-style
                    .frame(width: cell, height: 12, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func monthLabel(col: Int, formatter: DateFormatter) -> String? {
        let cal = Calendar.current
        let colTop = cal.startOfDay(for: Date())
            .addingTimeInterval(TimeInterval(-(((weeks - 1 - col) * 7) + 6) * 86_400))
        if col == 0 { return formatter.string(from: colTop) }
        let prevTop = colTop.addingTimeInterval(-7 * 86_400)
        let changed = cal.component(.month, from: colTop) != cal.component(.month, from: prevTop)
        return changed ? formatter.string(from: colTop) : nil
    }

    private func todayRing(today: Int) -> some View {
        cellsOverlay { day in
            if day == today {
                RoundedRectangle(cornerRadius: 2).stroke(Theme.ink, lineWidth: 1.25)
            }
        }
    }

    // MARK: Grid plumbing

    /// The week×day grid of rounded squares, each filled by `color(day)`. Used for both the baseline
    /// layer and the active-day mask, so the two stay pixel-aligned.
    private func cells(today: Int, _ color: @escaping (Int) -> Color) -> some View {
        HStack(spacing: spacing) {
            ForEach(0..<weeks, id: \.self) { col in
                VStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { row in
                        let day = today - ((weeks - 1 - col) * 7) - (6 - row)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(day))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
    }

    /// Same geometry, overlaying an arbitrary per-cell view (keeps the today ring pixel-aligned).
    private func cellsOverlay<V: View>(@ViewBuilder _ view: @escaping (Int) -> V) -> some View {
        let today = StreakCalculator.localDay(Date())
        return HStack(spacing: spacing) {
            ForEach(0..<weeks, id: \.self) { col in
                VStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { row in
                        let day = today - ((weeks - 1 - col) * 7) - (6 - row)
                        ZStack { view(day) }.frame(width: cell, height: cell)
                    }
                }
            }
        }
    }
}
