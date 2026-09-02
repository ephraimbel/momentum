import SwiftUI

private struct WorkoutReplaySelection: Identifiable {
    let id: UUID
}

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
    @State private var replaySelection: WorkoutReplaySelection?
    /// A cover swap is browsing state, not an edit to the athlete's saved cover preference. Keep
    /// it at the pager root so a vertical swipe that recycles a lazy page does not forget which
    /// side the viewer brought forward. The saved `coverIsPhoto` remains the initial value.
    @State private var photoHeroOverrides: [UUID: Bool] = [:]
    @State private var photoPageByWorkout: [UUID: Int] = [:]
    /// Only the snapped page owns a live Mapbox canvas. LazyVStack keeps neighbors alive; letting
    /// every route page run a map wastes GPU memory and can unload the app after rapid relaunches.
    @State private var visibleWorkoutID: UUID?

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
                                isActive: (visibleWorkoutID ?? startID) == workout.id,
                                topInset: geo.safeAreaInsets.top, bottomInset: geo.safeAreaInsets.bottom,
                                photoHeroRequested: photoHeroBinding(for: workout),
                                photoPage: photoPageBinding(for: workout.id),
                                onClose: { dismiss() },
                                onOpenReplay: { replaySelection = .init(id: workout.id) })
                            .frame(width: geo.size.width, height: fullHeight)
                            .clipped()
                            .id(workout.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $visibleWorkoutID)
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
                // Open on the tapped workout (`.scrollPosition`'s initial value isn't honored for a lazy
                // paging stack, so jump explicitly once the content exists).
                .onAppear {
                    // If the tapped workout vanished between tap and present (concurrent delete/
                    // sync), scrollTo would silently no-op and the pager would open on the newest
                    // workout instead — close rather than show the wrong one.
                    guard workouts.contains(where: { $0.id == startID }) else { dismiss(); return }
                    visibleWorkoutID = startID
                    var tx = Transaction(); tx.disablesAnimations = true
                    withTransaction(tx) { proxy.scrollTo(startID, anchor: .top) }
                }
            }
        }
        .background(Theme.background)
        .fullScreenCover(item: $replaySelection) { selection in
            if let workout = workouts.first(where: { $0.id == selection.id }) {
                WorkoutRouteReplayView(workout: workout, distanceUnit: distanceUnit)
            }
        }
        // This pager is itself a full-screen cover. A locked replay tap needs a presentation host
        // in this live context or the paywall would wait behind the pager until it closes.
        .nestedPaywallHost()
    }

    private func photoHeroBinding(for workout: Workout) -> Binding<Bool> {
        Binding(
            get: {
                guard !workout.orderedPhotosData.isEmpty else { return false }
                return photoHeroOverrides[workout.id] ?? workout.coverIsPhoto
            },
            set: { photoHeroOverrides[workout.id] = $0 })
    }

    private func photoPageBinding(for id: UUID) -> Binding<Int> {
        Binding(get: { photoPageByWorkout[id] ?? 0 },
                set: { photoPageByWorkout[id] = max(0, $0) })
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
    var isActive: Bool
    var topInset: CGFloat
    var bottomInset: CGFloat
    @Binding var photoHeroRequested: Bool
    @Binding var photoPage: Int
    var onClose: () -> Void
    var onOpenReplay: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PaywallController.self) private var paywall
    @State private var showHint = false
    /// The full editor, the same one the history detail opens.
    @State private var editing = false
    /// Camera line to the route map (routes only): shows the re-center control once the athlete
    /// pinch-explores away from the fitted overview, and answers its tap.
    @State private var mapCamera = RouteMapCameraHandle()
    /// Measured height of the top-right control column, so the media counter pill can sit BELOW
    /// it whatever it holds. It used to be a hard-coded 52 — one 36pt share button plus a gap —
    /// and when Edit joined the column (2026-08-22) the pencil landed squarely on the "1/3" pill
    /// on every multi-photo post. The default is the two-button column (36 + 8 + 36) so the very
    /// first frame is already right; the re-center control growing the column moves the pill down.
    @State private var controlColumnHeight: CGFloat = 80
    /// The saved cover choice establishes the first frame; tapping the small alternate swaps the
    /// two surfaces in place without mutating that saved choice. Photos remain a horizontal set.
    private var photos: [Data] { workout.orderedPhotosData }
    private var photosAreHero: Bool { !photos.isEmpty && photoHeroRequested }

    /// The session's own visual in either slot. Hit-testing is off inside the thumbnail: a
    /// pannable map in a 62pt card would just fight the finger.
    /// `.tile` in the thumbnail, `.immersive` full screen. The immersive style is composed for a
    /// full page — inside a 62pt card it rendered as an empty wash. `.tile` is the style the grid
    /// already uses at this size, so the thumbnail is literally the tile the athlete knows.
    private func ownVisual(interactive: Bool) -> some View {
        let live = interactive && isActive
        return WorkoutTileMedia(workout: workout, style: live ? .immersive : .tile,
                         respectsPhotoCover: false,
                         distanceUnit: distanceUnit,
                         mapCameraHandle: live ? mapCamera : nil)
    }

    var body: some View {
        ZStack {
            heroMedia

            // Soft light scrims keep ink controls legible over any media (photos, maps, muscle
            // art). Eased (SoftScrim), not two-stop — a linear fade "ends in a line" over dark
            // basemaps (owner report 2026-07-29, first seen on the community pager).
            // ONE soft scrim, bottom only — the same rule the community pager has had since
            // 2026-08-20 ("scrap the fade from the top"), which this pager never adopted. A photo
            // opened from the profile grid was hazed at BOTH ends, and the bottom fade ran
            // `bottomInset + 430` — well over half the screen on a 6.1". The athlete's photograph
            // is the point; it runs clean to the top edge now (owner report 2026-08-29).
            GeometryReader { geo in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    SoftScrim.bottom(Theme.background)
                        .frame(height: geo.size.height * 0.35)
                }
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if isFirst, showHint, !reduceMotion { swipeHint.transition(.opacity) }
                statsOverlay
                    // Match the Community pager's dense-overlay contract. The full activity stays
                    // readable and VoiceOver-complete without allowing scaled display text to
                    // expand the hero wider than the device.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, topInset + Theme.Space.sm)
            .padding(.bottom, bottomInset + Theme.Space.lg)
        }
        .contentShape(Rectangle())
        .sheet(isPresented: $editing) { editSheet }
        .onChange(of: workout.coverIsPhoto) { _, newValue in
            guard !photos.isEmpty else { photoHeroRequested = false; return }
            swapHero(toPhotos: newValue, haptic: false)
        }
        .onChange(of: photos.count) { _, count in
            if count == 0 { photoHeroRequested = false; photoPage = 0 }
            else if photoPage >= count { photoPage = 0 }
        }
        .task {
            guard isFirst else { return }
            withAnimation(.easeIn(duration: 0.4).delay(0.5)) { showHint = true }
            try? await Task.sleep(for: .seconds(2.6))
            withAnimation(.easeOut(duration: 0.5)) { showHint = false }
        }
    }

    @ViewBuilder
    private var heroMedia: some View {
        if photosAreHero {
            photoHero
                .transition(.opacity.combined(with: .scale(scale: 0.992)))
                .accessibilityIdentifier("workout-photos-hero")
        } else {
            ownVisual(interactive: true)
                // A live Mapbox view cannot safely participate in matched geometry: SwiftUI
                // reparents its platform view mid-flight, which can blank the map and corrupt
                // the full-page frame. A tiny transform + crossfade keeps the exchange smooth
                // while the map remains in its real hero container.
                .transition(.opacity.combined(with: .scale(scale: 0.992)))
                .accessibilityIdentifier("workout-visual-hero")
        }
    }

    @ViewBuilder
    private var photoHero: some View {
        if photos.count > 1 {
            // The counter pill sits BELOW the whole top-right control column (measured), with
            // the same gap the column's buttons keep between themselves.
            FullBleedMediaPager(
                pages: photos.map { .photo($0) }, page: $photoPage,
                pillTopPadding: topInset + Theme.Space.sm + controlColumnHeight + Theme.Space.sm)
                .animation(.easeOut(duration: 0.25), value: controlColumnHeight)
        } else if let only = photos.first {
            PagedPhoto(data: only).ignoresSafeArea()
        }
    }

    private func swapHero(toPhotos: Bool, haptic: Bool = true) {
        guard !toPhotos || !photos.isEmpty else { return }
        if haptic { Haptics.selection() }
        withAnimation(reduceMotion ? .easeOut(duration: 0.16)
                                   : .spring(response: 0.42, dampingFraction: 0.88)) {
            photoHeroRequested = toPhotos
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
                // Route controls belong to the route canvas. When photos are the hero, the route
                // is one tap away in the alternate rectangle and these controls stay out of the
                // photograph's chrome.
                if !photosAreHero, workout.type.isGPS, (workout.gps?.distanceM ?? 0) > 0 {
                    let locked = !paywall.isEntitled(to: .routeReplay)
                    Button {
                        if locked { paywall.present(for: .routeReplay) }
                        else { onOpenReplay(); Haptics.light() }
                    } label: {
                        Image(systemName: locked ? "lock.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 36, height: 36).background(Circle().fill(Theme.surface))
                            .overlay(Circle().stroke(locked ? Theme.proLavender.opacity(0.55) : Theme.hairline))
                    }
                    .accessibilityIdentifier("routeReplayButton")
                    .accessibilityLabel(locked ? "Replay route, Pro" : "Replay route")
                    .accessibilityHint(locked ? "Opens the Pro offer" : "Animates this recorded route")
                }
                // Edit lives here because this pager is the athlete's OWN media — its single call
                // site is their profile grid (other people's posts open in `CommunityPager`), so
                // there is no "is this mine" question to ask. This is where people actually look
                // back at what they posted, so it is where "change the name / add the photo /
                // narrow the audience" has to be reachable.
                Button { editing = true } label: {
                    Image(systemName: "pencil").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 36, height: 36).background(Circle().fill(Theme.surface)).overlay(Circle().stroke(Theme.hairline))
                }
                .accessibilityLabel("Edit activity")
                // Appears only once the athlete pinch-explores the route map; one tap re-frames
                // the whole route. Joins the trailing control column so the map stays uncluttered.
                if !photosAreHero, mapCamera.isExplored {
                    Button { mapCamera.recenter() } label: {
                        Image(systemName: "viewfinder").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 36, height: 36).background(Circle().fill(Theme.surface)).overlay(Circle().stroke(Theme.hairline))
                    }
                    .accessibilityLabel("Re-center route")
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .animation(.easeOut(duration: 0.25), value: mapCamera.isExplored)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlColumnHeight = $0 }
        }
    }

    private var editSheet: some View { ActivityEditView(workout: workout) }

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
            // One alternate-media door, never an extra page: whichever surface is not the hero
            // sits here and trades places with it on tap. With no photos there is nothing to swap,
            // so the rectangle is absent.
            if !photos.isEmpty {
                if photosAreHero {
                    PostMediaThumb(label: workout.type.isStrengthStyle ? "Strength session visual" : "Route map") {
                        ownVisual(interactive: false)
                    } onTap: { swapHero(toPhotos: false) }
                } else if let photo = selectedPhoto {
                    PostMediaThumb(label: photos.count == 1 ? "Workout photo" : "Workout photos") {
                        PagedPhoto(data: photo)
                    } onTap: { swapHero(toPhotos: true) }
                }
            }
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

    private var selectedPhoto: Data? {
        photos.indices.contains(photoPage) ? photos[photoPage] : photos.first
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
