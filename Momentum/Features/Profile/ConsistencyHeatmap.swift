import SwiftUI

/// A GitHub-style consistency grid for the last `weeks` weeks. Inactive days are a clean light grid;
/// active days reveal **one** cohesive iridescent sheet that flows across the whole grid (earned
/// accent — consistency is progress). Doing it as a single masked sheet (the `MuscleMapView`
/// technique) — rather than filling each 13px square with its own gradient — is what makes active
/// days read as a vivid, intentional accent instead of muddy per-square pastels. Shared by the
/// Profile surfaces. Color is never the sole carrier — a single VoiceOver summary names the
/// active-day count (PRD §13.4).
struct ConsistencyHeatmap: View {
    let countingDays: Set<Int>
    var weeks: Int = 16
    var cell: CGFloat = 13
    var spacing: CGFloat = 3

    var body: some View {
        let today = StreakCalculator.localDay(Date())
        let windowDays = weeks * 7
        let activeDays = (0..<windowDays).filter { countingDays.contains(today - $0) }.count
        ZStack {
            // Baseline: every day as a faint, clean square so the grid structure always reads.
            cells(today: today) { _ in Theme.inkTertiary.opacity(0.12) }
            // Active days: a single iridescent gradient spanning the whole grid, revealed only through
            // the active squares — so they share one flowing accent (periwinkle → peach) and stand out.
            Rectangle().fill(IridescentMaterial())
                .mask(cells(today: today) { day in countingDays.contains(day) ? Color.white : Color.clear })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Consistency")
        .accessibilityValue("\(activeDays) of \(windowDays) days active in the last \(weeks) weeks")
    }

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
}
