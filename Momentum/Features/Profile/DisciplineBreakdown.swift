import SwiftUI

/// How the athlete trains — workout counts by discipline with a quiet proportion bar. Monochrome by
/// design: discipline mix is identity, not progress, so it earns no iridescence (PRD principle).
/// Surfaces the hybrid-athlete shape (runs *and* lifts) at a glance — the product wedge.
struct DisciplineBreakdown: View {
    let counts: [WorkoutType: Int]
    var maxRows: Int = 5

    private var ranked: [(type: WorkoutType, count: Int)] {
        counts.filter { $0.value > 0 }.sorted { $0.value > $1.value }
            .prefix(maxRows).map { (type: $0.key, count: $0.value) }
    }
    private var topCount: Int { max(1, ranked.first?.count ?? 1) }

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            ForEach(ranked, id: \.type) { row in
                HStack(spacing: Theme.Space.md) {
                    Image(systemName: row.type.systemImage)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                        .frame(width: 22)
                    Text(row.type.title)
                        .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.sm)
                    bar(for: row.count)
                    Text("\(row.count)")
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.ink).frame(width: 36, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.type.title): \(row.count) workouts")
            }
        }
    }

    private func bar(for count: Int) -> some View {
        let fraction = CGFloat(count) / CGFloat(topCount)
        return ZStack(alignment: .leading) {
            Capsule().fill(Theme.hairline)
            Capsule().fill(Theme.ink.opacity(0.85))
                .frame(width: max(6, 76 * fraction))
        }
        .frame(width: 76, height: 6)
        .accessibilityHidden(true)
    }
}
