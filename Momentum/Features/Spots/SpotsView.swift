import SwiftUI
import CoreLocation
import MapboxMaps

/// "Spots near you" — real parks, trailheads, and nature reserves to run or hike, surfaced from map
/// data near the athlete (PRD §6). Map-first like AllTrails/Strava: spots as tappable dots over the
/// brand basemap, a Run/Hike filter, and a ranked list (nearest first; community-popular spots bump up
/// once that layer ships). Pick one to get a loop there or step-by-step directions.
struct SpotsView: View {
    @State private var vm: SpotsViewModel
    @State private var viewport: Viewport
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let distanceUnit: DistanceUnit
    private let onLoopHere: (GeoPoint) -> Void
    private let onClose: () -> Void

    init(origin: GeoPoint,
         provider: any SpotsProviding,
         distanceUnit: DistanceUnit = .auto,
         activity: SpotActivity? = nil,
         analytics: (any AnalyticsServing)? = nil,
         onLoopHere: @escaping (GeoPoint) -> Void = { _ in },
         onClose: @escaping () -> Void = {}) {
        _vm = State(initialValue: SpotsViewModel(
            origin: origin, provider: provider, activity: activity,
            onLoaded: { n in analytics?.log(.spotsViewed(count: n)) },
            onSelected: { k in analytics?.log(.spotSelected(kind: k.rawValue)) }))
        _viewport = State(initialValue: .camera(center: origin.clCoordinate, zoom: 12))
        self.distanceUnit = distanceUnit
        self.onLoopHere = onLoopHere
        self.onClose = onClose
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            map
            topBar
            panel
        }
        .task { await vm.load() }
        .onChange(of: vm.selectedID) { focusSelected() }
    }

    // MARK: Map

    private var map: some View {
        MapReader { proxy in
        Map(viewport: $viewport) {
            // Purple "you" puck configured imperatively in `.onStyleLoaded` (see BrandPuck.apply) to
            // avoid the SwiftUI `Puck2D` device crash.
            CircleAnnotationGroup(vm.spots) { spot in
                CircleAnnotation(centerCoordinate: spot.point.clCoordinate)
                    .circleColor(StyleColor(UIColor(spot.id == vm.selectedID ? Theme.ink : Theme.route)))
                    .circleRadius(spot.id == vm.selectedID ? 9 : 6)
                    .circleStrokeColor(StyleColor(.white))
                    .circleStrokeWidth(2)
                    .onTapGesture { select(spot) }
            }
            if let sel = vm.selected {
                MapViewAnnotation(coordinate: sel.point.clCoordinate) { callout(sel) }
                    .allowOverlap(true)
            }
        }
        .mapStyle(MapStyleOption.persisted.mapboxStyle)   // follow the athlete's app-wide choice
        .ornamentOptions(MapChrome.hidden)
        .onStyleLoaded { _ in BrandPuck.apply(to: proxy) }
        .ignoresSafeArea()
        }
    }

    /// A small name bubble over the selected spot.
    private func callout(_ spot: Spot) -> some View {
        Text(spot.name)
            .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.background)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.sm).padding(.vertical, 6)
            .background(Capsule().fill(Theme.ink))
            .offset(y: -22)
            .allowsHitTesting(false)
    }

    // MARK: Top chrome

    private var topBar: some View {
        VStack(spacing: Theme.Space.sm) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 38, height: 38)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().stroke(Theme.hairline))
                }
                .accessibilityLabel("Close")
                Spacer()
                Text("Spots near you").font(.display(18, weight: .bold)).foregroundStyle(Theme.ink)
                Spacer()
                Color.clear.frame(width: 38, height: 38)   // balance the X
            }
            activityFilter
        }
        .padding(Theme.Space.md)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// All / Run / Hike — re-ranks the spots already in hand (no refetch).
    private var activityFilter: some View {
        HStack(spacing: Theme.Space.sm) {
            filterPill(nil, label: "All", icon: "circle.grid.2x2")
            ForEach(SpotActivity.allCases) { a in filterPill(a, label: a.title, icon: a.systemImage) }
        }
    }

    private func filterPill(_ activity: SpotActivity?, label: String, icon: String) -> some View {
        let on = vm.activity == activity
        return Button { Haptics.light(); vm.setActivity(activity) } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold))
                Text(label).font(.rounded(Theme.FontSize.caption, weight: .bold))
            }
            .foregroundStyle(on ? Theme.background : Theme.ink)
            .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
            .background(Capsule().fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(.regularMaterial)))
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: on ? 0 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Bottom panel

    private var panel: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sheet).stroke(Theme.hairline))
            .padding(Theme.Space.md)
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .idle, .loading:
            HStack(spacing: Theme.Space.sm) {
                ProgressView()
                Text("Finding spots near you…")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            }
            .frame(maxWidth: .infinity).frame(height: 92)
        case .empty:
            VStack(spacing: 6) {
                Text("No spots found nearby").font(.display(17, weight: .bold)).foregroundStyle(Theme.ink)
                Text("Try a different filter, or check your connection.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await vm.reload() } }
                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity).frame(height: 110).padding(.horizontal, Theme.Space.md)
        case .loaded(let spots):
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(spots) { spot in
                        spotRow(spot)
                        if spot.id != spots.last?.id { Divider().overlay(Theme.hairline).padding(.leading, 56) }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private func spotRow(_ spot: Spot) -> some View {
        let on = spot.id == vm.selectedID
        return VStack(spacing: 0) {
            Button { select(spot) } label: {
                HStack(spacing: Theme.Space.md) {
                    ZStack {
                        Circle().fill(Theme.route.opacity(0.16))
                        Image(systemName: spot.kind.systemImage).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.route)
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spot.name).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(subtitle(spot)).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                    }
                    Spacer(minLength: Theme.Space.sm)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Formatters.distance(meters: spot.distanceM, unit: distanceUnit))
                            .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                        if let runs = spot.popularity.runs, runs > 0 { popularBadge(runs) }
                    }
                }
                .padding(.vertical, Theme.Space.sm).padding(.horizontal, Theme.Space.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if on { actions(spot).padding(.horizontal, Theme.Space.md).padding(.bottom, Theme.Space.sm) }
        }
        .background(on ? Theme.route.opacity(0.06) : .clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(spot.name), \(spot.kind.title), \(Formatters.distance(meters: spot.distanceM, unit: distanceUnit)) away")
    }

    private func actions(_ spot: Spot) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Button { Haptics.light(); onLoopHere(spot.point) } label: {
                Label("Loop here", systemImage: "arrow.triangle.capsulepath")
                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.ink))
            }
            .buttonStyle(.plain)
            Button { openDirections(spot) } label: {
                Label("Directions", systemImage: "location.fill")
                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
        }
    }

    private func popularBadge(_ runs: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill").font(.system(size: 9, weight: .bold))
            Text("\(runs)").font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
        }
        .foregroundStyle(Theme.route)
    }

    private func subtitle(_ spot: Spot) -> String {
        [spot.kind.title, spot.neighborhood].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Actions

    private func select(_ spot: Spot) {
        Haptics.light()
        vm.select(spot)
    }

    private func focusSelected() {
        guard let sel = vm.selected else { return }
        withViewportAnimation(reduceMotion ? .easeInOut(duration: 0) : .easeInOut(duration: 0.5)) {
            viewport = .camera(center: sel.point.clCoordinate, zoom: 14)
        }
    }

    /// Walking directions to the spot in Apple Maps.
    private func openDirections(_ spot: Spot) {
        Haptics.light()
        let q = "\(spot.point.lat),\(spot.point.lon)"
        if let url = URL(string: "http://maps.apple.com/?daddr=\(q)&dirflg=w") { openURL(url) }
    }
}

#Preview {
    SpotsView(origin: GeoPoint(lat: 30.2672, lon: -97.7431), provider: PreviewSpots())
}

/// Deterministic sample spots so the sheet renders in previews without the network.
private struct PreviewSpots: SpotsProviding {
    func nearbySpots(around point: GeoPoint, kinds: [SpotKind], limitPerKind: Int) async -> [Spot] {
        [
            Spot(id: "1", name: "Republic Square", kind: .park, point: GeoPoint(lat: 30.2677, lon: -97.7469), neighborhood: "Downtown", distanceM: 0),
            Spot(id: "2", name: "Roy & Ann Butler Hike-and-Bike Trail", kind: .trail, point: GeoPoint(lat: 30.2644, lon: -97.7560), neighborhood: "Zilker", distanceM: 0),
            Spot(id: "3", name: "Mount Bonnell", kind: .mountain, point: GeoPoint(lat: 30.3210, lon: -97.7730), neighborhood: nil, distanceM: 0),
        ]
    }
}
