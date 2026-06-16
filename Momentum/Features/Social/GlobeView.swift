import SwiftUI
import SwiftData
import CoreLocation
import MapboxMaps

/// The momentum globe (docs/SOCIAL-LAYER.md) — a real Mapbox globe of the world (dark basemap, brand
/// canvas). Glowing iridescent dots mark the community at their (city-level, fuzzed) locations, plus
/// you when you've opted onto the map. Drag to spin the globe; tap a dot to open that athlete. Honest
/// presence: only the real seeded community + your own location — no fabricated crowd.
struct GlobeView: View {
    @Query private var profiles: [UserProfile]
    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]
    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @Environment(ModerationStore.self) private var moderation
    @State private var liveCount = 0
    @State private var selected: CommunityAthlete?
    // Opens on North America (the community is US-majority); drag to spin the globe.
    @State private var viewport: Viewport = .camera(center: CLLocationCoordinate2D(latitude: 38, longitude: -97), zoom: 1.35)

    /// Community athletes shown on the globe — blocked athletes are removed.
    private var athletes: [CommunityAthlete] { CommunityDirectory.all().filter { !moderation.isBlocked($0.handle) } }

    private var profile: UserProfile? { profiles.first }
    private var onMap: Bool { profile?.appearOnMap ?? false }
    /// Your dot, from your most recent route — only when you've opted onto the map.
    private var userCoord: CLLocationCoordinate2D? {
        guard onMap,
              let s = workouts.lazy.compactMap({ $0.gps?.samples.first(where: { $0.accepted }) }).first
        else { return nil }
        return CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)
    }

    var body: some View {
        globe
            .ignoresSafeArea()
            .overlay(alignment: .top) { header }
            .overlay(alignment: .bottom) { bottomControls }
            .background(.black)
            .navigationTitle("World")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(item: $selected) { AthleteProfileView(athlete: $0) }
            .task { liveCount = await services.presence.refresh(appearOnMap: onMap) }
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text("Around the world").font(.display(24, weight: .black)).foregroundStyle(.white)
            Text(subtitle)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
        }
        .padding(.top, Theme.Space.sm)
        .frame(maxWidth: .infinity)
        .padding(.bottom, Theme.Space.xl)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var bottomControls: some View {
        VStack(spacing: Theme.Space.md) {
            legend
            mapOptInRow
        }
        .padding(Theme.Space.lg)
        .padding(.bottom, Theme.Space.lg)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
    }

    private var subtitle: String {
        // "live now" only appears when the realtime backend reports real presence (never fabricated).
        let base = "\(athletes.count) in the Momentum community"
        return liveCount > 0 ? "\(base) · \(liveCount) live now" : base
    }

    // MARK: Mapbox globe

    private var globe: some View {
        Map(viewport: $viewport) {
            // Hundreds of community dots render as one circle layer (performant), glowing brand purple.
            CircleAnnotationGroup(athletes) { athlete in
                CircleAnnotation(centerCoordinate: CLLocationCoordinate2D(latitude: athlete.lat, longitude: athlete.lon))
                    .circleColor(StyleColor(UIColor(Theme.route)))
                    .circleRadius(6)
                    .circleBlur(0.6)
                    .circleStrokeColor(StyleColor(UIColor.white.withAlphaComponent(0.85)))
                    .circleStrokeWidth(1)
                    .onTapGesture { selected = athlete }
            }
            // Your own dot (white core, purple ring) when opted onto the map.
            if let me = userCoord {
                CircleAnnotation(centerCoordinate: me)
                    .circleColor(StyleColor(.white))
                    .circleRadius(6)
                    .circleStrokeColor(StyleColor(UIColor(Theme.route)))
                    .circleStrokeWidth(2)
            }
        }
        .mapStyle(.standard)                   // realistic blue-and-green Earth (vector + atmosphere) — lighter than satellite imagery
        .ornamentOptions(MapChrome.hidden)
    }

    private var legend: some View {
        HStack(spacing: Theme.Space.md) {
            dot(Theme.route); Text("Community").font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            if userCoord != nil {
                dot(.white).overlay(Circle().stroke(Theme.route, lineWidth: 2).frame(width: 10, height: 10))
                Text("You").font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
    }
    private func dot(_ color: Color) -> some View { Circle().fill(color).frame(width: 8, height: 8) }

    @ViewBuilder
    private var mapOptInRow: some View {
        if onMap {
            Label("You're on the map", systemImage: "checkmark.circle.fill")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Button {
                profile?.appearOnMap = true; try? context.save(); Haptics.light()
            } label: {
                Label("Appear on the map", systemImage: "mappin.and.ellipse")
                    .font(.rounded(Theme.FontSize.body, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .foregroundStyle(.black)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(.white))
            }
            .buttonStyle(.plain)
            .disabled(profile == nil)
            .accessibilityHint("Show as a fuzzed dot. Never your exact location.")
        }
    }
}
