import Foundation

/// The deterministic **publish contract** for the social backend (docs/SOCIAL-LAYER.md Slice 6):
/// exactly what a shared workout and a public profile look like on the wire. Pure + testable —
/// the transport (`SupabaseSocialBackend`) just ships what this produces. Rules encoded here:
///  • A post exists only for a shared workout (`SocialPrivacy.isShared`); private stays home.
///  • Everything in a post is **publish-redacted at build time**: location granularity applied,
///    stat line respects "show exact numbers", route present only when route maps are opted in —
///    and then end-trimmed (`RouteTrimmer`) so precise start/end points never leave the device.
///  • The full-precision route belongs to `SyncEngine`/`workouts` (owner-only), never to a post.
enum SocialSyncEngine {

    /// The athlete's public projection (mirrors the Supabase `profiles` table; `id` is injected
    /// by the transport from the session).
    struct ProfileDTO: Codable, Equatable, Sendable {
        let handle: String
        let displayName: String
        let bio: String
        let publicLocation: String?
        var avatarPath: String?
        let discoverable: Bool
    }

    /// One feed post (mirrors the Supabase `posts` table). `photoPaths` is filled in by the
    /// transport after the Storage uploads succeed.
    struct PostDTO: Codable, Equatable, Sendable {
        let id: String
        let visibility: String                 // 'public' | 'friends' (never 'private')
        let workoutType: String
        let startedAt: Date
        let title: String
        let caption: String?
        let statLine: String
        let distanceM: Double?
        let durationS: Double?
        let totalVolumeKg: Double?
        let totalSets: Int?
        let avgPaceSPerKm: Double?
        let prBadge: String?
        let muscles: [String: Double]?
        let route: [[Double]]?                 // TRIMMED [[lat,lon]] | nil
        let mapStyle: String
        let aiRead: String?
        var photoPaths: [String] = []
    }

    /// One row of the `feed_page` RPC — the wire shape a remote post arrives in. Explicit
    /// snake_case keys so decoding never depends on a globally-configured decoder.
    struct FeedRow: Codable, Equatable, Sendable {
        let id: UUID
        let authorId: UUID
        let authorName: String
        let authorHandle: String?
        let authorLocation: String?
        let avatarPath: String?
        let workoutType: String
        let startedAt: Date
        let title: String
        let caption: String?
        let statLine: String
        let prBadge: String?
        let muscles: [String: Double]?
        let route: [[Double]]?
        let mapStyle: String
        let aiRead: String?
        let photoPaths: [String]
        let reactionCount: Int
        let viewerReacted: Bool
        let createdAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case authorId = "author_id"
            case authorName = "author_name"
            case authorHandle = "author_handle"
            case authorLocation = "author_location"
            case avatarPath = "avatar_path"
            case workoutType = "workout_type"
            case startedAt = "started_at"
            case title, caption
            case statLine = "stat_line"
            case prBadge = "pr_badge"
            case muscles, route
            case mapStyle = "map_style"
            case aiRead = "ai_read"
            case photoPaths = "photo_paths"
            case reactionCount = "reaction_count"
            case viewerReacted = "viewer_reacted"
            case createdAt = "created_at"
        }
    }

    /// Render a remote post through the exact same card as seeds and own posts. `isCommunity`
    /// is false — this is a real athlete, not badged sample content. The viewer's own reaction
    /// is subtracted from the server count so `ReactionStore.count(for:)` (baseline + own tap)
    /// stays exact after the merge.
    static func feedItem(from row: FeedRow, photos: [Data], avatar: Data?) -> FeedItem {
        FeedItem(
            id: row.id,
            authorName: row.authorName.isEmpty ? "Athlete" : row.authorName,
            authorHandle: row.authorHandle,
            location: row.authorLocation,
            isCommunity: false,
            type: WorkoutType(rawValue: row.workoutType) ?? .run,
            date: row.startedAt,
            title: row.title,
            caption: row.caption,
            statLine: row.statLine,
            prBadge: row.prBadge,
            muscles: row.muscles.map { dict in
                Dictionary(uniqueKeysWithValues: dict.compactMap { key, value in
                    MuscleGroup(rawValue: key).map { ($0, value) }
                })
            },
            routeLatLon: (row.route?.count ?? 0) > 1 ? row.route : nil,
            mapStyle: MapStyleOption(rawValue: row.mapStyle) ?? .standard,
            baseReactions: max(0, row.reactionCount - (row.viewerReacted ? 1 : 0)),
            photosData: photos,
            avatarData: avatar,
            aiRead: row.aiRead)
    }

    /// The publish sweep (runs opportunistically with the workout sync): which workouts need a
    /// post created, and which need their post deleted (privacy downgraded after publishing).
    /// Symmetric and idempotent — backfill of already-shared history falls out for free.
    static func publishActions(_ workouts: [Workout]) -> (publish: [Workout], unpublish: [Workout]) {
        let publish = workouts
            .filter { SocialPrivacy.isShared($0) && $0.postPublishedAt == nil }
            .sorted { $0.startedAt < $1.startedAt }
        let unpublish = workouts.filter { !SocialPrivacy.isShared($0) && $0.postPublishedAt != nil }
        return (publish, unpublish)
    }

    /// The public projection of a profile. Location is redacted here (granularity → city or
    /// nothing) — the raw city string never uploads unless the athlete opted in.
    static func profileDTO(for profile: UserProfile) -> ProfileDTO {
        ProfileDTO(
            handle: SocialPrivacy.normalizedHandle(profile.handle),
            displayName: profile.displayName.trimmingCharacters(in: .whitespaces),
            bio: profile.bio.trimmingCharacters(in: .whitespaces),
            publicLocation: SocialPrivacy.publicLocation(profile),
            avatarPath: nil,
            discoverable: profile.discoverable)
    }

    /// Build the publishable post for a workout — nil when the workout isn't shared. The stat
    /// line is pre-formatted in the author's units (same as the feed renders today); with
    /// "show exact numbers" off it's omitted entirely (honest: no numbers rather than fake ones).
    static func postDTO(for w: Workout, profile: UserProfile) -> PostDTO? {
        guard SocialPrivacy.isShared(w), w.privacy != .private else { return nil }
        let weightUnit = WeightUnit(rawValue: profile.weightUnit) ?? .kg
        let distanceUnit = DistanceUnit(rawValue: profile.distanceUnit) ?? .auto
        let statLine = SocialPrivacy.showsExactNumbers(profile)
            ? FeedAssembler.statLine(w, weightUnit: weightUnit, distanceUnit: distanceUnit)
            : ""
        let route: [[Double]]? = SocialPrivacy.showsRoute(w, profile: profile)
            ? RouteTrimmer.trimmed(FeedAssembler.routeLatLon(w))
            : nil
        return PostDTO(
            id: w.id.uuidString,
            visibility: w.privacy.rawValue,
            workoutType: w.type.rawValue,
            startedAt: w.startedAt,
            title: w.title.isEmpty ? w.type.title : w.title,
            caption: w.note.isEmpty ? nil : w.note,
            statLine: statLine,
            distanceM: SocialPrivacy.showsExactNumbers(profile) ? w.gps?.distanceM : nil,
            durationS: w.durationS,
            totalVolumeKg: SocialPrivacy.showsExactNumbers(profile) ? w.strength?.totalVolumeKg : nil,
            totalSets: w.strength?.totalSets,
            avgPaceSPerKm: SocialPrivacy.showsExactNumbers(profile) ? w.gps?.avgPaceSPerKm : nil,
            prBadge: nil,
            muscles: FeedAssembler.muscleMap(w).map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) },
            route: route,
            mapStyle: (w.gps?.mapStyle ?? .standard).rawValue,
            aiRead: w.aiSummary)
    }
}

/// End-trims a shared route so the precise start/finish (usually home) never leaves the device.
/// Deterrence, not cryptographic protection (docs/SOCIAL-BACKEND-SETUP.md) — the strong
/// guarantee is that the removed points are simply absent from anything shareable.
enum RouteTrimmer {

    /// Drop ~`trimM` meters from each end. nil when there's no meaningful path to share —
    /// including short loops, where trimming both ends would still reveal the whole circuit.
    static func trimmed(_ path: [[Double]]?, trimM: Double = 200) -> [[Double]]? {
        guard let path, path.count > 1 else { return nil }
        let total = length(of: path)
        // A path that can't spare both ends plus a stretch in the middle isn't shareable at all.
        guard total > trimM * 2.5 else { return nil }

        var startIdx = 0, accumulated = 0.0
        while startIdx < path.count - 1, accumulated < trimM {
            accumulated += meters(path[startIdx], path[startIdx + 1])
            startIdx += 1
        }
        var endIdx = path.count - 1
        accumulated = 0
        while endIdx > 0, accumulated < trimM {
            accumulated += meters(path[endIdx - 1], path[endIdx])
            endIdx -= 1
        }
        guard endIdx > startIdx + 1 else { return nil }
        return Array(path[startIdx...endIdx])
    }

    static func length(of path: [[Double]]) -> Double {
        guard path.count > 1 else { return 0 }
        return zip(path, path.dropFirst()).reduce(0) { $0 + meters($1.0, $1.1) }
    }

    /// Haversine distance between two [lat, lon] points.
    static func meters(_ a: [Double], _ b: [Double]) -> Double {
        let r = 6_371_000.0
        let dLat = (b[0] - a[0]) * .pi / 180
        let dLon = (b[1] - a[1]) * .pi / 180
        let la1 = a[0] * .pi / 180, la2 = b[0] * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
