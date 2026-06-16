import Foundation
import SwiftData

/// One card in the community feed. A value type so the user's own public workouts and the
/// clearly-labeled "Momentum community" content render through the same card without inventing fake
/// SwiftData workouts (community items are never written to the user's history/analytics).
struct FeedItem: Identifiable, Sendable, Hashable {
    let id: UUID
    let authorName: String
    let authorHandle: String?
    let location: String?
    let isCommunity: Bool          // drives the "Momentum community" badge (honest labeling)
    let type: WorkoutType
    let date: Date
    let title: String
    let caption: String?
    let statLine: String
    let prBadge: String?
    /// Normalized 0…1 route path for the silhouette banner; nil → glyph banner (strength/timed/no route).
    let routeNorm: [CGPoint]?
    /// Seeded baseline respects (community sample engagement); the viewer's own reaction adds on top.
    var baseReactions: Int = 0
    /// A photo the athlete attached (Strava-style). nil → route silhouette / glyph media.
    var photoData: Data? = nil
}

/// Pure, testable feed assembly (docs/SOCIAL-LAYER.md). Merges the athlete's **shared** workouts with
/// the seeded community, newest first. Private workouts never appear; route geometry only when the
/// athlete opted route maps in.
enum FeedAssembler {
    static func feed(userWorkouts: [Workout], profile: UserProfile?,
                     community: [FeedItem], now: Date = Date()) -> [FeedItem] {
        let mine = userWorkouts
            .filter { SocialPrivacy.isShared($0) }
            .map { item(from: $0, profile: profile) }
        return (mine + community).sorted { $0.date > $1.date }
    }

    /// Map a shared `Workout` into a feed card from the owner's point of view.
    static func item(from w: Workout, profile: UserProfile?) -> FeedItem {
        let weightUnit = WeightUnit(rawValue: profile?.weightUnit ?? "kg") ?? .kg
        let distanceUnit = DistanceUnit(rawValue: profile?.distanceUnit ?? "auto") ?? .auto
        let showRoute = profile.map { SocialPrivacy.showsRoute(w, profile: $0) } ?? false
        let coords: [CGPoint]? = showRoute ? normalizedRoute(w) : nil
        return FeedItem(
            id: w.id,
            authorName: displayName(profile),
            authorHandle: profile.flatMap { $0.handle.isEmpty ? nil : $0.handle },
            location: profile.flatMap(SocialPrivacy.publicLocation),
            isCommunity: false,
            type: w.type,
            date: w.startedAt,
            title: w.title.isEmpty ? w.type.title : w.title,
            caption: w.note.isEmpty ? nil : w.note,
            statLine: statLine(w, weightUnit: weightUnit, distanceUnit: distanceUnit),
            prBadge: nil,
            routeNorm: coords,
            photoData: w.photoData)
    }

    static func displayName(_ profile: UserProfile?) -> String {
        let n = profile?.displayName.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? "You" : n
    }

    static func statLine(_ w: Workout, weightUnit: WeightUnit, distanceUnit: DistanceUnit) -> String {
        if w.type.isStrengthStyle, let s = w.strength {
            let vol = weightUnit == .lb ? s.totalVolumeKg * Formatters.lbPerKg : s.totalVolumeKg
            return "\(Int(vol)) \(weightUnit == .lb ? "lb" : "kg") · \(s.totalSets) sets · \(Formatters.duration(s: w.durationS))"
        } else if let gps = w.gps, gps.distanceM > 0 {
            return "\(Formatters.distance(meters: gps.distanceM, unit: distanceUnit)) · \(Formatters.duration(s: w.durationS))"
        }
        return Formatters.duration(s: w.durationS)
    }

    /// Project a workout's accepted GPS samples into a normalized 0…1 path (y-flipped for screen).
    static func normalizedRoute(_ w: Workout) -> [CGPoint]? {
        let pts = (w.gps?.samples ?? []).filter(\.accepted).sorted { $0.t < $1.t }
        guard pts.count > 1 else { return nil }
        let lats = pts.map(\.lat), lons = pts.map(\.lon)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return nil }
        let dLat = max(maxLat - minLat, 1e-6), dLon = max(maxLon - minLon, 1e-6)
        return pts.map { CGPoint(x: ($0.lon - minLon) / dLon, y: 1 - ($0.lat - minLat) / dLat) }
    }
}
