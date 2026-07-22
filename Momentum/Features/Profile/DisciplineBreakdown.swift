import SwiftUI

/// How the athlete trains — each discipline as a data row: icon chip, name, share-of-training, and
/// a full-width proportion track (the Oura/Whoop data-sheet treatment). Monochrome by design:
/// discipline mix is identity, not progress, so it earns no iridescence (PRD principle). Surfaces
/// the hybrid-athlete shape (runs *and* lifts) at a glance — the product wedge.
struct DisciplineBreakdown: View {
    let counts: [WorkoutType: Int]
    var maxRows: Int = 5

    private var ranked: [(type: WorkoutType, count: Int)] {
        counts.filter { $0.value > 0 }.sorted { $0.value > $1.value }
            .prefix(maxRows).map { (type: $0.key, count: $0.value) }
    }
    private var total: Int { max(1, counts.values.reduce(0, +)) }

    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            ForEach(Array(ranked.enumerated()), id: \.element.type) { index, row in
                let share = Double(row.count) / Double(total)
                VStack(spacing: Theme.Space.sm) {
                    HStack(spacing: Theme.Space.md) {
                        Image(systemName: row.type.systemImage)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                        Text(row.type.title)
                            .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Space.sm)
                        Text("\(row.count)")
                            .font(.display(17, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
                        Text("· \(Int((share * 100).rounded()))%")
                            .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Theme.inkTertiary)
                    }
                    // Full-width share track — every row measured against the same whole, so the
                    // bars read as a composition of your training, not a ranking. Each bar draws
                    // in from the left with a small stagger (a scale transform, never layout);
                    // Reduce Motion shows them settled.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.hairline.opacity(0.7))
                            Capsule().fill(Theme.ink.opacity(0.85))
                                .frame(width: max(5, geo.size.width * share))
                                .scaleEffect(x: drawn || reduceMotion ? 1 : 0.001, anchor: .leading)
                                .animation(reduceMotion ? nil
                                           : .spring(response: 0.55, dampingFraction: 0.85)
                                               .delay(0.15 + Double(index) * 0.07),
                                           value: drawn)
                        }
                    }
                    .frame(height: 5)
                    .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.type.title): \(row.count) workouts, \(Int((share * 100).rounded())) percent of training")
            }
        }
        .onAppear { drawn = true }
    }
}
