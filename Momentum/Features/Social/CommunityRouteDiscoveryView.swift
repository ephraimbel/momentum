import SwiftUI
import SwiftData

/// Distances are SI; bucket labels follow the athlete's display preference.
enum CommunityRouteDistance: String, CaseIterable, Identifiable {
    case all, short, medium, long, longer
    var id: Self { self }
    func label(unit: DistanceUnit) -> String {
        let miles = unit.resolved() == .imperial
        switch self {
        case .all: return "Any distance"
        case .short: return miles ? "Under 3 mi" : "Under 5 km"
        case .medium: return miles ? "3–6 mi" : "5–10 km"
        case .long: return miles ? "6–12 mi" : "10–20 km"
        case .longer: return miles ? "12+ mi" : "20+ km"
        }
    }
    func contains(meters: Double, unit: DistanceUnit) -> Bool {
        guard meters.isFinite, meters > 0 else { return false }
        let edges = unit.resolved() == .imperial
            ? [3, 6, 12].map { Double($0) * Formatters.metersPerMile } : [5000.0, 10000, 20000]
        switch self {
        case .all: return true
        case .short: return meters < edges[0]
        case .medium: return meters >= edges[0] && meters < edges[1]
        case .long: return meters >= edges[1] && meters < edges[2]
        case .longer: return meters >= edges[2]
        }
    }
}

struct CommunityRouteDiscoveryView: View {
    let items: [FeedItem]
    let ownHandle: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query private var profiles: [UserProfile]
    @State private var distance: CommunityRouteDistance = .all
    @State private var location = ""
    @State private var opened: FeedItem?
    // This is a snapshot of posts in the current wall, preserving its scope/moderation decisions.
    private var routes: [FeedItem] { items.filter { $0.hasRenderableRoute && $0.distanceKm > 0 } }
    private var locations: [String] { Array(Set(routes.compactMap { $0.metro ?? $0.location })).sorted() }
    private var unit: DistanceUnit { DistanceUnit(rawValue: profiles.first?.distanceUnit ?? "auto") ?? .auto }
    private var results: [FeedItem] {
        routes.filter { (location.isEmpty || ($0.metro ?? $0.location) == location)
            && distance.contains(meters: $0.distanceKm * 1000, unit: unit) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            distanceMenu
                            locationMenu
                        }
                    } else {
                        HStack { distanceMenu; Spacer(); locationMenu }
                    }
                }
                .font(.rounded(13, weight: .semibold))
                .padding(Theme.Space.md)
                Text(dynamicTypeSize.isAccessibilitySize ? "Routes from this wall."
                     : "Routes from the posts on this wall. Save one to find it again later.")
                    .font(.rounded(12, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Theme.Space.md)
                if routes.isEmpty {
                    ContentUnavailableView("No routes here yet", systemImage: "map",
                        description: Text("Posts with shared routes will appear here as they reach this wall."))
                } else if results.isEmpty {
                    ContentUnavailableView {
                        Label("No matching routes", systemImage: "map")
                    } description: { Text("Try another distance or location.") } actions: {
                        Button("Clear filters") { distance = .all; location = "" }
                    }
                } else {
                    List(results) { item in
                        Button { opened = item; Haptics.light() } label: {
                            HStack(spacing: 12) {
                                FeedTileMedia(item: item, respectsPhotoCover: false, showsMapStatus: false)
                                    .frame(width: 64, height: 80).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.rounded(15, weight: .semibold)).foregroundStyle(Theme.ink)
                                    Text(Formatters.distance(meters: item.distanceKm * 1000, unit: unit))
                                        .font(.rounded(13, weight: .medium)).monospacedDigit()
                                    Text([item.authorName, item.location].compactMap { $0 }.joined(separator: " · "))
                                        .font(.rounded(12, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                                        .lineLimit(2)
                                    if item.isCommunity { Text("Example route").font(.rounded(10, weight: .medium)).foregroundStyle(Theme.inkTertiary) }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(CommunityControlPressStyle())
                        .listRowBackground(Theme.background)
                    }
                    .listStyle(.plain)
                    .communitySnapshotScrolling()
                }
            }
            .background(Theme.background)
            .navigationTitle("Browse routes").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fullScreenCover(item: $opened) { item in
                CommunityPager(items: [item], startID: item.id, ownHandle: ownHandle)
            }
            .onChange(of: distance) { Haptics.selection() }
            .onChange(of: location) { Haptics.selection() }
        }
    }
    private var distanceMenu: some View {
        Menu {
            Picker("Distance", selection: $distance) {
                ForEach(CommunityRouteDistance.allCases) { value in
                    Text(value.label(unit: unit)).tag(value)
                }
            }
        } label: {
            Label(distance.label(unit: unit), systemImage: "ruler")
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .frame(minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier("community.routes.distance")
        .disabled(routes.isEmpty)
    }

    private var locationMenu: some View {
        Menu {
            Picker("Location", selection: $location) {
                Text("All locations").tag("")
                ForEach(locations, id: \.self) { Text($0).tag($0) }
            }
        } label: {
            Label(location.isEmpty ? "All locations" : location, systemImage: "mappin")
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .frame(minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier("community.routes.location")
        .disabled(routes.isEmpty)
    }

}
