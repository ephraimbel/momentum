import SwiftUI
import CoreLocation

// Share styles (PRD §4.9/§25 "multiple swipeable style templates") — the Strava-class share
// moment, in momentum's voice. What Strava taught us: the athlete's own photo is the hero,
// stats are quiet white type floating over it, the route is a brand-colored line that could
// only be theirs, and the wordmark whispers. What stays ours: monochrome discipline, Space
// Grotesk numerals, iridescence as the single earned accent — and one style nobody else has,
// the light "Paper" editorial card.

/// The template picker's vocabulary. `classic` is the free tier; the rest ride the existing
/// `Feature.allShareTemplates` gate ("every share style").
enum ShareStyle: String, CaseIterable, Identifiable {
    case classic = "Classic"       // the original black card — free
    case photoTrio = "Photo"       // full-bleed photo, stat trio low, route floating high
    case photoStack = "Stacked"    // full-bleed photo, stats stacked down the center
    case paper = "Paper"           // the light editorial card — white canvas, ink type
    case sticker = "Sticker"       // transparent — stats + route only, lays over any story

    var id: String { rawValue }
    var requiresPro: Bool { self != .classic }
    /// Styles that carry the athlete's photo.
    var usesPhoto: Bool { self == .photoTrio || self == .photoStack }
}

// MARK: - Shared stat vocabulary

/// The three numbers a card leads with, derived once per workout (label, value).
struct ShareStats {
    let rows: [(label: String, value: String)]

    init(workout: Workout, weightUnit: WeightUnit, distanceUnit: DistanceUnit) {
        let time = Formatters.duration(s: workout.durationS)
        if workout.type.isStrengthStyle, let s = workout.strength {
            let volume = weightUnit == .lb ? s.totalVolumeKg * Formatters.lbPerKg : s.totalVolumeKg
            rows = [("Volume", "\(Formatters.compact(volume)) \(weightUnit == .lb ? "lb" : "kg")"),
                    ("Sets", "\(s.totalSets)"),
                    ("Time", time)]
        } else if let gps = workout.gps, gps.distanceM > 0 {
            if workout.type.discipline == .cycling {
                let speed = workout.durationS > 0 ? gps.distanceM / workout.durationS : 0
                rows = [("Distance", Formatters.distance(meters: gps.distanceM, unit: distanceUnit)),
                        ("Speed", Formatters.speed(ms: speed, unit: distanceUnit)),
                        ("Time", time)]
            } else {
                let pace = workout.durationS / (gps.distanceM / 1000)
                rows = [("Distance", Formatters.distance(meters: gps.distanceM, unit: distanceUnit)),
                        ("Pace", Formatters.pace(secPerKm: pace, unit: distanceUnit)),
                        ("Time", time)]
            }
        } else {
            rows = [("Time", time), ("Activity", workout.type.title)]
        }
    }
}

/// The route as the brand line: soft white casing under an iridescent core — legible on any
/// photo, unmistakably momentum (the same treatment as the live watch map).
private struct ShareRoute: View {
    let coords: [CLLocationCoordinate2D]
    let lineWidth: CGFloat
    var ink: Bool = false   // Paper wants the periwinkle route color, not white casing

    var body: some View {
        ZStack {
            if !ink {
                RouteSilhouette(coords: coords)
                    .stroke(.white.opacity(0.92),
                            style: StrokeStyle(lineWidth: lineWidth * 1.9, lineCap: .round, lineJoin: .round))
            }
            RouteSilhouette(coords: coords)
                .stroke(ink ? AnyShapeStyle(Theme.route)
                            : AnyShapeStyle(LinearGradient(colors: Theme.iridescent,
                                                           startPoint: .topLeading, endPoint: .bottomTrailing)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Photo · Trio  (photo hero, stat trio low, route floating high)

struct PhotoTrioCard: View {
    let workout: Workout
    let stats: ShareStats
    let photo: UIImage?
    let size: CGSize

    var body: some View {
        ZStack {
            ShareBackdrop(photo: photo, size: size)
            // Legibility scrim — only where the type lives.
            LinearGradient(stops: [.init(color: .clear, location: 0.45),
                                   .init(color: .black.opacity(0.55), location: 1)],
                           startPoint: .top, endPoint: .bottom)

            VStack(spacing: 0) {
                if let coords = routeCoords {
                    ShareRoute(coords: coords, lineWidth: size.width * 0.011)
                        .frame(height: size.height * 0.30)
                        .padding(.horizontal, size.width * 0.16)
                        .padding(.top, size.height * 0.12)
                }
                Spacer(minLength: 0)
                VStack(spacing: size.height * 0.016) {
                    Text("momentum")
                        .font(.display(size.width * 0.055, weight: .bold))
                        .foregroundStyle(.white)
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(stats.rows.indices, id: \.self) { i in
                            statCell(stats.rows[i], compact: true)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, size.width * 0.06)
                }
                .padding(.bottom, size.height * 0.10)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var routeCoords: [CLLocationCoordinate2D]? {
        guard let gps = workout.gps else { return nil }
        let coords = gps.routeCoordinates(type: workout.type)
        return coords.count > 1 ? coords : nil
    }

    private func statCell(_ row: (label: String, value: String), compact: Bool) -> some View {
        VStack(spacing: size.height * 0.004) {
            Text(row.label.uppercased())
                .font(.rounded(size.width * 0.028, weight: .semibold)).tracking(2)
                .foregroundStyle(.white.opacity(0.75))
            Text(row.value)
                .font(.display(size.width * 0.052, weight: .bold)).monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .shadow(color: .black.opacity(0.35), radius: size.width * 0.008, y: 1)
    }
}

// MARK: - Photo · Stacked  (stats down the center, small route beneath)

struct PhotoStackCard: View {
    let workout: Workout
    let stats: ShareStats
    let photo: UIImage?
    let size: CGSize

    var body: some View {
        ZStack {
            ShareBackdrop(photo: photo, size: size)
            Color.black.opacity(0.28)   // quiet full veil so center type always reads

            VStack(spacing: size.height * 0.030) {
                Spacer(minLength: 0)
                ForEach(stats.rows.indices, id: \.self) { i in
                    VStack(spacing: size.height * 0.004) {
                        Text(stats.rows[i].label.uppercased())
                            .font(.rounded(size.width * 0.030, weight: .semibold)).tracking(2)
                            .foregroundStyle(.white.opacity(0.8))
                        Text(stats.rows[i].value)
                            .font(.display(size.width * 0.085, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
                if let gps = workout.gps {
                    let coords = gps.routeCoordinates(type: workout.type)
                    if coords.count > 1 {
                        ShareRoute(coords: coords, lineWidth: size.width * 0.009)
                            .frame(height: size.height * 0.14)
                            .frame(width: size.width * 0.36)
                            .padding(.top, size.height * 0.015)
                    }
                }
                Text("momentum")
                    .font(.display(size.width * 0.045, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.top, size.height * 0.01)
                Spacer(minLength: 0)
            }
            .shadow(color: .black.opacity(0.3), radius: size.width * 0.008, y: 1)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Full-bleed photo, or a quiet brand canvas when there's no photo yet.
private struct ShareBackdrop: View {
    let photo: UIImage?
    let size: CGSize

    var body: some View {
        if let photo {
            Image(uiImage: photo)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            ZStack {
                Color.black
                IridescentView(intensity: 0.35, isStatic: true)
            }
        }
    }
}

// MARK: - Paper  (the momentum-only card: light editorial, ink on white)

struct PaperCard: View {
    let workout: Workout
    let stats: ShareStats
    let size: CGSize

    private var pad: CGFloat { size.width * 0.09 }

    var body: some View {
        ZStack {
            Color.white
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(workout.type.title.uppercased())
                        .tracking(3)
                    Spacer()
                    Text(workout.startedAt.formatted(date: .abbreviated, time: .omitted).uppercased())
                        .tracking(1.5)
                }
                .font(.rounded(size.width * 0.028, weight: .semibold))
                .foregroundStyle(.black.opacity(0.45))

                Spacer(minLength: 0)

                if let gps = workout.gps {
                    let coords = gps.routeCoordinates(type: workout.type)
                    if coords.count > 1 {
                        ShareRoute(coords: coords, lineWidth: size.width * 0.012, ink: true)
                            .frame(height: size.height * 0.30)
                            .frame(maxWidth: .infinity)
                        Spacer(minLength: 0)
                    }
                }

                VStack(alignment: .leading, spacing: size.height * 0.018) {
                    ForEach(stats.rows.indices, id: \.self) { i in
                        HStack(alignment: .firstTextBaseline) {
                            Text(stats.rows[i].label.uppercased())
                                .font(.rounded(size.width * 0.030, weight: .semibold)).tracking(2)
                                .foregroundStyle(.black.opacity(0.4))
                            Spacer()
                            Text(stats.rows[i].value)
                                .font(.display(size.width * 0.070, weight: .bold)).monospacedDigit()
                                .foregroundStyle(.black)
                                .lineLimit(1).minimumScaleFactor(0.6)
                        }
                        if i < stats.rows.count - 1 {
                            Rectangle().fill(.black.opacity(0.08)).frame(height: 1)
                        }
                    }
                }

                // The one earned accent on the page.
                IridescentView(intensity: 0.9, isStatic: true)
                    .frame(width: size.width * 0.30, height: size.height * 0.008)
                    .clipShape(Capsule())
                    .padding(.top, size.height * 0.035)

                Spacer(minLength: 0)
                Text("momentum")
                    .font(.display(size.width * 0.05, weight: .bold))
                    .foregroundStyle(.black)
            }
            .padding(pad)
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Sticker  (transparent — lays over any Instagram story)

struct StickerCard: View {
    let workout: Workout
    let stats: ShareStats
    let size: CGSize

    var body: some View {
        VStack(spacing: size.height * 0.030) {
            Spacer(minLength: 0)
            if let gps = workout.gps {
                let coords = gps.routeCoordinates(type: workout.type)
                if coords.count > 1 {
                    ShareRoute(coords: coords, lineWidth: size.width * 0.013)
                        .frame(height: size.height * 0.30)
                        .padding(.horizontal, size.width * 0.14)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(stats.rows.indices, id: \.self) { i in
                    VStack(spacing: size.height * 0.005) {
                        Text(stats.rows[i].label.uppercased())
                            .font(.rounded(size.width * 0.030, weight: .semibold)).tracking(2)
                            .foregroundStyle(.white.opacity(0.85))
                        Text(stats.rows[i].value)
                            .font(.display(size.width * 0.055, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, size.width * 0.05)
            Text("momentum")
                .font(.display(size.width * 0.045, weight: .bold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .shadow(color: .black.opacity(0.45), radius: size.width * 0.008, y: 1)
        .frame(width: size.width, height: size.height)
    }
}
