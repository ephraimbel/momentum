import SwiftUI
import MapKit

/// "Suggest a loop" — pick a distance, get up to three path-snapped loops from here, shuffle for
/// alternatives, pick one. Chrome floats (glass) over the map; the selected loop wears the
/// earned-iridescent accent (PRD §6). Run/walk/hike only (MapKit has no cycling directions).
struct RouteSuggestionView: View {
    @State private var vm: RouteSuggestionViewModel
    private let onUse: (SuggestedLoop) -> Void
    private let onClose: () -> Void

    @State private var camera: MapCameraPosition = .automatic
    @State private var mapStyle: MapStyleOption = .standard

    init(start: GeoPoint, targetM: Double = 5000, distanceUnit: DistanceUnit = .auto,
         directions: DirectionsProviding = MapKitDirectionsProvider(),
         onUse: @escaping (SuggestedLoop) -> Void = { _ in },
         onClose: @escaping () -> Void = {}) {
        _vm = State(initialValue: RouteSuggestionViewModel(
            start: start, targetM: targetM, distanceUnit: distanceUnit, directions: directions))
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
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            Annotation("Start", coordinate: vm.start.clCoordinate) { startDot }
            // Non-selected first, so the selected loop draws on top.
            ForEach(vm.candidates.filter { $0.id != vm.selectedID }) { loop in
                MapPolyline(coordinates: loop.polyline.map(\.clCoordinate))
                    .stroke(mapStyle.isImagery ? Color.white.opacity(0.7) : Theme.inkTertiary.opacity(0.35),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let sel = vm.selected {
                let coords = sel.polyline.map(\.clCoordinate)
                MapPolyline(coordinates: coords)
                    .stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: coords)
                    .stroke(LinearGradient(colors: Theme.iridescent, startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
        }
        .mapStyle(mapStyle.mapStyle)
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
        HStack {
            stat(Formatters.distance(meters: loop.distanceM, unit: vm.distanceUnit), "Distance")
            Spacer()
            stat(Formatters.duration(s: loop.estDurationS), "Est. time")
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
        let lats = loop.polyline.map(\.lat), lons = loop.polyline.map(\.lon)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                            longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.005, (lats.max()! - lats.min()!) * 1.5),
                                    longitudeDelta: max(0.005, (lons.max()! - lons.min()!) * 1.5))
        withAnimation(.easeInOut(duration: 0.5)) {
            camera = .region(MKCoordinateRegion(center: center, span: span))
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
