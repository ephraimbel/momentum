import SwiftUI

/// A compact "Your map" banner at the top of History — the personal heatmap as a glanceable look-back
/// (not a tab). Renders nothing until there are GPS routes, so it never shows an empty box; taps to
/// open the full `PersonalHeatmapView`.
struct HeatmapHistoryCard: View {
    let workouts: [Workout]
    var distanceUnit: DistanceUnit = .auto

    /// The athlete's own map style — the card is a preview of `PersonalHeatmapView`, so it must
    /// render in the same basemap. It used to hardcode `.standard` (Light), which put a bright
    /// white tile in the middle of a dark-mode page and disagreed with the page it opened.
    @AppStorage(MapStyleOption.storageKey) private var style: MapStyleOption = .realistic
    @Environment(\.colorScheme) private var colorScheme
    @State private var result: HeatmapSource.Result?
    /// Session cache: the History branch is destroyed on every segment flip, so an uncached build
    /// re-faulted + re-binned the entire GPS history per visit and the card popped in late,
    /// shifting the feed. `Result` is pure values (cells/count/meters) — safe to hold statically.
    ///
    /// Keyed on the CONTENT signature, not the count (the rule the rest of Progress already
    /// follows): an equal-count edit — delete a mis-logged run, log the real one — left the map
    /// drawing the deleted route for the whole session.
    @MainActor private static var cache: (key: Int, result: HeatmapSource.Result)?
    // --heatmap-expand: auto-open the full PersonalHeatmapView on appear (website screenshot).
    @State private var expand = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--heatmap-expand")
        #else
        return false
        #endif
    }()

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
        // Keyed on the data, not the mount: a run logged mid-session now refreshes the card
        // (the old `if result == nil` guard froze "N activities" for the view's life), while a
        // cache hit renders instantly on re-visits instead of re-binning the whole history.
        .task(id: workouts.contentSignature) {
            let key = workouts.contentSignature
            if let cached = Self.cache, cached.key == key {
                if result == nil { result = cached.result }
                return
            }
            let built = await HeatmapSource.build(from: workouts)
            Self.cache = (key, built)
            result = built
        }
        .fullScreenCover(isPresented: $expand) {
            PersonalHeatmapView(distanceUnit: distanceUnit) { expand = false }
        }
    }

    private func card(_ r: HeatmapSource.Result) -> some View {
        ZStack(alignment: .bottomLeading) {
            HeatmapMapView(cells: r.cells, style: style.uriStyle(for: colorScheme))
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
