import SwiftUI

/// A compact "Your map" banner at the top of History — the personal heatmap as a glanceable look-back
/// (not a tab). Renders nothing until there are GPS routes, so it never shows an empty box; taps to
/// open the full `PersonalHeatmapView`.
struct HeatmapHistoryCard: View {
    let workouts: [Workout]
    var distanceUnit: DistanceUnit = .auto

    @State private var result: HeatmapSource.Result?
    @State private var expand = false

    var body: some View {
        // ZStack with a zero-size anchor: lifecycle modifiers never fire on a Group that renders
        // EmptyView, so a bare `if` here would leave `.task` dead and the card permanently hidden.
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            if let r = result, !r.cells.isEmpty {
                Button { expand = true } label: { card(r) }
                    .buttonStyle(.plain)
            }
        }
        .task { if result == nil { result = await HeatmapSource.build(from: workouts) } }
        .fullScreenCover(isPresented: $expand) {
            PersonalHeatmapView(distanceUnit: distanceUnit) { expand = false }
        }
    }

    private func card(_ r: HeatmapSource.Result) -> some View {
        ZStack(alignment: .bottomLeading) {
            HeatmapMapView(cells: r.cells, style: .standard)
                .frame(height: 200)
                .allowsHitTesting(false)               // the whole card is the tap target
            LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("YOUR MAP")
                        .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(.white.opacity(0.85))
                    Text("\(r.activityCount) \(r.activityCount == 1 ? "activity" : "activities") · \(Formatters.distance(meters: r.totalMeters, unit: distanceUnit)) mapped")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(Theme.Space.md)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
    }
}
