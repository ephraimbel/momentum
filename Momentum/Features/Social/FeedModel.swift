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
    /// At most one truthful reason this post matters (record, first distance milestone, or plan
    /// context). It is separate from `prBadge`: a planned long run is meaningful but is not a PR.
    var earnedContext: String? = nil
    /// Muscles worked (strength/HIIT) → rendered as a glowing `MuscleMapView`, the lift counterpart
    /// to the route map. nil/empty for non-strength posts.
    var muscles: [MuscleGroup: Double]? = nil
    /// Real route coordinates [[lat, lon]] — rendered as a map+trace in the feed. nil → glyph media.
    var routeLatLon: [[Double]]? = nil
    /// Which basemap to show behind this post's route (variety across the feed).
    var mapStyle: MapStyleOption = .standard
    /// Seeded baseline respects (community sample engagement); the viewer's own reaction adds on top.
    var baseReactions: Int = 0
    /// Photos the athlete attached (Strava-style, ordered; first is the hero photo).
    var photosData: [Data] = []
    /// The initial cover rule: the activity's own visual (route/muscle/glyph) leads unless the
    /// author explicitly chose a photo. The post viewer keeps both available as a two-way swap.
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

    /// Whether the post contains at least one real, drawable route segment. This intentionally
    /// validates the untrusted server array instead of trusting `count`: a malformed pair such as
    /// `[latitude]` used to pass the count gate and then crash every Community surface when the
    /// coordinate accessor subscripted its missing longitude.
    var hasRenderableRoute: Bool {
        guard let pairs = routeLatLon else { return false }
        var first: CLLocationCoordinate2D?
        for pair in pairs {
            guard let coordinate = Self.validCoordinate(pair) else { continue }
            guard let first else {
                first = coordinate
                continue
            }
            if coordinate.latitude != first.latitude || coordinate.longitude != first.longitude {
                return true
            }
        }
        return false
    }

    /// Route as validated map coordinates for `RouteMapView`. Remote JSON is never allowed to
    /// reach SwiftUI, Mapbox, the snapshotter, or Saved Routes until malformed values and adjacent
    /// duplicates have been removed. `nil` means there is no drawable segment and callers should
    /// fall back to the post's photo/sport visual.
    var routeCoordinates: [CLLocationCoordinate2D]? {
        sanitizedRouteLatLon?.map {
            CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1])
        }
    }

    /// The storage representation of the validated route, used when bookmarking a shared post.
    /// Keeping this derived from `routeCoordinates` prevents malformed server JSON from becoming a
    /// durable `SavedRoute` that would fail again on a later screen.
    var sanitizedRouteLatLon: [[Double]]? {
        Self.sanitizedRouteLatLon(routeLatLon)
    }

    /// Sanitize once at the network boundary as well as defensively at use sites. This keeps the
    /// stored `FeedItem` honest, so even future call sites that perform a cheap nil/count check do
    /// not accidentally treat a malformed remote payload as a route.
    static func sanitizedRouteLatLon(_ pairs: [[Double]]?) -> [[Double]]? {
        guard let pairs else { return nil }
        var result: [[Double]] = []
        result.reserveCapacity(pairs.count)
        for pair in pairs {
            guard let coordinate = validCoordinate(pair) else { continue }
            if let previous = result.last,
               previous[0] == coordinate.latitude,
               previous[1] == coordinate.longitude {
                continue
            }
            result.append([coordinate.latitude, coordinate.longitude])
        }
        guard result.count > 1,
              result.dropFirst().contains(where: {
                  $0[0] != result[0][0] || $0[1] != result[0][1]
              }) else { return nil }
        return result
    }

    private static func validCoordinate(_ pair: [Double]) -> CLLocationCoordinate2D? {
        guard pair.count >= 2 else { return nil }
        let latitude = pair[0]
        let longitude = pair[1]
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
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

/// A bounded identity for image bytes. UI tasks need to notice replacement content, but hashing a
/// multi-megabyte JPEG every time SwiftUI compares a tile would recreate the scroll hitch the image
/// cache removed. Length, the first/last 64 bytes, and evenly-spaced interior samples distinguish
/// real photo edits while keeping the work constant.
enum MediaFingerprint {
    static func value(_ data: Data?) -> UInt64 {
        guard let data else { return 0 }
        var hash: UInt64 = 1_469_598_103_934_665_603
        func mix(_ byte: UInt8, into value: inout UInt64) {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        var count = UInt64(data.count)
        for _ in 0..<8 {
            mix(UInt8(truncatingIfNeeded: count), into: &hash)
            count >>= 8
        }
        for byte in data.prefix(64) { mix(byte, into: &hash) }
        if data.count > 128 {
            for sample in 1...16 {
                let offset = sample * (data.count - 1) / 17
                mix(data[data.index(data.startIndex, offsetBy: offset)], into: &hash)
            }
        }
        for byte in data.suffix(64) { mix(byte, into: &hash) }
        return hash
    }

    static func value(_ data: [Data]) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for photo in data {
            hash ^= value(photo)
            hash &*= 1_099_511_628_211
        }
        hash ^= UInt64(data.count)
        return hash
    }
}

extension FeedItem {
    /// Everything a realized grid tile or pager summary can visibly draw, without comparing whole
    /// JPEGs or full polylines. A post id is stable across edits, so id-only equality is incorrect:
    /// this signature lets same-id photo/cover/caption/count updates invalidate exactly that tile.
    var renderSignature: Int {
        var h = Hasher()
        h.combine(authorName)
        h.combine(authorHandle)
        h.combine(location)
        h.combine(isCommunity)
        h.combine(isPro)
        h.combine(type)
        h.combine(date)
        h.combine(title)
        h.combine(caption)
        h.combine(statLine)
        h.combine(prBadge)
        h.combine(earnedContext)
        h.combine(mapStyle)
        h.combine(baseReactions)
        h.combine(remoteCommentCount)
        h.combine(coverIsPhoto)
        h.combine(MediaFingerprint.value(photosData))
        h.combine(MediaFingerprint.value(avatarData))
        if let muscles {
            for pair in muscles.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                h.combine(pair.key)
                h.combine(pair.value)
            }
        }
        if let routeLatLon {
            h.combine(routeLatLon.count)
            if let first = routeLatLon.first { h.combine(first) }
            if routeLatLon.count > 2 { h.combine(routeLatLon[routeLatLon.count / 2]) }
            if let last = routeLatLon.last { h.combine(last) }
        }
        return h.finalize()
    }

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
    static func item(from w: Workout, profile: UserProfile?, isPro: Bool = false,
                     earnedContext: String? = nil) -> FeedItem {
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
            earnedContext: earnedContext,
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
