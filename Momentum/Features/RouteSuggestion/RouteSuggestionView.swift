import SwiftUI
import CoreLocation
import MapboxMaps

/// "Suggest a loop" — pick a distance, get up to three path-snapped loops from here, shuffle for
/// alternatives, pick one. Chrome floats (glass) over the map; the selected loop wears the
/// earned-iridescent accent (PRD §6). Run/walk/hike only (no cycling directions).
struct RouteSuggestionView: View {
    @State private var vm: RouteSuggestionViewModel
    private let onUse: (SuggestedLoop) -> Void
    private let onClose: () -> Void

    @State private var viewport: Viewport
    @State private var mapStyle: MapStyleOption = .standard

    init(start: GeoPoint, targetM: Double = 5000, distanceUnit: DistanceUnit = .auto,
         directions: DirectionsProviding = MapKitDirectionsProvider(),
         onUse: @escaping (SuggestedLoop) -> Void = { _ in },
         onClose: @escaping () -> Void = {}) {
        _vm = State(initialValue: RouteSuggestionViewModel(
            start: start, targetM: targetM, distanceUnit: distanceUnit, directions: directions))
        // Open locked on the athlete's location, not the whole world — we reframe to the loop once
        // candidates load.
        _viewport = State(initialValue: .camera(center: start.clCoordinate, zoom: 13))
        self.onUse = onUse
        self.onClose = onClose
    }

    private static let distances: [Double] = [3000, 5000, 10000]

    var body: some View {
        ZStack(alignment: .bottom) {
            map
            topBar
            panel
        }
        .task { if vm.candidates.isEmpty { await vm.suggest() } }
        .onChange(of: vm.selectedID) { frameSelected() }
        .onChange(of: vm.candidates.count) { frameSelected() }
    }

    // MARK: Map

    private var map: some View {
        Map(viewport: $viewport) {
            MapViewAnnotation(coordinate: vm.start.clCoordinate) { startDot }.allowOverlap(true)
            // Non-selected first, so the selected loop draws on top.
            PolylineAnnotationGroup(vm.candidates.filter { $0.id != vm.selectedID }) { loop in
                PolylineAnnotation(lineCoordinates: loop.polyline.map(\.clCoordinate))
                    .lineColor(StyleColor(UIColor(mapStyle.isImagery ? Color.white.opacity(0.7) : Theme.inkTertiary.opacity(0.35))))
                    .lineWidth(4).lineJoin(.round)
            }
            if let sel = vm.selected {
                PolylineAnnotation(lineCoordinates: sel.polyline.map(\.clCoordinate))
                    .lineColor(StyleColor(UIColor.white.withAlphaComponent(0.55)))
                    .lineWidth(10).lineJoin(.round)
                // Earned accent — solid iridescent stop (annotations can't carry a gradient stroke).
                PolylineAnnotation(lineCoordinates: sel.polyline.map(\.clCoordinate))
                    .lineColor(StyleColor(UIColor(Theme.iridescent[0])))
                    .lineWidth(6).lineJoin(.round)
            }
        }
        .mapStyle(mapStyle.mapboxStyle)
        .ornamentOptions(MapChrome.hidden)
        .ignoresSafeArea()
    }

    private var startDot: some View {
        ZStack {
            Circle().fill(IridescentMaterial()).frame(width: 24, height: 24).opacity(0.6)
            Circle().fill(Theme.ink).frame(width: 12, height: 12)
            Circle().strokeBorder(.white, lineWidth: 2).frame(width: 12, height: 12)
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        VStack {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 38, height: 38)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().stroke(Theme.hairline))
                }
                Spacer()
                MapLayersButton(style: $mapStyle)
            }
            .padding(Theme.Space.md)
            Spacer()
        }
    }

    private var panel: some View {
        VStack(spacing: Theme.Space.md) {
            distancePicker
            content
        }
        .padding(Theme.Space.md)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sheet).stroke(Theme.hairline))
        .padding(Theme.Space.md)
    }

    /// 3K / 5K / 10K segmented selection.
    private var distancePicker: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(Self.distances, id: \.self) { d in
                let on = d == vm.targetM
                Button { Task { await vm.setDistance(d) } } label: {
                    Text("\(Int(d / 1000))K")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.sm)
                        .foregroundStyle(on ? Theme.background : Theme.ink)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Color.clear)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .stroke(Theme.hairline, lineWidth: on ? 0 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading {
            HStack(spacing: Theme.Space.sm) {
                ProgressView()
                Text("Finding loops near you…")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            }
            .frame(maxWidth: .infinity).frame(height: 96)
        } else if vm.didFail {
            VStack(spacing: 4) {
                Text("No loop found here").font(.display(18, weight: .bold)).foregroundStyle(Theme.ink)
                Text("Try a different distance, or move to a more connected area.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).frame(height: 96)
        } else if let sel = vm.selected {
            candidatePicker
            selectedStats(sel)
            HStack(spacing: Theme.Space.md) {
                OversizedButton(title: "Shuffle", systemImage: "shuffle", kind: .outline) { Task { await vm.shuffle() } }
                OversizedButton(title: "Use this route", systemImage: "figure.run") { onUse(sel) }
            }
        }
    }

    /// One pill per candidate loop — tap to highlight it on the map.
    private var candidatePicker: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(Array(vm.candidates.enumerated()), id: \.element.id) { idx, loop in
                let on = loop.id == vm.selectedID
                Button { vm.selectedID = loop.id } label: {
                    Text("Loop \(idx + 1)")
                        .font(.rounded(Theme.FontSize.label, weight: .bold))
                        .foregroundStyle(on ? Theme.ink : Theme.inkTertiary)
                        .padding(.horizontal, Theme.Space.md).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .overlay {
                            if on {
                                Capsule()
                                    .fill(LinearGradient(colors: Theme.iridescent, startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .opacity(0.18).allowsHitTesting(false)
                            }
                        }
                        .overlay(Capsule().stroke(Theme.hairline))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func selectedStats(_ loop: SuggestedLoop) -> some View {
        // Distance only — no estimated time. Everyone runs at their own pace, so a nominal-pace
        // estimate would be misleading; the loop's actual distance is the honest, useful number.
        HStack {
            stat(Formatters.distance(meters: loop.distanceM, unit: vm.distanceUnit), "Distance")
            Spacer()
        }
        .padding(.horizontal, Theme.Space.sm)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.display(22, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1).foregroundStyle(Theme.inkTertiary)
        }
    }

    // MARK: Camera

    private func frameSelected() {
        guard let loop = vm.selected, loop.polyline.count > 1 else { return }
        let coords = loop.polyline.map(\.clCoordinate)
        withAnimation(.easeInOut(duration: 0.5)) {
            viewport = .overview(geometry: LineString(coords),
                                 geometryPadding: EdgeInsets(top: 90, leading: 40, bottom: 230, trailing: 40))
        }
    }
}

/// Straight-segment mock so the canvas renders without network — the loop still reads as a polygon.
private struct PreviewDirections: DirectionsProviding {
    func walkingLeg(from: GeoPoint, to: GeoPoint) async throws -> RouteLeg {
        RouteLeg(distanceM: from.distance(to: to) * 1.3, polyline: [from, to])
    }
}

#Preview {
    RouteSuggestionView(start: GeoPoint(lat: 30.2672, lon: -97.7431), directions: PreviewDirections())
}
