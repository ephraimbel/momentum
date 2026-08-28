import SwiftUI

/// Consistency on the Progress page (owner call 2026-08-28): the SAME GitHub-grade grid the
/// profile's Highlights carries — `ConsistencyHeatmap`, intensity stepped by active minutes,
/// month and weekday axes, the today ring, the count-up headline — in place of the eight-week
/// pill calendar, so the two pages can never drift. The card answers in one line; the tap
/// answers in full (`ConsistencyDetailSheet`): longer windows and the streak/volume numbers
/// behind the picture.
struct ConsistencyCard: View {
    let stats: ProfileStats
    let dayMinutes: [Int: Double]
    var weeks: Int = 16
    var onOpen: () -> Void = {}

    var body: some View {
        let today = StreakCalculator.localDay(Date())
        let active = ConsistencyFacts.activeDays(countingDays: stats.countingDays, weeks: weeks, today: today)
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        EyebrowLabel(text: "Consistency", tint: Theme.purple)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            CountUpNumber(value: Double(active), format: { "\(Int($0.rounded()))" },
                                          font: .display(22, weight: .black), delay: 0.15)
                            Text("active days · last \(weeks) weeks")
                                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    Spacer(minLength: Theme.Space.sm)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                        .padding(.top, 4)
                }
                ConsistencyHeatmap(countingDays: stats.countingDays, dayMinutes: dayMinutes,
                                   weeks: weeks, showsAxes: true)
            }
            .padding(Theme.Space.md + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .raised(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        // ONE VoiceOver element with the grid's summary (PRD §13.4 — colour is never the sole
        // carrier), plus the door.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Consistency")
        .accessibilityValue("\(active) of \(weeks * 7) days active in the last \(weeks) weeks")
        .accessibilityHint("Opens the consistency detail")
        .accessibilityAddTraits(.isButton)
    }
}

/// The tap-through: the same grid over longer windows — 16 and 26 weeks in one grid, a year as
/// two stacked half-years (pages are vertical-only, never a horizontal scroller) — with the
/// window's numbers laid out beneath, and the intensity rule stated in plain words.
struct ConsistencyDetailSheet: View {
    let stats: ProfileStats
    let dayMinutes: [Int: Double]
    let sessionsByDay: [Int: Int]
    @Environment(\.dismiss) private var dismiss

    private enum Window: String, CaseIterable, Identifiable {
        case sixteen = "16W", half = "26W", year = "52W"
        var id: Self { self }
        var weeks: Int {
            switch self {
            case .sixteen: 16
            case .half: 26
            case .year: 52
            }
        }
        var phrase: String {
            switch self {
            case .sixteen: "last 16 weeks"
            case .half: "last 26 weeks"
            case .year: "last year"
            }
        }
    }

    @State private var window: Window = .sixteen
    /// The grid's available width — cells size to fit it, never scroll.
    @State private var gridWidth: CGFloat = 340

    private static let spacing: CGFloat = 3
    /// The weekday gutter plus its gap, as `ConsistencyHeatmap` lays it out.
    private static let gutter: CGFloat = 12 + 6

    private var today: Int { StreakCalculator.localDay(Date()) }
    private var facts: ConsistencyFacts.Window {
        ConsistencyFacts.window(countingDays: stats.countingDays, dayMinutes: dayMinutes,
                                sessionsByDay: sessionsByDay, weeks: window.weeks, today: today)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    hero.reveal(0)
                    picker.reveal(0.03)
                    grids.reveal(0.06)
                    numbers.reveal(0.09)
                    rule.reveal(0.12)
                }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.vertical, Theme.Space.md)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            }
            .background(Theme.background)
            .navigationTitle("Consistency")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold).foregroundStyle(Theme.ink)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var hero: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            CountUpNumber(value: Double(facts.activeDays), format: { "\(Int($0.rounded()))" },
                          font: .display(40, weight: .black), delay: 0.1)
                .id(window)   // a fresh count-up per window
            Text("active days · \(window.phrase)")
                .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private var picker: some View {
        SegmentedCapsule(items: Window.allCases, selection: $window, scale: .compact,
                         title: { $0.rawValue }, spokenLabel: { $0.phrase })
    }

    /// One grid for 16/26 weeks; the year is two stacked 26-week halves — older above, the recent
    /// half (with today's ring and the key) below.
    @ViewBuilder
    private var grids: some View {
        let cal = Calendar.current
        let todayDate = cal.startOfDay(for: Date())
        switch window {
        case .sixteen, .half:
            grid(weeks: window.weeks, anchor: todayDate, showsLegend: true)
        case .year:
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                grid(weeks: 26, anchor: cal.date(byAdding: .day, value: -26 * 7, to: todayDate) ?? todayDate,
                     showsLegend: false)
                grid(weeks: 26, anchor: todayDate, showsLegend: true)
            }
        }
    }

    private func grid(weeks: Int, anchor: Date, showsLegend: Bool) -> some View {
        let cell = min(13, max(7, floor((gridWidth - Self.gutter - CGFloat(weeks - 1) * Self.spacing)
                                        / CGFloat(weeks))))
        return ConsistencyHeatmap(countingDays: stats.countingDays, dayMinutes: dayMinutes,
                                  weeks: weeks, cell: cell, spacing: Self.spacing,
                                  showsAxes: true, showsLegend: showsLegend, anchor: anchor)
            .id("\(window.rawValue)-\(anchor.timeIntervalSinceReferenceDate)")   // re-cascade per window
    }

    /// The window's numbers: two rows of three, the profile's lifetime-cell type.
    private var numbers: some View {
        let f = facts
        let hours = f.activeMinutes / 60
        let cells: [(String, String)] = [
            ("\(f.activeDays) of \(f.windowDays)", "Active days"),
            (hours >= 10 ? String(format: "%.0f h", hours) : String(format: "%.1f h", hours), "Active time"),
            // One-line labels only: a wrapping label drops its value's baseline out of line with
            // its neighbours, and the block reads as three columns or not at all.
            (String(format: "%.1f", f.sessionsPerWeek), "Per week"),
            ("\(f.bestWeekSessions)", "Best week"),
            ("\(stats.currentStreak)d", "Streak"),
            ("\(stats.longestStreak)d", "Best streak"),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                         alignment: .leading, spacing: Theme.Space.lg) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.0).font(.display(18, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(c.1.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.8)
                        .foregroundStyle(Theme.inkTertiary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// The intensity rule, stated: what "more" actually means.
    private var rule: some View {
        Text("A day counts once it qualifies as training. Its depth is active minutes: light under 30, mid to 75, full at 75 and beyond. Streaks also credit the rest days your plan scheduled.")
            .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
