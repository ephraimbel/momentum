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

    private var distanceUnit: DistanceUnit {
        DistanceUnit(rawValue: profiles.first?.distanceUnit ?? "auto") ?? .auto
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if routes.isEmpty {
                    emptyState
                } else {
                    ForEach(routes) { row($0) }
                }
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationTitle("Saved")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $opened) { SavedRouteDetailView(route: $0) }
    }

    private func row(_ route: SavedRoute) -> some View {
        // A route opens its explorable map; a routeless save (a strength day, a swim) is the kept
        // post itself — its row is informational, no map to promise, no chevron that lies.
        //
        // The routeless row is NOT a Button any more (2026-08-29). It used to be one whose action
        // was `if route.hasRoute { … }`, so for a routeless save it took the press highlight,
        // announced itself to VoiceOver as a button, and then did nothing — a dead control, which
        // is exactly what this audit is about. Long-press to Remove still works on both.
        Group {
            if route.hasRoute {
                Button { opened = route } label: { rowBody(route) }
                    .buttonStyle(.plain)
            } else {
                rowBody(route)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
        .contextMenu {
            Button(role: .destructive) {
                context.delete(route)
                try? context.save()
                Haptics.light()
            } label: { Label("Remove", systemImage: "bookmark.slash") }
        }
        .accessibilityLabel("\(route.title), \(subtitle(route))")
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
                        .foregroundStyle(Theme.inkTertiary).lineLimit(1)
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
                            .frame(width: 36, height: 36).background(Circle().fill(Theme.surface)).overlay(Circle().stroke(Theme.hairline))
                    }
                    .accessibilityLabel("Close")
                    Spacer()
                    Button {
                        context.delete(route)
                        try? context.save()
                        Haptics.light()
                        dismiss()
                    } label: {
                        Image(systemName: "bookmark.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 36, height: 36).background(Circle().fill(Theme.surface)).overlay(Circle().stroke(Theme.hairline))
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
    }
}

#Preview {
    NavigationStack { SavedRoutesView() }
        .modelContainer(for: [SavedRoute.self, UserProfile.self], inMemory: true)
}
