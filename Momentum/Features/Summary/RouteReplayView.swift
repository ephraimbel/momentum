import SwiftUI
import SwiftData
import CoreLocation
import MapboxMaps
import UIKit

/// Plain values handed from SwiftData to the replay renderer. No model object crosses the
/// background-context hop, and no generated video or second copy of the route is persisted.
struct RouteReplayPayload: Sendable {
    let timeline: RouteReplayTimeline
    let title: String
    let type: WorkoutType
    let startedAt: Date
    let style: MapStyleOption
    /// Shared routes have already had their precise endpoints removed before upload. Local routes
    /// remain complete for the athlete's own replay and are clipped only when an export plan is
    /// created.
    let routeIsPrivacyTrimmed: Bool

    init(timeline: RouteReplayTimeline, title: String, type: WorkoutType,
         startedAt: Date, style: MapStyleOption,
         routeIsPrivacyTrimmed: Bool = false) {
        self.timeline = timeline
        self.title = title
        self.type = type
        self.startedAt = startedAt
        self.style = style
        self.routeIsPrivacyTrimmed = routeIsPrivacyTrimmed
    }

    /// Validate route data before it reaches the spline. Local map-matched JSON and remote post
    /// arrays can both outlive schema/code changes; a malformed value must degrade to
    /// "Replay unavailable", never poison the smoothing math or Mapbox camera.
    static func sanitizedCoordinates(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        coordinates.filter {
            $0.latitude.isFinite && $0.longitude.isFinite
                && (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude)
        }
    }

    static func canReplaySharedPost(_ item: FeedItem) -> Bool {
        let points = sharedCoordinates(item)
        guard points.count > 1 else { return false }
        return zip(points, points.dropFirst()).contains { pair in
            GeoPoint(lat: pair.0.latitude, lon: pair.0.longitude)
                .distance(to: GeoPoint(lat: pair.1.latitude, lon: pair.1.longitude)) > 0
        }
    }

    static func sharedPost(_ item: FeedItem) -> RouteReplayPayload? {
        // Synced routes are untrusted arrays. Do not use `FeedItem.routeCoordinates` here because
        // a malformed one-value row would be subscripted before the timeline can sanitize it.
        let coordinates = sharedCoordinates(item)
        guard coordinates.count > 1 else { return nil }
        let smoothed = RouteSmoothing.smooth(coordinates).map { GeoPoint(lat: $0.latitude, lon: $0.longitude) }
        let timeline = RouteReplayTimeline(
            geometry: smoothed,
            workoutDurationS: item.routeReplayDurationS,
            totalDistanceM: item.distanceKm * 1_000)
        guard timeline.isPlayable else { return nil }
        return .init(timeline: timeline, title: item.title, type: item.type,
                     startedAt: item.date, style: item.mapStyle,
                     routeIsPrivacyTrimmed: true)
    }

    private static func sharedCoordinates(_ item: FeedItem) -> [CLLocationCoordinate2D] {
        sanitizedCoordinates(item.routeLatLon?.compactMap { pair -> CLLocationCoordinate2D? in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
        } ?? [])
    }
}

/// Loads a finished local route away from the main actor. A long run can carry thousands of
/// `LocationSample` rows; faulting and Kalman-replaying those while the cover animates in would
/// hitch the exact premium moment this feature is supposed to create.
@MainActor
private enum RouteReplayLoader {
    static func load(_ workout: Workout) async -> RouteReplayPayload? {
        guard let gps = workout.gps, workout.type.isGPS else { return nil }
        let title = workout.title.isEmpty ? workout.type.title : workout.title
        let type = workout.type
        let startedAt = workout.startedAt
        let durationS = workout.durationS
        let distanceM = gps.distanceM
        let style = gps.mapStyle

        guard let container = gps.modelContext?.container else {
            return make(gps: gps, title: title, type: type, startedAt: startedAt,
                        durationS: durationS, distanceM: distanceM, style: style)
        }
        let id = gps.persistentModelID
        return await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            guard let detail = context.model(for: id) as? GPSDetail else { return nil }
            return make(gps: detail, title: title, type: type, startedAt: startedAt,
                        durationS: durationS, distanceM: distanceM, style: style)
        }.value
    }

    nonisolated private static func make(gps: GPSDetail, title: String, type: WorkoutType,
                                         startedAt: Date, durationS: Double, distanceM: Double,
                                         style: MapStyleOption) -> RouteReplayPayload? {
        let raw = RouteReplayPayload.sanitizedCoordinates(gps.routeCoordinates(type: type))
        let geometry = RouteSmoothing.smooth(raw).map { GeoPoint(lat: $0.latitude, lon: $0.longitude) }
        let timeline = RouteReplayTimeline(geometry: geometry,
                                           routePoints: gps.routePoints(type: type),
                                           workoutDurationS: durationS,
                                           totalDistanceM: distanceM)
        guard timeline.isPlayable else { return nil }
        return .init(timeline: timeline, title: title, type: type,
                     startedAt: startedAt, style: style)
    }
}

/// Full-screen local-workout entry. The cover appears immediately, then the route resolves into it
/// without blocking the calling save/detail/profile surface.
struct WorkoutRouteReplayView: View {
    let workout: Workout
    var distanceUnit: DistanceUnit = .auto

    @Environment(\.dismiss) private var dismiss
    @State private var payload: RouteReplayPayload?
    @State private var resolved = false

    var body: some View {
        Group {
            if let payload {
                RouteReplayExperience(payload: payload, distanceUnit: distanceUnit)
            } else if resolved {
                unavailable
            } else {
                loading
            }
        }
        .background(Theme.background)
        .task(id: workout.id) {
            payload = await RouteReplayLoader.load(workout)
            resolved = true
        }
    }

    private var loading: some View {
        RouteReplayPreparationShell(title: workout.title.isEmpty ? workout.type.title : workout.title,
                                    type: workout.type,
                                    onClose: { dismiss() })
    }

    private var unavailable: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Replay unavailable", systemImage: "map")
            } description: {
                Text("This activity doesn't have enough route data to replay.")
            } actions: {
                Button("Close") { dismiss() }.buttonStyle(.borderedProminent).tint(Theme.ink)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { closeButton }
            }
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.surface))
                .overlay(Circle().stroke(Theme.hairline))
        }
        .accessibilityLabel("Close route replay")
    }
}

/// Full-screen replay for an already-materialized shared post. Its route was privacy-trimmed before
/// publishing, so playback cannot reveal a home/start point that the static post did not contain.
struct SharedRouteReplayView: View {
    let payload: RouteReplayPayload
    var distanceUnit: DistanceUnit = .auto

    var body: some View {
        RouteReplayExperience(payload: payload, distanceUnit: distanceUnit)
    }
}

/// A local workout can need one background-context hop before its route exists as plain values.
/// Keep the eventual replay's visual grammar on screen during that hop instead of flashing a
/// blank page with a spinner in its center.
private struct RouteReplayPreparationShell: View {
    let title: String
    let type: WorkoutType
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            RouteReplayLoadingBackdrop(geometry: [], type: type)
            HStack(spacing: Theme.Space.sm) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Theme.surface.opacity(0.9)))
                        .overlay(Circle().stroke(Theme.hairline))
                }
                .accessibilityLabel("Close route replay")

                VStack(alignment: .leading, spacing: 2) {
                    Text("ROUTE REPLAY")
                        .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                        .foregroundStyle(Theme.inkSecondary)
                    Text(title)
                        .font(.rounded(Theme.FontSize.body, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                ProgressView().tint(Theme.purple)
                    .accessibilityLabel("Preparing route replay")
            }
            .padding(8)
            .padding(.trailing, Theme.Space.sm)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Theme.hairline)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.top, Theme.Space.sm)
        }
        .background(Theme.background)
        .accessibilityIdentifier("routeReplayPreparationShell")
    }
}

/// The replay's guaranteed first frame. It uses only the already-prepared route geometry, so it
/// paints synchronously while Mapbox loads its style/terrain underneath. The real map crossfades
/// over this exact trace; the athlete never sees an empty white or charcoal page.
private struct RouteReplayLoadingBackdrop: View {
    let geometry: [GeoPoint]
    let type: WorkoutType

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.surface
                LinearGradient(colors: [Theme.proLavender.opacity(0.14),
                                        Theme.background.opacity(0.22),
                                        Theme.surface],
                               startPoint: .topLeading, endPoint: .bottomTrailing)

                Canvas { context, size in
                    let drawingHeight = max(260, size.height * 0.72)
                    let path = routePath(in: CGSize(width: size.width, height: drawingHeight))
                    context.stroke(path, with: .color(.white.opacity(0.72)),
                                   style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    context.stroke(path, with: .color(Theme.route.opacity(0.78)),
                                   style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                .accessibilityHidden(true)

                LinearGradient(colors: [.clear, Theme.background.opacity(0.5)],
                               startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preparing \(type.title.lowercased()) route map")
        .accessibilityIdentifier("routeReplayLoadingBackdrop")
    }

    private func routePath(in size: CGSize) -> Path {
        let points = geometry.count > 1
            ? RouteReplayProjection.fitted(geometry, in: size, inset: 54)
            : []
        var path = Path()
        if let first = points.first {
            path.move(to: first.cgPoint)
            for point in points.dropFirst() { path.addLine(to: point.cgPoint) }
        } else {
            // A quiet, route-like fallback for the local loader before its SwiftData hop returns.
            path.move(to: CGPoint(x: size.width * 0.14, y: size.height * 0.26))
            path.addCurve(to: CGPoint(x: size.width * 0.48, y: size.height * 0.50),
                          control1: CGPoint(x: size.width * 0.32, y: size.height * 0.18),
                          control2: CGPoint(x: size.width * 0.25, y: size.height * 0.58))
            path.addCurve(to: CGPoint(x: size.width * 0.82, y: size.height * 0.34),
                          control1: CGPoint(x: size.width * 0.68, y: size.height * 0.40),
                          control2: CGPoint(x: size.width * 0.66, y: size.height * 0.20))
        }
        return path
    }
}

// MARK: - Player

@MainActor @Observable
private final class RouteReplayPlayer {
    var progress = 0.0
    var isPlaying = false
    var rate = 1.0
    /// Camera mode belongs to the playback state machine. Keeping it here makes the finish frame
    /// atomic: the timeline cannot report 100% while the controls still claim to be following.
    var followsAthlete = true

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var baseDurationS = 12.0
    @ObservationIgnored private var resumeAfterScrub = false

    deinit { loop?.cancel() }

    func configure(durationS: Double, autoplay: Bool) {
        baseDurationS = max(1, durationS)
        progress = 0
        followsAthlete = true
        if autoplay { play() }
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        if progress >= 0.999 {
            progress = 0
            followsAthlete = true
        }
        guard !isPlaying else { return }
        isPlaying = true
        loop?.cancel()
        loop = Task { [weak self] in
            let clock = ContinuousClock()
            var previous = clock.now
            while let self, !Task.isCancelled, self.isPlaying {
                do { try await clock.sleep(for: .milliseconds(33)) } catch { return }
                let now = clock.now
                let elapsed = previous.duration(to: now).seconds
                previous = now
                self.progress = min(1, self.progress + elapsed * self.rate / self.baseDurationS)
                if self.progress >= 1 {
                    self.isPlaying = false
                    self.followsAthlete = false
                    self.loop = nil
                    return
                }
            }
        }
    }

    func pause() {
        isPlaying = false
        loop?.cancel()
        loop = nil
    }

    func restart(autoplay: Bool = true) {
        pause()
        progress = 0
        followsAthlete = true
        if autoplay { play() }
    }

    func scrub(_ active: Bool) {
        if active {
            resumeAfterScrub = isPlaying
            pause()
        } else if resumeAfterScrub {
            resumeAfterScrub = false
            play()
        }
    }

    func cycleRate() { rate = rate == 1 ? 2 : 1 }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

private struct RouteReplayExperience: View {
    let payload: RouteReplayPayload
    var distanceUnit: DistanceUnit
    /// `RouteReplayMap` is rebuilt as the 30 Hz playback state changes. Bridge the immutable route
    /// to CoreLocation once at presentation time instead of remapping a long-run polyline every
    /// frame (a four-hour trace can contain tens of thousands of smoothed vertices).
    private let mapCoordinates: [CLLocationCoordinate2D]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(Services.self) private var services
    @State private var player = RouteReplayPlayer()
    /// One explicit camera source of truth for the Mapbox surface, visible label, and accessibility
    /// label. Deriving the control from both timeline progress and the player's async loop allowed
    /// a completed replay to show Overview while VoiceOver still announced "Show route overview".
    @State private var cameraFollowsAthlete = true
    @State private var cinematic3D = true
    @State private var celebratedFinish = false
    @State private var exportingVideo = false
    @State private var exportTask: Task<Void, Never>?
    @State private var exportedVideo: RouteReplayExportedVideo?
    @State private var exportURLToCleanup: URL?
    @State private var exportError: String?
    @State private var resumeAfterExport = false
    @State private var mapReady = false
    @State private var chromeVisible = false
    @State private var mapRevealTask: Task<Void, Never>?

    init(payload: RouteReplayPayload, distanceUnit: DistanceUnit) {
        self.payload = payload
        self.distanceUnit = distanceUnit
        self.mapCoordinates = payload.timeline.geometry.map(\.clCoordinate)
    }

    var body: some View {
        @Bindable var player = player
        GeometryReader { geo in
            ZStack {
                RouteReplayLoadingBackdrop(geometry: payload.timeline.geometry,
                                           type: payload.type)
                    .opacity(mapReady ? 0 : 1)

                RouteReplayMap(timeline: payload.timeline,
                               coordinates: mapCoordinates,
                               playbackProgress: player.progress,
                               style: payload.style,
                               followsAthlete: cameraFollowsAthlete && !reduceMotion,
                               cinematic3D: cinematic3D,
                               type: payload.type,
                               onReady: revealMap)
                    .ignoresSafeArea()
                    // A fully transparent UIViewRepresentable can be skipped by the compositor,
                    // starving Mapbox's first style frame. Keep it imperceptibly mounted behind
                    // the painted route preview, then crossfade only after `onStyleLoaded`.
                    .opacity(mapReady ? 1 : 0.001)
                    .allowsHitTesting(mapReady)

                VStack(spacing: 0) {
                    topBar
                        .opacity(chromeVisible ? 1 : 0)
                        .offset(y: chromeVisible ? 0 : -8)
                    Spacer(minLength: 0)
                    controls(bottomInset: geo.safeAreaInsets.bottom,
                             progress: $player.progress)
                        .opacity(chromeVisible ? 1 : 0)
                        .offset(y: chromeVisible ? 0 : 18)
                        .allowsHitTesting(mapReady)
                }

                if exportingVideo {
                    exportProgress
                }
            }
        }
        .background(Theme.background)
        .onAppear {
            player.configure(durationS: payload.timeline.playbackDurationS,
                             autoplay: false)
            cameraFollowsAthlete = !reduceMotion
            player.followsAthlete = cameraFollowsAthlete
            if reduceMotion {
                chromeVisible = true
            } else {
                withAnimation(.easeOut(duration: 0.24)) { chromeVisible = true }
            }
        }
        .onDisappear {
            player.pause()
            exportTask?.cancel()
            mapRevealTask?.cancel()
        }
        .onChange(of: player.progress) { old, new in
            // The map switches to its fitted overview at the same threshold. Publish the control
            // state in that exact transaction so visuals, text, and accessibility never disagree.
            if old < 0.997, new >= 0.997 {
                cameraFollowsAthlete = false
                player.followsAthlete = false
            }
            guard old < 1, new >= 1, !celebratedFinish else { return }
            celebratedFinish = true
            Haptics.success()
        }
        .onChange(of: reduceMotion) { _, enabled in
            if enabled {
                player.pause()
                cameraFollowsAthlete = false
                player.followsAthlete = false
            }
        }
        .sheet(item: $exportedVideo, onDismiss: finishSharing) { video in
            RouteReplayActivityView(items: [video.url])
                .presentationDetents([.large])
        }
        .alert("Replay video unavailable", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "Please try again.")
        }
    }

    private func revealMap() {
        guard !mapReady, mapRevealTask == nil else { return }
        mapRevealTask = Task { @MainActor in
            #if DEBUG
            // A deterministic window lets UI tests prove that the prepared route placeholder is
            // a real first frame—not a transient screenshot that only appears on a fast machine.
            if ProcessInfo.processInfo.arguments.contains("--route-replay-map-ready-delay") {
                try? await Task.sleep(for: .seconds(1.5))
            }
            #endif
            guard !Task.isCancelled else { return }
            if reduceMotion {
                mapReady = true
            } else {
                withAnimation(.easeOut(duration: 0.28)) { mapReady = true }
                try? await Task.sleep(for: .milliseconds(180))
            }
            guard !Task.isCancelled else { return }
            mapRevealTask = nil
            #if DEBUG
            let startsPaused = ProcessInfo.processInfo.arguments.contains("--route-replay-start-paused")
            #else
            let startsPaused = false
            #endif
            if !reduceMotion, !startsPaused { player.play() }
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: Theme.Space.sm) {
            replayIdentity
                .layoutPriority(1)
            Spacer(minLength: 0)
            cinematicButton
            shareVideoButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.md)
        // The VStack already begins below the safe area. Adding `safeAreaInsets.top` here placed
        // the replay identity almost a second status-bar below the Dynamic Island.
        .padding(.top, Theme.Space.sm)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routeReplayHeader")
    }

    private var replayIdentity: some View {
        HStack(alignment: .center, spacing: Theme.Space.sm) {
            Button { closeReplay() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.surface.opacity(0.88)))
                    .overlay(Circle().stroke(Theme.hairline))
            }
            .accessibilityLabel("Close route replay")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("ROUTE REPLAY")
                        .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                        .accessibilityIdentifier("routeReplayScreen")
                    Text("PRO")
                        .font(.rounded(9, weight: .bold)).tracking(0.8)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.proLavender.opacity(0.18)))
                }
                .foregroundStyle(Theme.inkSecondary)
                Text(payload.title)
                    .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            .frame(maxWidth: 150, alignment: .leading)
        }
        .padding(8)
        .padding(.trailing, Theme.Space.sm)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Theme.hairline)
        }
        .shadow(color: .black.opacity(0.08), radius: 14, y: 7)
    }

    private var cinematicButton: some View {
        Button {
            cinematic3D.toggle()
            Haptics.selection()
        } label: {
            VStack(spacing: 0) {
                Image(systemName: cinematic3D ? "cube.transparent.fill" : "square.2.layers.3d")
                    .font(.system(size: 15, weight: .bold))
                Text(cinematic3D ? "3D" : "2D")
                    .font(.rounded(8, weight: .bold)).tracking(0.5)
            }
            .foregroundStyle(cinematic3D ? Theme.purple : Theme.ink)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(Theme.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cinematic3D
                            ? "Use flat replay camera"
                            : "Use cinematic 3D replay camera")
        .accessibilityIdentifier("routeReplay3DButton")
    }

    private var shareVideoButton: some View {
        Button { exportReplayVideo() } label: {
            Group {
                if exportingVideo {
                    ProgressView().tint(Theme.ink).controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .foregroundStyle(Theme.ink)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(Theme.hairline))
        }
        .buttonStyle(.plain)
        .disabled(exportingVideo)
        .accessibilityLabel(exportingVideo ? "Creating private replay video" : "Share replay video")
        .accessibilityIdentifier("routeReplayShareButton")
    }

    private var exportProgress: some View {
        VStack(spacing: 7) {
            ProgressView().tint(Theme.purple)
            Text("CREATING REPLAY")
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                .foregroundStyle(Theme.ink)
            Label(payload.routeIsPrivacyTrimmed
                  ? "Using this post's privacy-safe route"
                  : "Start and finish are hidden",
                  systemImage: "lock.fill")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.hairline)
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("routeReplayExportProgress")
    }

    private func closeReplay() {
        // Stop the display-link-style playback loop before removing Mapbox from the
        // hierarchy. This also keeps dismissal deterministic for VoiceOver and UI tests.
        player.pause()
        player.followsAthlete = false
        exportTask?.cancel()
        exportTask = nil
        if let url = exportURLToCleanup { try? FileManager.default.removeItem(at: url) }
        exportURLToCleanup = nil
        dismiss()
    }

    private func exportReplayVideo() {
        guard !exportingVideo else { return }
        guard let plan = RouteReplayExportPlan.make(from: payload) else {
            exportError = "This route is too short to hide both endpoints safely, so Momentum won't create a shareable video from it."
            return
        }

        resumeAfterExport = player.isPlaying
        player.pause()
        exportingVideo = true
        exportTask = Task { @MainActor in
            #if DEBUG
            let fastExport = ProcessInfo.processInfo.arguments.contains("--route-replay-export-fast")
            // UI tests use a deterministic preparation window to exercise cancellation before
            // the activity sheet can race the close action. This path is compiled out of release
            // builds and remains cancellable, just like the real Mapbox snapshot request.
            if ProcessInfo.processInfo.arguments.contains("--route-replay-export-test-delay") {
                try? await Task.sleep(for: .seconds(2))
            }
            #else
            let fastExport = false
            #endif
            let backdrop = fastExport
                ? RouteReplayVideoBackdrop.fallback(for: plan,
                                                    size: RouteReplayBackdropSnapshotter.size)
                : await RouteReplayBackdropSnapshotter.snapshot(for: plan)
            guard !Task.isCancelled else {
                exportingVideo = false
                exportTask = nil
                return
            }

            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try await RouteReplayVideoExporter.export(
                        plan: plan,
                        backdrop: backdrop,
                        distanceUnit: distanceUnit,
                        canvas: fastExport ? CGSize(width: 180, height: 320)
                                           : RouteReplayVideoExporter.storySize,
                        routeDurationS: fastExport ? 0.25 : nil,
                        holdDurationS: fastExport ? 0.1 : 1)
                }.value
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url)
                    exportingVideo = false
                    exportTask = nil
                    return
                }
                exportURLToCleanup = url
                exportedVideo = RouteReplayExportedVideo(url: url)
                services.analytics.log(.shareCreated(style: "route-replay-private-video"))
                Haptics.success()
            } catch is CancellationError {
                // Dismissing replay during export is an intentional cancellation, not an error.
            } catch {
                exportError = error.localizedDescription
                if resumeAfterExport, player.progress < 1 { player.play() }
                resumeAfterExport = false
            }
            exportingVideo = false
            exportTask = nil
        }
    }

    private func finishSharing() {
        if let url = exportURLToCleanup { try? FileManager.default.removeItem(at: url) }
        exportURLToCleanup = nil
        exportedVideo = nil
        if resumeAfterExport, player.progress < 1 { player.play() }
        resumeAfterExport = false
    }

    private func controls(bottomInset: CGFloat, progress: Binding<Double>) -> some View {
        VStack(spacing: Theme.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                replayMetric(Formatters.duration(s: payload.timeline.elapsedTime(at: player.progress)), "TIME")
                Spacer()
                replayMetric(Formatters.distance(meters: payload.timeline.distance(at: player.progress),
                                                  unit: distanceUnit), "DISTANCE", trailing: true)
            }

            Slider(value: progress, in: 0...1, onEditingChanged: player.scrub)
                .tint(Theme.purple)
                .accessibilityLabel("Route replay position")
                .accessibilityValue("\(Int((player.progress * 100).rounded())) percent")

            if reduceMotion {
                Label("Drag the timeline to replay", systemImage: "hand.draw")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity)
            } else {
                HStack {
                    controlButton(label: "\(Int(player.rate))×", accessibility: "Playback speed") {
                        player.cycleRate(); Haptics.selection()
                    }
                    Spacer()
                    Button {
                        celebratedFinish = false
                        if player.progress >= 0.999 {
                            // A fresh replay starts as a replay, not as a static overview left over
                            // from the previous finish.
                            cameraFollowsAthlete = true
                            player.restart()
                        } else {
                            player.toggle()
                        }
                        Haptics.light()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : (player.progress >= 1 ? "arrow.counterclockwise" : "play.fill"))
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.background)
                            .frame(width: 58, height: 58)
                            .raised(Circle(), tone: .ink)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause route replay" : (player.progress >= 1 ? "Replay route" : "Play route replay"))
                    Spacer()
                    controlButton(label: cameraFollowsAthlete ? "Follow" : "Overview",
                                  systemImage: cameraFollowsAthlete ? "location.fill" : "map",
                                  accessibility: cameraFollowsAthlete ? "Show route overview" : "Follow athlete") {
                        cameraFollowsAthlete.toggle()
                        player.followsAthlete = cameraFollowsAthlete
                        Haptics.selection()
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.lg)
        .padding(.bottom, bottomInset + Theme.Space.md)
        .background(.ultraThinMaterial,
                    in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
        .overlay(alignment: .top) {
            Capsule().fill(Theme.hairline).frame(width: 36, height: 4).padding(.top, 8)
        }
    }

    private func replayMetric(_ value: String, _ label: String, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(value)
                .font(.display(25, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
            Text(label)
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.1)
                .foregroundStyle(Theme.inkTertiary)
        }
    }

    private func controlButton(label: String, systemImage: String? = nil,
                               accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .bold)) }
                Text(label).font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
            }
            .foregroundStyle(Theme.ink)
            .frame(minWidth: 72, minHeight: 40)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().stroke(Theme.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }
}

private struct RouteReplayExportedVideo: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet owns every destination (Messages, Instagram, TikTok, Save Video, Files)
/// and hands each app a real local `.mp4`, not a screen recording or a link that can expire.
private struct RouteReplayActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Mapbox renderer

/// Low-pass only the circular heading—not the athlete's coordinate—so switchbacks still follow the
/// recorded trace while GPS-sized bearing changes cannot make a 58° camera twitch frame-to-frame.
@MainActor
private final class RouteReplayCameraMemory {
    private var bearing: Double?

    func reset() { bearing = nil }

    func smoothedBearing(toward target: Double) -> Double {
        guard target.isFinite else { return bearing ?? 0 }
        guard let current = bearing else {
            bearing = target
            return target
        }
        var delta = (target - current).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        let next = (current + delta * 0.16 + 360).truncatingRemainder(dividingBy: 360)
        bearing = next
        return next
    }
}

/// Mapbox paints the trim interval transparent by default. Keep the completed head in the layer's
/// normal color and trim only the future tail. This deliberately uses Mapbox's default trim color:
/// if a style does not support trimming, the safe fallback is a visible full route, never no route.
enum RouteReplayLineTrim {
    static func hiddenTail(afterVisibleProgress progress: Double) -> [Double] {
        [min(1, max(0, progress)), 1]
    }
}

private struct RouteReplayMap: View {
    let timeline: RouteReplayTimeline
    let coordinates: [CLLocationCoordinate2D]
    let playbackProgress: Double
    let style: MapStyleOption
    let followsAthlete: Bool
    let cinematic3D: Bool
    let type: WorkoutType
    let onReady: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var styleReady = false
    @State private var cameraMemory = RouteReplayCameraMemory()

    private var state: RouteReplayTimeline.State? { timeline.state(at: playbackProgress) }
    private var routeProgress: Double { state?.routeProgress ?? 0 }

    init(timeline: RouteReplayTimeline, coordinates: [CLLocationCoordinate2D],
         playbackProgress: Double, style: MapStyleOption,
         followsAthlete: Bool, cinematic3D: Bool, type: WorkoutType,
         onReady: @escaping () -> Void) {
        self.timeline = timeline
        self.coordinates = coordinates
        self.playbackProgress = playbackProgress
        self.style = style
        self.followsAthlete = followsAthlete
        self.cinematic3D = cinematic3D
        self.type = type
        self.onReady = onReady
    }

    var body: some View {
        MapReader { proxy in
            Map(initialViewport: Self.overview(coordinates)) {
                PolylineAnnotationGroup {
                    PolylineAnnotation(id: "route-replay-ghost", lineCoordinates: coordinates)
                        .lineColor(StyleColor(UIColor(Theme.route).withAlphaComponent(0.24)))
                        .lineBorderColor(StyleColor(UIColor.white.withAlphaComponent(0.52)))
                        .lineBorderWidth(1)
                        .lineWidth(4)
                }
                .lineCap(.round)
                .lineJoin(.round)
                .lineEmissiveStrength(1)
                .lineOcclusionOpacity(0.55)
                .slot(.top)

                PolylineAnnotationGroup {
                    PolylineAnnotation(id: "route-replay-progress", lineCoordinates: coordinates)
                        .lineColor(StyleColor(UIColor(Theme.route)))
                        .lineBorderColor(StyleColor(UIColor.white))
                        .lineBorderWidth(1)
                        .lineWidth(5)
                }
                .lineCap(.round)
                .lineJoin(.round)
                .lineEmissiveStrength(1)
                .lineOcclusionOpacity(1)
                .lineTrimOffset(start: RouteReplayLineTrim.hiddenTail(afterVisibleProgress: routeProgress)[0],
                                end: RouteReplayLineTrim.hiddenTail(afterVisibleProgress: routeProgress)[1])
                .slot(.top)

                if let start = coordinates.first {
                    MapViewAnnotation(coordinate: start) { RouteStartMark(diameter: 11) }
                        .allowOverlap(true)
                }
                if let finish = coordinates.last {
                    MapViewAnnotation(coordinate: finish) { RouteFinishMark(diameter: 11) }
                        .allowOverlap(true)
                }
                if let state {
                    MapViewAnnotation(coordinate: state.coordinate.clCoordinate) {
                        replayMarker
                    }
                    .allowOverlap(true).priority(10)
                }
            }
            .mapStyle(style.mapboxStyle(for: colorScheme))
            .ornamentOptions(MapChrome.minimal)
            .gestureOptions(Self.gestures)
            .onStyleLoaded { _ in
                MapChrome.hidePointsOfInterest(on: proxy.map)
                if cinematic3D { addCinematicTerrain(proxy.map) }
                else { proxy.map?.removeTerrain() }
                styleReady = true
                if followsAthlete, !reduceMotion {
                    updateFollowCamera(proxy.map)
                } else {
                    showOverview(proxy, animated: false)
                }
                onReady()
            }
            .onChange(of: routeProgress) { oldProgress, progress in
                if followsAthlete, progress < 0.997, !reduceMotion {
                    // Playback updates at ~30 Hz. Send those directly to Mapbox's native camera;
                    // storing each frame in SwiftUI Viewport state causes body churn and can race
                    // a simultaneous transition to `.overview`.
                    updateFollowCamera(proxy.map)
                } else if oldProgress < 0.997, progress >= 0.997 {
                    showOverview(proxy, animated: !reduceMotion)
                }
            }
            .onChange(of: followsAthlete) { _, following in
                guard styleReady else { return }
                // A mode switch owns the camera completely. Cancel any prior native transition
                // before starting the next one so fast repeated taps remain deterministic.
                proxy.camera?.cancelAnimations()
                if following, !reduceMotion {
                    cameraMemory.reset()
                    updateFollowCamera(proxy.map)
                } else {
                    showOverview(proxy, animated: !reduceMotion)
                }
            }
            .onChange(of: cinematic3D) { _, enabled in
                guard styleReady else { return }
                proxy.camera?.cancelAnimations()
                cameraMemory.reset()
                if enabled { addCinematicTerrain(proxy.map) }
                else { proxy.map?.removeTerrain() }
                if followsAthlete, !reduceMotion {
                    updateFollowCamera(proxy.map)
                } else {
                    showOverview(proxy, animated: !reduceMotion)
                }
            }
            .background(Theme.surface)
        }
    }

    private var replayMarker: some View {
        Image(systemName: type.isCycling ? "figure.outdoor.cycle" : "figure.run")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Theme.background)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Theme.ink))
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
            .accessibilityHidden(true)
    }

    private func updateFollowCamera(_ map: MapboxMap?) {
        guard styleReady, let state else { return }
        let bearing = cinematic3D ? cameraMemory.smoothedBearing(toward: state.bearing) : 0
        map?.setCamera(to: CameraOptions(center: state.coordinate.clCoordinate,
                                         padding: UIEdgeInsets(top: 80, left: 20,
                                                               bottom: 230, right: 20),
                                         zoom: cinematic3D
                                            ? (type.isCycling ? 14.5 : 15.25)
                                            : (type.isCycling ? 14.2 : 15.4),
                                         bearing: bearing,
                                         pitch: cinematic3D ? 58 : 0))
    }

    private func showOverview(_ proxy: MapProxy, animated: Bool) {
        guard styleReady, coordinates.count > 1, let map = proxy.map else { return }
        let camera = try? map.camera(
            for: coordinates,
            camera: CameraOptions(
                bearing: cinematic3D ? (timeline.state(at: 0.45)?.bearing ?? 0) : 0,
                pitch: cinematic3D ? 36 : 0),
            coordinatesPadding: UIEdgeInsets(top: 110, left: 42, bottom: 250, right: 42),
            maxZoom: 16.5,
            offset: nil)
        guard let camera else { return }
        if animated, let animator = proxy.camera {
            animator.ease(to: camera, duration: 0.65, curve: .easeOut)
        } else {
            map.setCamera(to: camera)
        }
    }

    /// Terrain is attached once per style load. Standard/Standard Satellite already have rich 3D
    /// data; the explicit DEM gives Light, Streets, Outdoors and Dark the same real elevation when
    /// the athlete asks for cinematic mode.
    private func addCinematicTerrain(_ map: MapboxMap?) {
        guard let map, map.isStyleLoaded else { return }
        let sourceID = "route-replay-terrain-dem"
        if !map.sourceExists(withId: sourceID) {
            var source = RasterDemSource(id: sourceID)
            source.url = "mapbox://mapbox.mapbox-terrain-dem-v1"
            source.tileSize = 514
            source.maxzoom = 14
            try? map.addSource(source)
        }
        try? map.setTerrain(Terrain(sourceId: sourceID).exaggeration(1.12))
    }

    private static var gestures: GestureOptions {
        var options = GestureOptions()
        options.panEnabled = true
        options.pinchEnabled = true
        options.pinchZoomEnabled = true
        options.pinchPanEnabled = true
        options.rotateEnabled = false
        options.pitchEnabled = false
        options.doubleTapToZoomInEnabled = true
        options.doubleTouchToZoomOutEnabled = true
        options.quickZoomEnabled = true
        return options
    }

    private static func overview(_ coordinates: [CLLocationCoordinate2D]) -> Viewport {
        guard coordinates.count > 1 else {
            return coordinates.first.map { .camera(center: $0, zoom: 14) } ?? .idle
        }
        return .overview(geometry: LineString(coordinates),
                         geometryPadding: EdgeInsets(top: 110, leading: 42, bottom: 250, trailing: 42),
                         maxZoom: 16.5)
    }
}

private extension FeedItem {
    var routeReplayDurationS: Double {
        guard let value = metrics.first(where: { $0.label == "Time" })?.value else { return 0 }
        let pieces = value.split(separator: ":").compactMap { Double($0) }
        guard pieces.count == 2 || pieces.count == 3 else { return 0 }
        return pieces.reversed().enumerated().reduce(0) { total, pair in
            total + pair.element * pow(60, Double(pair.offset))
        }
    }
}
