import SwiftUI

/// The immersive, full-screen way to relive your training — tap a tile on the profile grid and swipe
/// up/down through your workouts like a feed of your own runs and lifts (the "new way of logging"). Each
/// page is the full-bleed route / muscle map / photo with the session's hero stats laid over a soft
/// light scrim, plus Share and Close. Native iOS 18 vertical paging; user-driven, so it stays smooth
/// and Reduce-Motion-safe (no parallax; the muscle map already holds static under Reduce Motion).
///
/// Paging snaps perfectly because each page is sized to the **full** screen height (safe-area insets
/// included) — the same height the scroll viewport takes once it ignores the safe area. Sizing a page to
/// the inset-excluded height (the GeometryReader default) is what makes a paged feed drift a little more
/// off-centre with every swipe, so we deliberately add the insets back.
struct ImmersiveWorkoutPager: View {
    let workouts: [Workout]
    let startID: UUID
    var weightUnit: WeightUnit = .default()
    var distanceUnit: DistanceUnit = .auto
    /// Who these pages belong to — drawn over the media exactly the way the community pager draws
    /// everyone else's (owner call 2026-07-30). The grid tile stays chip-free (your own wall doesn't
    /// need to tell you whose it is); opening the content is where the identity belongs.
    var byline: WorkoutByline? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            // geo.size excludes the safe area; add the insets back so a page == the full-screen viewport.
            let fullHeight = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(workouts) { workout in
                            ImmersiveWorkoutPage(
                                workout: workout, weightUnit: weightUnit, distanceUnit: distanceUnit,
                                byline: byline, isFirst: workout.id == startID,
                                topInset: geo.safeAreaInsets.top, bottomInset: geo.safeAreaInsets.bottom,
                                onClose: { dismiss() })
                            .frame(width: geo.size.width, height: fullHeight)
                            .clipped()
                            .id(workout.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
                // Open on the tapped workout (`.scrollPosition`'s initial value isn't honored for a lazy
                // paging stack, so jump explicitly once the content exists).
                .onAppear {
                    // If the tapped workout vanished between tap and present (concurrent delete/
                    // sync), scrollTo would silently no-op and the pager would open on the newest
                    // workout instead — close rather than show the wrong one.
                    guard workouts.contains(where: { $0.id == startID }) else { dismiss(); return }
                    var tx = Transaction(); tx.disablesAnimations = true
                    withTransaction(tx) { proxy.scrollTo(startID, anchor: .top) }
                }
            }
        }
        .background(Theme.background)
    }
}

// MARK: - Whose content this is

/// The athlete's own byline for a full-bleed page: photo, name, Pro seal, "@handle · City". Built
/// once at presentation time from the live `UserProfile` (a value, so paging never faults the model),
/// and it reads the SAME public projection the community feed publishes — `SocialPrivacy` decides
/// whether a location may appear at all, so your own post can't show more than a follower sees.
struct WorkoutByline: Equatable {
    var name: String
    var handle: String?
    var location: String?
    var avatarData: Data?
    var isPro: Bool = false

    init(name: String, handle: String? = nil, location: String? = nil,
         avatarData: Data? = nil, isPro: Bool = false) {
        self.name = name
        self.handle = handle
        self.location = location
        self.avatarData = avatarData
        self.isPro = isPro
    }

    init(profile: UserProfile?, isPro: Bool = false) {
        self.init(name: FeedAssembler.displayName(profile),
                  handle: profile.flatMap { $0.handle.isEmpty ? nil : $0.handle },
                  location: profile.flatMap(SocialPrivacy.publicLocation),
                  avatarData: profile?.avatarData,
                  isPro: isPro)
    }

    /// "@handle · Austin, TX" — the community pager's second line, same order, same separator.
    /// Empty when the athlete has neither (a brand-new account shows just their name).
    var secondLine: String {
        var parts: [String] = []
        if let handle { parts.append("@\(handle)") }
        if let location, !location.isEmpty { parts.append(location) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - One page

private struct ImmersiveWorkoutPage: View {
    let workout: Workout
    var weightUnit: WeightUnit
    var distanceUnit: DistanceUnit
    var byline: WorkoutByline?
    var isFirst: Bool
    var topInset: CGFloat
    var bottomInset: CGFloat
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showHint = false
    /// Camera line to the route map (routes only): shows the re-center control once the athlete
    /// pinch-explores away from the fitted overview, and answers its tap.
    @State private var mapCamera = RouteMapCameraHandle()

    /// The cover rule applied to your own posts: the session's visual (live route map, muscle
    /// map) is page one and photos page behind it — flipped by "Photo as cover". In a paged
    /// context the route page drops its camera handle (a pannable map inside a horizontal pager
    /// fights the swipe); the single-media page keeps the fully explorable map exactly as before.
    private var mediaPages: [FullBleedPage] {
        let photos = workout.orderedPhotosData.map { FullBleedPage.photo($0) }
        guard !photos.isEmpty else { return [] }
        let primary = [FullBleedPage.primary(AnyView(
            WorkoutTileMedia(workout: workout, style: .immersive, distanceUnit: distanceUnit)
                .allowsHitTesting(false)))]
        return workout.coverIsPhoto ? photos + primary : primary + photos
    }

    var body: some View {
        ZStack {
            let pages = mediaPages
            if pages.count > 1 {
                // The counter pill sits BELOW the top-right share control's row.
                FullBleedMediaPager(pages: pages, pillTopPadding: topInset + 52)
            } else {
                WorkoutTileMedia(workout: workout, style: .immersive,
                                 distanceUnit: distanceUnit, mapCameraHandle: mapCamera)
            }

            // Soft light scrims keep ink controls legible over any media (photos, maps, muscle
            // art). Eased (SoftScrim), not two-stop — a linear fade "ends in a line" over dark
            // basemaps (owner report 2026-07-29, first seen on the community pager).
            VStack(spacing: 0) {
                SoftScrim.top(Theme.background)
                    .frame(height: topInset + 150)
                Spacer(minLength: 0)
                // As tall as the community pager's: this overlay now stacks byline + title + note +
                // stats, and at 300 a busy basemap's POI labels bled up through the byline.
                SoftScrim.bottom(Theme.background)
                    .frame(height: bottomInset + 430)
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if isFirst, showHint, !reduceMotion { swipeHint.transition(.opacity) }
                statsOverlay
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, topInset + Theme.Space.sm)
            .padding(.bottom, bottomInset + Theme.Space.lg)
        }
        .contentShape(Rectangle())
        .task {
            guard isFirst else { return }
            withAnimation(.easeIn(duration: 0.4).delay(0.5)) { showHint = true }
            try? await Task.sleep(for: .seconds(2.6))
            withAnimation(.easeOut(duration: 0.5)) { showHint = false }
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 36, height: 36).background(Circle().fill(Theme.surface)).overlay(Circle().stroke(Theme.hairline))
            }
            .accessibilityLabel("Close")
            Spacer()
            VStack(spacing: Theme.Space.sm) {
                ShareButton(workout: workout, weightUnit: weightUnit, distanceUnit: distanceUnit)
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                    .frame(width: 36, height: 36).background(Circle().fill(Theme.surface)).overlay(Circle().stroke(Theme.hairline))
                // Appears only once the athlete pinch-explores the route map; one tap re-frames
                // the whole route. Joins the trailing control column so the map stays uncluttered.
                if mapCamera.isExplored {
                    Button { mapCamera.recenter() } label: {
                        Image(systemName: "viewfinder").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 36, height: 36).background(Circle().fill(Theme.surface)).overlay(Circle().stroke(Theme.hairline))
                    }
                    .accessibilityLabel("Re-center route")
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .animation(.easeOut(duration: 0.25), value: mapCamera.isExplored)
        }
    }

    private var swipeHint: some View {
        VStack(spacing: 2) {
            Image(systemName: "chevron.compact.up").font(.system(size: 22, weight: .semibold))
            Text("Swipe").font(.rounded(Theme.FontSize.caption, weight: .semibold))
        }
        .foregroundStyle(Theme.inkSecondary)
        .padding(.bottom, Theme.Space.md)
    }

    /// The community pager's composition, on your own work: who → what → the note you wrote → the
    /// numbers. Without a byline (previews) the date carries the top line on its own.
    private var statsOverlay: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if let byline {
                bylineRow(byline)
            } else {
                Text(workout.startedAt.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            }
            Text(workout.title.isEmpty ? workout.type.title : workout.title)
                .font(.display(28, weight: .black)).foregroundStyle(Theme.ink).lineLimit(2)
            if !workout.note.isEmpty {
                Text(workout.note)
                    .font(.rounded(Theme.FontSize.body, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary).lineLimit(2)
            }
            StatGrid(cells: metricCells, valueSize: 24, leading: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Photo · name · Pro seal · date, then "@handle · City" — the community byline exactly, minus
    /// the tap: this profile is the one you came from, so it stays inert (the same rule
    /// `CommunityPager` applies to your own posts on the wall).
    private func bylineRow(_ author: WorkoutByline) -> some View {
        HStack(spacing: Theme.Space.sm) {
            AvatarView(photo: author.avatarData, name: author.name, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(author.name)
                        .font(.rounded(15, weight: .semibold)).foregroundStyle(Theme.ink)
                        .lineLimit(1).layoutPriority(1)
                    if author.isPro {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.purple)
                            .accessibilityLabel("Verified Pro")
                    }
                    // Full ink, never tertiary: this line sits over arbitrary media and tertiary
                    // gray vanished against a pale sky even under the scrim (community pager's
                    // lesson, 2026-07-30). Hierarchy comes from weight.
                    Text("· \(dateLabel)")
                        .font(.rounded(15, weight: .regular)).foregroundStyle(Theme.ink)
                        .lineLimit(1)
                }
                if !author.secondLine.isEmpty {
                    Text(author.secondLine)
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The byline's date. The community fills this slot with "3 minutes ago", but your own logbook
    /// wants the calendar date — "16 weeks ago" is useless when you're looking back at a build — and
    /// it picks up the year as soon as the session isn't from this one.
    private var dateLabel: String {
        let cal = Calendar.current
        let sameYear = cal.component(.year, from: workout.startedAt) == cal.component(.year, from: Date())
        return sameYear
            ? workout.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            : workout.startedAt.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private var metricCells: [StatGrid.Cell] {
        if workout.type.isStrengthStyle, let s = workout.strength {
            let vol = weightUnit == .lb ? s.totalVolumeKg * Formatters.lbPerKg : s.totalVolumeKg
            return [
                .init(value: "\(Formatters.compact(vol)) \(weightUnit == .lb ? "lb" : "kg")", label: "Volume"),
                .init(value: "\(s.totalSets)", label: "Sets"),
                .init(value: Formatters.duration(s: workout.durationS), label: "Time"),
            ]
        } else if workout.type.isGPS, let gps = workout.gps {
            var cells: [StatGrid.Cell] = [
                .init(value: Formatters.distance(meters: gps.distanceM, unit: distanceUnit), label: "Distance"),
                .init(value: Formatters.duration(s: workout.durationS), label: "Time"),
            ]
            if workout.type.isCycling {
                let speed = workout.durationS > 0 ? gps.distanceM / workout.durationS : 0
                cells.append(.init(value: Formatters.speed(ms: speed, unit: distanceUnit), label: "Speed"))
            } else {
                let pace = gps.distanceM > 0 ? workout.durationS / (gps.distanceM / 1000) : 0
                cells.append(.init(value: Formatters.pace(secPerKm: pace, unit: distanceUnit), label: "Pace"))
            }
            return cells
        } else {
            var cells: [StatGrid.Cell] = [.init(value: Formatters.duration(s: workout.durationS), label: "Time")]
            if let cal = workout.calories, cal > 0 {
                cells.append(.init(value: "\(Int(cal))", label: "Cal"))
            }
            if let rpe = workout.perceivedEffort {
                cells.append(.init(value: "\(rpe)", label: "Effort"))
            }
            return cells
        }
    }
}
