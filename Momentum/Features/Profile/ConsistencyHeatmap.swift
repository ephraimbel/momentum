import SwiftUI

/// A GitHub-style consistency grid for the last `weeks` weeks. Active days glow earned-iridescent
/// (consistency is progress); rest days are hairline. Shared by the Profile and Progress surfaces so
/// they can't diverge. Color is never the sole carrier — a single VoiceOver summary names the
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
        HStack(spacing: spacing) {
            ForEach(0..<weeks, id: \.self) { col in
                VStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { row in
                        let day = today - ((weeks - 1 - col) * 7) - (6 - row)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(countingDays.contains(day)
                                  ? AnyShapeStyle(IridescentMaterial())
                                  : AnyShapeStyle(Theme.hairline))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Consistency")
        .accessibilityValue("\(activeDays) of \(windowDays) days active in the last \(weeks) weeks")
    }
}
