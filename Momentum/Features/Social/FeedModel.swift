import Foundation
import SwiftData
import CoreLocation

/// One card in the community feed. A value type so the user's own public workouts and the
/// clearly-labeled "Momentum community" content render through the same card without inventing fake
/// SwiftData workouts (community items are never written to the user's history/analytics).
struct FeedItem: Identifiable, Sendable, Hashable {
    let id: UUID
    let authorName: String
    let authorHandle: String?
    /// What the byline prints — the author's own home town ("Buda, TX").
    let location: String?
    /// The metro that town belongs to ("Austin, TX"), for anything that needs to know WHERE rather
    /// than what is written: the hemisphere a January run is in, and the bundled loop pool. Since
    /// the community moved off downtown pins (2026-08-29) `location` alone can no longer answer
    /// either. nil for the user's own and real network posts.
    var metro: String? = nil
    let isCommunity: Bool          // drives the "Momentum community" label (honest labeling)
    /// Verified Pro athlete → the checkmark next to the name. Remote posts carry it from the
    /// server profile; the viewer's own posts stamp it from the live entitlement; seeded community
    /// members carry `CommunityGenerator.isPro(handle:)` — deterministic, ~62%, so byline, pager,
    /// and profile always agree (owner call 2026-07-30; replaced the iridescent "Momentum" pill).
    var isPro: Bool = false
    let type: WorkoutType
    let date: Date
    let title: String
    let caption: String?
    let statLine: String
    let prBadge: String?
    /// Muscles worked (strength/HIIT) → rendered as a glowing `MuscleMapView`, the lift counterpart
    /// to the route map. nil/empty for non-strength posts.
    var muscles: [MuscleGroup: Double]? = nil
    /// Real route coordinates [[lat, lon]] — rendered as a map+trace in the feed. nil → glyph media.
    var routeLatLon: [[Double]]? = nil
    /// Which basemap to show behind this post's route (variety across the feed).
    var mapStyle: MapStyleOption = .standard
    /// Seeded baseline respects (community sample engagement); the viewer's own reaction adds on top.
    var baseReactions: Int = 0
    /// Photos the athlete attached (Strava-style, ordered; first is the hero). Since 2026-07-29
    /// they page BEHIND the activity's own visual — see `coverIsPhoto`.
    var photosData: [Data] = []
    /// The cover rule: the activity's own visual (route/muscle/glyph) covers the tile and leads
    /// the pager; a photo covers only when the author explicitly chose it.
    var coverIsPhoto: Bool = false
    /// The hero photo — the first attached photo (convenience for tile/thumbnail contexts).
    var photoData: Data? { photosData.first }
    /// The author's profile photo (the user's own posts); nil → initials/bundled avatar (community).
    var avatarData: Data? = nil
    /// The bundled synthetic-face asset for a seeded community author (deterministic per name), so
    /// community posts show a real-feeling face instead of an initials chip. nil for the user's own
    /// and real network posts (they carry `avatarData`). See `CommunityAvatars`.
    var communityAvatarAsset: String? { isCommunity ? authorHandle.flatMap { CommunityAvatars.assetName(forHandle: $0) } : nil }
    /// The hash-assigned preset look for face-less community athletes (see `CommunityAvatars.preset`).
    var communityPreset: AvatarPreset? { isCommunity ? authorHandle.flatMap { CommunityAvatars.preset(forHandle: $0) } : nil }
    /// The optional public AI read of the workout — shown as the "Momentum read" pull-quote in the
    /// post's reading view. The user's own posts carry their `aiSummary`; community posts are seeded.
    var aiRead: String? = nil
    /// REMOTE posts only: the server's comment count for the rail (blocked-filtered, from
    /// `feed_page.comment_count`). nil for seeded/own posts — their counts are computed locally.
    var remoteCommentCount: Int? = nil

    /// Route as map coordinates for `RouteMapView`.
    var routeCoordinates: [CLLocationCoordinate2D]? {
        routeLatLon.map { $0.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) } }
    }

    /// The stat line split into the Strava-style metric strip (value + label). Derived from `statLine`
    /// so the user's own posts and seeded community posts (same format) both render structured.
    var metrics: [FeedMetric] {
        statLine.components(separatedBy: " · ").compactMap { token in
            let t = token.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            let lower = t.lowercased()
            if lower.contains("/mi") || lower.contains("/km") { return FeedMetric(value: t, label: "Pace") }
            if lower.contains("mi") || lower.contains("km")   { return FeedMetric(value: t, label: "Distance") }
            if lower.contains("lb") || lower.contains("kg")   { return FeedMetric(value: t, label: "Volume") }
            // Trail posts carry a climb figure ("8.1 mi · 1:14:45 · 1,350 ft"). It used to fall
            // through to the unlabeled case, so the pager's stat row showed a number under a blank
            // caption while its neighbours read DISTANCE and TIME — the one cell that looked broken.
            if lower.hasSuffix(" ft") || lower.hasSuffix(" m")  { return FeedMetric(value: t, label: "Climb") }
            if lower.contains("set") {
                let num = t.split(separator: " ").first.map(String.init) ?? t
                return FeedMetric(value: num, label: "Sets")
            }
            if t.contains(":") { return FeedMetric(value: t, label: "Time") }
            return FeedMetric(value: t, label: "")
        }
    }
}

extension FeedItem {
    /// The post's distance in km, read back off its own stat line — what the "save this route"
    /// bookmark stores. The UNIT has to be read too: the leading token is "5.5 mi" for an athlete
    /// on imperial and "8.9 km" for one on metric, and dividing both by 0.621371 stored every
    /// metric athlete's saved routes 1.6× too long (2026-08-28). 0 when the post has no distance.
    var distanceKm: Double {
        guard let token = metrics.first(where: { $0.label == "Distance" })?.value else { return 0 }
        let parts = token.split(separator: " ")
        guard let number = parts.first.map({ $0.replacingOccurrences(of: ",", with: "") }).flatMap(Double.init)
        else { return 0 }
        return parts.dropFirst().first.map(String.init)?.lowercased() == "km" ? number : number / 0.621371
    }
}

/// One cell of a feed post's metric strip — a value over a quiet label (Strava's signature stat row).
struct FeedMetric: Identifiable, Sendable, Hashable {
    let value: String
    let label: String
    var id: String { label + value }
}

/// Pure, testable feed assembly (docs/SOCIAL-LAYER.md). Merges the athlete's **shared** workouts with
/// the seeded community, newest first. Private workouts never appear; route geometry only when the
/// athlete opted route maps in.
enum FeedAssembler {
    static func feed(userWorkouts: [Workout], profile: UserProfile?,
                     community: [FeedItem], viewerIsPro: Bool = false, now: Date = Date()) -> [FeedItem] {
        let mine = userWorkouts
            .filter { SocialPrivacy.isShared($0) }
            .map { item(from: $0, profile: profile, isPro: viewerIsPro) }
        return (mine + community).sorted { $0.date > $1.date }
    }

    /// Follow-scoped view of an assembled feed: the athlete's own posts plus posts from handles they
    /// follow. Ordering is preserved (the assembled feed is already newest-first). Pure for testability.
    static func scoped(_ feed: [FeedItem], following: Set<String>) -> [FeedItem] {
        feed.filter { !$0.isCommunity || ($0.authorHandle.map(following.contains) ?? false) }
    }

    /// Map a shared `Workout` into a feed card from the owner's point of view.
    static func item(from w: Workout, profile: UserProfile?, isPro: Bool = false) -> FeedItem {
        let weightUnit = WeightUnit(rawValue: profile?.weightUnit ?? "kg") ?? .kg
        let distanceUnit = DistanceUnit(rawValue: profile?.distanceUnit ?? "auto") ?? .auto
        let showRoute = profile.map { SocialPrivacy.showsRoute(w, profile: $0) } ?? false
        let route: [[Double]]? = showRoute ? routeLatLon(w) : nil
        let muscles: [MuscleGroup: Double]? = muscleMap(w)
        return FeedItem(
            id: w.id,
            authorName: displayName(profile),
            authorHandle: profile.flatMap { $0.handle.isEmpty ? nil : $0.handle },
            location: profile.flatMap(SocialPrivacy.publicLocation),
            isCommunity: false,
            isPro: isPro,
            type: w.type,
            date: w.startedAt,
            title: w.title.isEmpty ? w.type.title : w.title,
            caption: w.note.isEmpty ? nil : w.note,
            statLine: statLine(w, weightUnit: weightUnit, distanceUnit: distanceUnit),
            prBadge: nil,
            muscles: muscles,
            routeLatLon: route,
            // The athlete's own posts render the map THEY saved the run with (save-screen choice).
            mapStyle: w.gps?.mapStyle ?? .standard,
            photosData: w.orderedPhotosData,
            coverIsPhoto: w.coverIsPhoto,
            avatarData: profile?.avatarData,
            aiRead: w.aiSummary)
    }

    static func displayName(_ profile: UserProfile?) -> String {
        let n = profile?.displayName.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? "You" : n
    }

    static func statLine(_ w: Workout, weightUnit: WeightUnit, distanceUnit: DistanceUnit) -> String {
        if w.type.isStrengthStyle, let s = w.strength {
            let vol = weightUnit == .lb ? s.totalVolumeKg * Formatters.lbPerKg : s.totalVolumeKg
            // `.formatted()`, never raw Int interpolation — every other surface (and every seeded
            // post) groups thousands, so "15608 lb" on the wall read as a different app.
            return "\(Int(vol).formatted()) \(weightUnit == .lb ? "lb" : "kg") · \(s.totalSets) sets · \(Formatters.duration(s: w.durationS))"
        } else if let gps = w.gps, gps.distanceM > 0 {
            return "\(Formatters.distance(meters: gps.distanceM, unit: distanceUnit)) · \(Formatters.duration(s: w.durationS))"
        }
        return Formatters.duration(s: w.durationS)
    }

    /// Muscles a strength/HIIT workout worked — from real logged sets, with a title-based fallback so
    /// a lift post always has a body to light up. nil for non-strength workouts.
    static func muscleMap(_ w: Workout) -> [MuscleGroup: Double]? {
        guard w.type.isStrengthStyle else { return nil }
        if let session = w.strength {
            let logged = MuscleActivation.from(session: session)
            if !logged.isEmpty { return logged }
        }
        let title = w.title.isEmpty ? w.type.title : w.title
        return StrengthFeedMuscles.activation(forTitle: title, type: w.type)
    }

    /// A workout's accepted GPS samples as real [[lat, lon]] coordinates for the feed map.
    static func routeLatLon(_ w: Workout) -> [[Double]]? {
        let pts = w.gps?.routeCoordinates(type: w.type) ?? []
        guard pts.count > 1 else { return nil }
        return pts.map { [$0.latitude, $0.longitude] }
    }
}
