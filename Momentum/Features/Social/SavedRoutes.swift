import SwiftUI
import SwiftData

/// The athlete's saved-route library (2026-07-29) — routes bookmarked from community posts,
/// browsable before a run. Pushed from the wall's utility strip. Rows lead with the route's
/// SHAPE (the silhouette, instantly) and open a full, explorable map.
struct SavedRoutesView: View {
    @Query(sort: \SavedRoute.savedAt, order: .reverse) private var routes: [SavedRoute]
    /// The athlete's unit preference. This library used to hardcode `"%.1f mi"`, so a metric
    /// athlete saved an 8 km loop off the wall and the library called it 5.0 mi — the same
    /// distance reading as two different numbers on two screens (found 2026-08-29). Distances are
    /// stored SI and converted at display time, like everywhere else in the app.
    @Query private var profiles: [UserProfile]
    @Environment(\.modelContext) private var context
    @State private var opened: SavedRoute?
    @State private var collections = RouteCollectionStore()
    @State private var selectedCollection: UUID?
    @State private var creatingCollection = false
    @State private var collectionName = ""
    @State private var routeToCollect: UUID?
    @State private var removalFailed = false

    private var visibleRoutes: [SavedRoute] {
        guard let selectedCollection,
              let collection = collections.collections.first(where: { $0.id == selectedCollection }) else { return routes }
        return routes.filter { collection.routeIDs.contains($0.id) }
    }

    private var distanceUnit: DistanceUnit {
        DistanceUnit(rawValue: profiles.first?.distanceUnit ?? "auto") ?? .auto
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !routes.isEmpty || !collections.collections.isEmpty { collectionBar }
                if routes.isEmpty {
                    emptyState
                } else if visibleRoutes.isEmpty {
                    ContentUnavailableView("This collection is empty", systemImage: "folder",
                        description: Text("Open a saved post's menu to add it here."))
                } else {
                    ForEach(visibleRoutes) { row($0) }
                }
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationTitle("Saved")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $opened) { SavedRouteDetailView(route: $0) }
        .task(id: profiles.first?.id) {
            collections.load(profileID: profiles.first?.id)
            collections.prune(validIDs: Set(routes.map(\.id)))
            selectedCollection = nil
        }
        .onChange(of: routes.map(\.id)) { _, ids in collections.prune(validIDs: Set(ids)) }
        .alert("New collection", isPresented: $creatingCollection) {
            TextField("Collection name", text: $collectionName)
            Button("Create") {
                if let id = collections.create(name: collectionName) {
                    if let routeToCollect { collections.add(routeID: routeToCollect, to: id) }
                    selectedCollection = id
                    Haptics.success()
                }
                routeToCollect = nil
            }
            .disabled(collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { routeToCollect = nil }
        } message: { Text("Keep routes and posts together. Collections stay on this device.") }
        .alert("Couldn't remove this save", isPresented: $removalFailed) {
            Button("OK", role: .cancel) { }
        } message: { Text("Your saved post is still here. Please try again.") }
    }

    private var collectionBar: some View {
        HStack {
            Menu {
                Button("All saved") { selectedCollection = nil }
                ForEach(collections.collections) { collection in
                    Button(collection.name) { selectedCollection = collection.id }
                }
            } label: {
                Label(collections.collections.first(where: { $0.id == selectedCollection })?.name ?? "All saved",
                      systemImage: "folder")
                    .font(.rounded(14, weight: .semibold)).lineLimit(1)
            }
            .accessibilityIdentifier("saved.collections.filter")
            Spacer()
            if let selectedCollection {
                Menu {
                    Button("Delete collection", role: .destructive) {
                        collections.remove(selectedCollection)
                        self.selectedCollection = nil
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel("Collection options")
            }
            Button { collectionName = ""; routeToCollect = nil; creatingCollection = true } label: {
                Image(systemName: "folder.badge.plus").frame(width: 44, height: 44)
            }
            .buttonStyle(CommunityControlPressStyle())
            .accessibilityLabel("New collection")
            .disabled(profiles.first == nil)
        }
        .padding(.vertical, Theme.Space.sm)
    }

    private func row(_ route: SavedRoute) -> some View {
        HStack(spacing: 0) {
            Group {
                if route.hasRoute {
                    Button { opened = route; Haptics.light() } label: { rowBody(route) }
                        .buttonStyle(CommunityControlPressStyle())
                } else { rowBody(route) }
            }
            .accessibilityLabel("\(route.title), \(subtitle(route))")
            Menu { routeActions(route) } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Organize \(route.title)")
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
        .contextMenu { routeActions(route) }
    }

    @ViewBuilder private func routeActions(_ route: SavedRoute) -> some View {
        ForEach(collections.collections) { collection in
            Button {
                collections.toggle(routeID: route.id, in: collection.id); Haptics.selection()
            } label: {
                Label(collection.name, systemImage: collection.routeIDs.contains(route.id) ? "checkmark.circle.fill" : "folder")
            }
        }
        Button("New collection…", systemImage: "folder.badge.plus") {
            collectionName = ""; routeToCollect = route.id; creatingCollection = true
        }
        .disabled(profiles.first == nil)
        Divider()
        Button(role: .destructive) {
            context.delete(route)
            do { try context.save(); Haptics.light() }
            catch { context.rollback(); removalFailed = true }
        } label: { Label("Remove saved post", systemImage: "bookmark.slash") }
    }

    private func rowBody(_ route: SavedRoute) -> some View {
        HStack(spacing: Theme.Space.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.surface)
                    if route.hasRoute {
                        RouteSilhouette(coords: route.coordinates)
                            .stroke(Theme.route, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .padding(8)
                    } else {
                        Image(systemName: route.sport.systemImage)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
                .frame(width: 56, height: 56)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.title.isEmpty ? (route.hasRoute ? "Saved route" : "Saved post") : route.title)
                        .font(.rounded(15, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(subtitle(route))
                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if route.hasRoute {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
            }
        .padding(.vertical, Theme.Space.sm + 2)
        .contentShape(Rectangle())
    }

    private func subtitle(_ route: SavedRoute) -> String {
        var parts: [String] = []
        if route.km > 0 { parts.append(Formatters.distance(meters: route.km * 1000, unit: distanceUnit)) }
        if let city = route.city { parts.append(city) }
        if let handle = route.authorHandle { parts.append("from @\(handle)") }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "bookmark")
                .font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            Text("Nothing saved yet")
                .font(.display(20, weight: .bold)).foregroundStyle(Theme.ink)
            Text("See something you like on the wall? Open it and tap the bookmark — routes land here ready for your next run.")
                .font(.rounded(Theme.FontSize.body, weight: .regular)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.xl)
        .padding(.top, Theme.Space.xxl)
    }
}

/// One saved route, full bleed — the explorable map the bookmark promised. The same visual
/// grammar as a pager page: media under soft scrims, title + stats over it, quiet chrome.
struct SavedRouteDetailView: View {
    let route: SavedRoute
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]
    @State private var removalFailed = false

    private var distanceUnit: DistanceUnit {
        DistanceUnit(rawValue: profiles.first?.distanceUnit ?? "auto") ?? .auto
    }

    var body: some View {
        ZStack {
            RouteMapView(coordinates: route.coordinates, style: route.mapStyle, interactive: true)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                SoftScrim.top(Theme.background)
                    .frame(height: 170)
                Spacer(minLength: 0)
                SoftScrim.bottom(Theme.background)
                    .frame(height: 280)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 44, height: 44).background(Circle().fill(Theme.surface)).overlay(Circle().stroke(Theme.hairline))
                    }
                    .accessibilityLabel("Close")
                    Spacer()
                    Button {
                        context.delete(route)
                        do {
                            try context.save()
                            Haptics.light()
                            dismiss()
                        } catch {
                            context.rollback()
                            removalFailed = true
                        }
                    } label: {
                        Image(systemName: "bookmark.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 44, height: 44).background(Circle().fill(Theme.surface)).overlay(Circle().stroke(Theme.hairline))
                    }
                    .accessibilityLabel("Remove from saved routes")
                }
                Spacer()
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text(route.title.isEmpty ? "Saved route" : route.title)
                        .font(.display(26, weight: .black)).foregroundStyle(Theme.ink).lineLimit(2)
                    HStack(spacing: 6) {
                        if route.km > 0 {
                            Text(Formatters.distance(meters: route.km * 1000, unit: distanceUnit))
                                .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                                .foregroundStyle(Theme.ink)
                        }
                        if let city = route.city {
                            Circle().fill(Theme.inkTertiary).frame(width: 2.5, height: 2.5)
                            Text(city).font(.rounded(Theme.FontSize.body, weight: .medium))
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        if let handle = route.authorHandle {
                            Circle().fill(Theme.inkTertiary).frame(width: 2.5, height: 2.5)
                            Text("from @\(handle)").font(.rounded(Theme.FontSize.body, weight: .medium))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.sm)
        }
        .background(Theme.background)
        .alert("Couldn't remove this save", isPresented: $removalFailed) {
            Button("OK", role: .cancel) { }
        } message: { Text("Your saved route is still here. Please try again.") }
    }
}

#Preview {
    NavigationStack { SavedRoutesView() }
        .modelContainer(for: [SavedRoute.self, UserProfile.self], inMemory: true)
}
