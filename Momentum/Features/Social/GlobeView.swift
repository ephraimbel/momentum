import SwiftUI
import SwiftData

/// The momentum globe (docs/SOCIAL-LAYER.md, Slice 3) — a custom, Apple-native minimalist globe
/// (Canvas + orthographic projection, no map SDK, no bundled textures). Glowing iridescent dots mark
/// the community (and you, if you've opted onto the map). Drag to spin; tap a dot to open that
/// athlete. Honest presence: only the real seeded community + your own location — no fabricated crowd.
struct GlobeView: View {
    @Query private var profiles: [UserProfile]
    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]
    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @Environment(ModerationStore.self) private var moderation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var liveCount = 0

    @State private var rotation: Double = 0
    @State private var tilt: Double = 0.35
    @State private var dragging = false
    @State private var dragAnchor: (rotation: Double, tilt: Double)?
    @State private var globeSize: CGSize = .zero
    @State private var selected: CommunityAthlete?

    private let tick = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()
    /// Community athletes shown on the globe — blocked athletes are removed.
    private var athletes: [CommunityAthlete] { CommunityDirectory.all().filter { !moderation.isBlocked($0.handle) } }

    private var profile: UserProfile? { profiles.first }
    private var onMap: Bool { profile?.appearOnMap ?? false }
    /// Your dot, from your most recent route — only when you've opted onto the map.
    private var userCoord: (lat: Double, lon: Double)? {
        guard onMap,
              let s = workouts.lazy.compactMap({ $0.gps?.samples.first(where: { $0.accepted }) }).first
        else { return nil }
        return (s.lat, s.lon)
    }

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            header
            globe
            legend
            mapOptInRow
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.lg)
        .background(Theme.background)
        .navigationTitle("World")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selected) { AthleteProfileView(athlete: $0) }
        .onReceive(tick) { _ in
            guard !reduceMotion, !dragging else { return }
            rotation += 0.0022
        }
        .task { liveCount = await services.presence.refresh(appearOnMap: onMap) }
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text("Around the world").font(.display(24, weight: .black)).foregroundStyle(Theme.ink)
            Text(subtitle)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
        }
    }

    private var subtitle: String {
        // "live now" only appears when the realtime backend reports real presence (never fabricated).
        let base = "\(athletes.count) in the Momentum community"
        return liveCount > 0 ? "\(base) · \(liveCount) live now" : base
    }

    private var globe: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(into: &ctx, size: size) }
                .onAppear { globeSize = geo.size }
                .onChange(of: geo.size) { _, s in globeSize = s }
                .gesture(drag)
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { hitTest($0.location, size: geo.size) }
                )
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private var legend: some View {
        HStack(spacing: Theme.Space.md) {
            dot(Theme.route); Text("Community").font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            if userCoord != nil {
                dot(.white).overlay(Circle().stroke(Theme.route, lineWidth: 2).frame(width: 10, height: 10))
                Text("You").font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            }
            Spacer(minLength: 0)
        }
    }
    private func dot(_ color: Color) -> some View { Circle().fill(color).frame(width: 8, height: 8) }

    @ViewBuilder
    private var mapOptInRow: some View {
        if onMap {
            Label("You're on the map", systemImage: "checkmark.circle.fill")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
        } else {
            Button {
                profile?.appearOnMap = true; try? context.save(); Haptics.light()
            } label: {
                Label("Appear on the map", systemImage: "mappin.and.ellipse")
                    .font(.rounded(Theme.FontSize.body, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .foregroundStyle(Theme.background)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.ink))
            }
            .buttonStyle(.plain)
            .disabled(profile == nil)
            .accessibilityHint("Show as a fuzzed dot. Never your exact location.")
        }
    }

    // MARK: Rendering

    private func draw(into ctx: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = min(size.width, size.height) / 2 * 0.94
        let proj = GlobeProjection(rotation: rotation, tilt: tilt)

        // Sphere body — lit from upper-left, falling to near-black at the limb.
        let sphere = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(sphere, with: .radialGradient(
            Gradient(colors: [Color(white: 0.17), Color(white: 0.06), .black]),
            center: CGPoint(x: center.x - r * 0.3, y: center.y - r * 0.3), startRadius: 0, endRadius: r * 1.25))
        ctx.stroke(sphere, with: .color(Theme.route.opacity(0.25)), lineWidth: 1)

        drawGraticule(&ctx, proj: proj, center: center, r: r)

        for a in athletes { drawDot(&ctx, proj: proj, center: center, r: r, lat: a.lat, lon: a.lon, color: Theme.route, isUser: false) }
        if let u = userCoord { drawDot(&ctx, proj: proj, center: center, r: r, lat: u.lat, lon: u.lon, color: .white, isUser: true) }
    }

    private func drawGraticule(_ ctx: inout GraphicsContext, proj: GlobeProjection, center: CGPoint, r: CGFloat) {
        let line = GraphicsContext.Shading.color(Color(white: 0.30))
        // Parallels.
        for latLine in stride(from: -60.0, through: 60.0, by: 30.0) {
            ctx.stroke(meridianOrParallel(proj: proj, center: center, r: r, fixedLat: latLine), with: line, lineWidth: 0.5)
        }
        // Meridians.
        for lonLine in stride(from: -150.0, through: 180.0, by: 30.0) {
            ctx.stroke(meridianOrParallel(proj: proj, center: center, r: r, fixedLon: lonLine), with: line, lineWidth: 0.5)
        }
    }

    /// Build a polyline path for a parallel (fixedLat) or meridian (fixedLon), front hemisphere only.
    private func meridianOrParallel(proj: GlobeProjection, center: CGPoint, r: CGFloat,
                                    fixedLat: Double? = nil, fixedLon: Double? = nil) -> Path {
        var path = Path()
        var pen = false
        let range = stride(from: -180.0, through: 180.0, by: 6.0)
        for t in range {
            let p = fixedLat != nil
                ? proj.project(latDeg: fixedLat!, lonDeg: t)
                : proj.project(latDeg: t, lonDeg: fixedLon!)
            guard p.front else { pen = false; continue }
            let s = GlobeProjection.screen(p, center: center, radius: r)
            if pen { path.addLine(to: s) } else { path.move(to: s); pen = true }
        }
        return path
    }

    private func drawDot(_ ctx: inout GraphicsContext, proj: GlobeProjection, center: CGPoint, r: CGFloat,
                         lat: Double, lon: Double, color: Color, isUser: Bool) {
        let p = proj.project(latDeg: lat, lonDeg: lon)
        guard p.front else { return }
        let s = GlobeProjection.screen(p, center: center, radius: r)
        let near = 0.55 + 0.45 * p.depth                       // closer dots read brighter/bigger
        let core: CGFloat = (isUser ? 5 : 4) * near
        let glow = core * 3.2
        // Soft iridescent halo (respects Reduce Motion implicitly — no animation, just static glow).
        ctx.fill(Path(ellipseIn: CGRect(x: s.x - glow, y: s.y - glow, width: 2 * glow, height: 2 * glow)),
                 with: .radialGradient(Gradient(colors: [color.opacity(0.55 * near), .clear]),
                                       center: s, startRadius: 0, endRadius: glow))
        ctx.fill(Path(ellipseIn: CGRect(x: s.x - core, y: s.y - core, width: 2 * core, height: 2 * core)),
                 with: .color(isUser ? .white : color))
        if isUser {
            ctx.stroke(Path(ellipseIn: CGRect(x: s.x - core, y: s.y - core, width: 2 * core, height: 2 * core)),
                       with: .color(Theme.route), lineWidth: 1.5)
        }
    }

    // MARK: Gestures

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { g in
                if dragAnchor == nil { dragAnchor = (rotation, tilt); dragging = true }
                let a = dragAnchor!
                rotation = a.rotation + Double(g.translation.width) / 90
                tilt = max(-1.2, min(1.2, a.tilt - Double(g.translation.height) / 160))
            }
            .onEnded { _ in dragAnchor = nil; dragging = false }
    }

    private func hitTest(_ loc: CGPoint, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = min(size.width, size.height) / 2 * 0.94
        let proj = GlobeProjection(rotation: rotation, tilt: tilt)
        var best: (CommunityAthlete, CGFloat)?
        for a in athletes {
            let p = proj.project(latDeg: a.lat, lonDeg: a.lon)
            guard p.front else { continue }
            let s = GlobeProjection.screen(p, center: center, radius: r)
            let d = hypot(s.x - loc.x, s.y - loc.y)
            if d < 34, best == nil || d < best!.1 { best = (a, d) }
        }
        if let hit = best { Haptics.light(); selected = hit.0 }
    }
}
