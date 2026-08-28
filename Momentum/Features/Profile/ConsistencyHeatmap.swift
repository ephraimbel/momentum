import SwiftUI

/// A GitHub-style consistency grid for the last `weeks` weeks. Inactive days are a clean light
/// grid; active days fill in **solid brand purple, stepped by how much you actually trained** that
/// day (the GitHub intensity treatment) — a 20-minute jog and a two-hour long run read differently
/// at a glance. Pass `dayMinutes` for the intensity signal; without it, active days render at one
/// solid mid level (binary callers like community profiles). Color is never the sole carrier — a
/// single VoiceOver summary names the active-day count (PRD §13.4).
///
/// `showsAxes` adds the frame that makes the data legible at a glance: month labels above the
/// columns, weekday hints down the left, a quiet ring on today, and the less→more legend.
struct ConsistencyHeatmap: View {
    let countingDays: Set<Int>
    /// Active minutes per local day — drives the intensity steps. Empty = binary rendering.
    var dayMinutes: [Int: Double] = [:]
    var weeks: Int = 16
    var cell: CGFloat = 13
    var spacing: CGFloat = 3
    var showsAxes: Bool = false
    /// The `Less → More` key under the grid (only with axes). Off for a stacked older half-year,
    /// which shares the recent half's key.
    var showsLegend: Bool = true
    /// The grid's newest day. Today by default; a past date renders an older window (the depth
    /// sheet's 52-week view stacks two 26-week grids — pages are vertical-only, never a horizontal
    /// scroller). The today ring appears only when the anchor IS today.
    var anchor: Date = Calendar.current.startOfDay(for: Date())

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The cascade: columns arrive oldest → newest on first appearance (transform-only —
    /// opacity + scale — and Reduce Motion snaps). The grid used to pop in whole.
    @State private var revealed = false

    private var anchorDay: Int { StreakCalculator.localDay(anchor) }
    private var anchoredOnToday: Bool { anchorDay == StreakCalculator.localDay(Date()) }

    var body: some View {
        let today = anchorDay
        let windowDays = weeks * 7
        let activeDays = (0..<windowDays).filter { countingDays.contains(today - $0) }.count
        HStack(alignment: .top, spacing: spacing * 2) {
            if showsAxes { weekdayGutter }
            VStack(alignment: .leading, spacing: spacing * 2) {
                if showsAxes { monthLabels }
                grid(today: today)
                if showsAxes, showsLegend { legend.padding(.top, spacing) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { revealed = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Consistency")
        .accessibilityValue("\(activeDays) of \(windowDays) days active in the last \(weeks) weeks")
    }

    private func grid(today: Int) -> some View {
        ZStack {
            cells(today: today) { day in fill(for: day) }
            // Today: a quiet ink ring anchors "now" at the bottom-right of the story.
            if showsAxes, anchoredOnToday {
                todayRing(today: today)
                    .opacity(revealed ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25).delay(Self.columnDelay * Double(weeks)),
                               value: revealed)
            }
        }
    }

    /// Per-column stagger of the arrival cascade.
    private static let columnDelay = 0.018

    // MARK: Intensity

    /// Solid purple, stepped by training minutes (GitHub's level treatment): a faint baseline for
    /// empty days, then light / medium / full purple at <30 / <75 / 75+ active minutes.
    private func fill(for day: Int) -> Color {
        guard countingDays.contains(day) else { return Theme.inkTertiary.opacity(0.10) }
        return Self.levelColors[level(for: day)]
    }

    private func level(for day: Int) -> Int {
        guard let minutes = dayMinutes[day] else { return 1 }   // binary callers: one solid mid step
        if minutes >= 75 { return 2 }
        if minutes >= 30 { return 1 }
        return 0
    }

    /// A real purple ramp (GitHub uses swatches, not opacity — white-blended tints go washy).
    /// Light lavender → mid violet → the full brand purple.
    static let levelColors: [Color] = [
        Color(hex: "C9BEF9"), Color(hex: "A18BF5"), Theme.purple,
    ]

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
    /// Calendar day arithmetic, not 86 400-second steps — a fall-back DST week would land the
    /// stepped date at 23:00 the prior day and label the row with the wrong weekday.
    private func weekdayLetter(row: Int) -> String {
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: -(6 - row), to: cal.startOfDay(for: anchor))
            ?? anchor
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
        let colTop = cal.startOfDay(for: anchor)
            .addingTimeInterval(TimeInterval(-(((weeks - 1 - col) * 7) + 6) * 86_400))
        if col == 0 { return formatter.string(from: colTop) }
        let prevTop = colTop.addingTimeInterval(-7 * 86_400)
        let changed = cal.component(.month, from: colTop) != cal.component(.month, from: prevTop)
        return changed ? formatter.string(from: colTop) : nil
    }

    /// The GitHub "less → more" key, right-aligned and quiet.
    private var legend: some View {
        HStack(spacing: spacing) {
            Text("Less").font(.rounded(9, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            RoundedRectangle(cornerRadius: 2).fill(Theme.inkTertiary.opacity(0.10))
                .frame(width: 9, height: 9)
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2).fill(Self.levelColors[i])
                    .frame(width: 9, height: 9)
            }
            Text("More").font(.rounded(9, weight: .bold)).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityHidden(true)
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
                .opacity(revealed ? 1 : 0)
                .scaleEffect(revealed ? 1 : 0.85)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.28).delay(Self.columnDelay * Double(col)),
                           value: revealed)
            }
        }
    }

    /// Same geometry, overlaying an arbitrary per-cell view (keeps the today ring pixel-aligned).
    private func cellsOverlay<V: View>(@ViewBuilder _ view: @escaping (Int) -> V) -> some View {
        let today = anchorDay
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
