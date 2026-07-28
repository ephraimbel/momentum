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
                                isFirst: workout.id == startID,
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

// MARK: - One page

private struct ImmersiveWorkoutPage: View {
    let workout: Workout
    var weightUnit: WeightUnit
    var distanceUnit: DistanceUnit
    var isFirst: Bool
    var topInset: CGFloat
    var bottomInset: CGFloat
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showHint = false
    /// Camera line to the route map (routes only): shows the re-center control once the athlete
    /// pinch-explores away from the fitted overview, and answers its tap.
    @State private var mapCamera = RouteMapCameraHandle()

    var body: some View {
        ZStack {
            WorkoutTileMedia(workout: workout, style: .immersive,
                             distanceUnit: distanceUnit, mapCameraHandle: mapCamera)

            // Soft light scrims keep ink controls legible over any media (photos, maps, muscle art).
            VStack(spacing: 0) {
                LinearGradient(colors: [Theme.background.opacity(0.92), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: topInset + 120)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, Theme.background.opacity(0.94)], startPoint: .top, endPoint: .bottom)
                    .frame(height: bottomInset + 300)
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

    private var statsOverlay: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(workout.startedAt.formatted(.dateTime.weekday(.wide).month().day()))
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            Text(workout.title.isEmpty ? workout.type.title : workout.title)
                .font(.display(28, weight: .black)).foregroundStyle(Theme.ink).lineLimit(2)
            StatGrid(cells: metricCells, valueSize: 24, leading: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
