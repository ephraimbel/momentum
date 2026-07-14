import Foundation
import SwiftData
import Supabase
import os

/// Quiet breadcrumbs for the best-effort paths — "silently kept local" and "silently lost" look
/// identical without them (this is exactly how a swallowed claim failure hid during the E2E).
private let socialLog = Logger(subsystem: "com.ephraimbel.momentum.app", category: "social")

/// The social network transport (docs/SOCIAL-BACKEND-SETUP.md). Everything is best-effort and
/// offline-first: the UserDefaults stores remain the UI's source of truth; this pushes their
/// mutations up and pulls remote state in behind them. `isAvailable` is false for guests and the
/// unconfigured app — every caller no-ops through it, keeping ship-dark behavior byte-identical.
@MainActor
protocol SocialBackending: AnyObject {
    var isAvailable: Bool { get async }
    /// Whether the signed-in athlete holds a Pro subscription — stamped onto the published
    /// profile as the verification checkmark (display status, never a server gate).
    var viewerIsPro: Bool { get }

    // Profile
    func pushProfile(_ dto: SocialSyncEngine.ProfileDTO) async throws
    func uploadAvatar(jpeg: Data) async -> String?
    /// Advisory availability probe for the @handle field. Works WITHOUT a session (anon RPC) so
    /// guests get live checks during onboarding; nil = unknown (offline/unconfigured) and the UI
    /// stays neutral — the unique index at claim time is the real arbiter.
    func handleAvailability(_ handle: String) async -> Bool?

    // Posts
    func publish(_ post: SocialSyncEngine.PostDTO, photos: [Data]) async -> Bool
    func unpublish(postID: UUID) async -> Bool
    func feed(scope: FeedScope, cursor: FeedCursor?, limit: Int) async -> FeedPage?
    func athletePage(handle: String) async -> AthletePage?
    /// Find discoverable athletes by name or @handle. nil = unavailable (guest/offline/dark);
    /// only `discoverable = true` profiles surface (privacy is opt-in).
    func searchAthletes(query: String, limit: Int) async -> [AthleteHit]?
    func signedPhotoURLs(paths: [String]) async -> [String: URL]
    func publicAvatarURL(path: String) -> URL?

    // Graph + engagement
    func setFollow(handle: String, following: Bool) async
    func pullFollowing() async -> Set<String>?
    func setReaction(postID: UUID, reacted: Bool) async
    func pushComment(_ comment: Comment) async
    func deleteComment(id: UUID) async
    func pullComments(postID: UUID) async -> [Comment]?

    // Safety
    func setBlock(handle: String, blocked: Bool) async
    func report(postID: UUID?, commentID: UUID?, handle: String?, reason: ReportReason, details: String?) async
}

enum FeedScope: String, Sendable { case everyone, following }

struct FeedCursor: Sendable, Equatable {
    let created: Date
    let id: UUID
}

struct FeedPage: Sendable {
    let rows: [SocialSyncEngine.FeedRow]
    let next: FeedCursor?
}

/// One search hit — a discoverable athlete's public identity (no posts; the profile page loads those).
struct AthleteHit: Sendable, Identifiable {
    let handle: String
    let displayName: String
    let location: String?
    let avatarPath: String?
    var id: String { handle }
}

/// One remote athlete's public projection + their visible posts.
struct AthletePage: Sendable {
    let handle: String
    let displayName: String
    let bio: String
    let location: String?
    let avatarPath: String?
    let rows: [SocialSyncEngine.FeedRow]
}

enum SocialBackendError: Error {
    case handleTaken
    case unavailable
}

extension SocialBackending {
    /// Claim the athlete's identity on the backend: avatar first (so the first profile row
    /// carries its path), then the profile upsert. No-ops for guests/dark builds/empty handles.
    /// Losing the claim race (handle taken between the availability check and now, or a guest's
    /// handle claimed while they were offline) keeps the local handle and posts one deduped
    /// inbox notification pointing at Edit Profile — no-shame, no blocking.
    func claimProfile(_ profile: UserProfile, in context: ModelContext) async {
        guard await isAvailable else {
            socialLog.info("claimProfile skipped: backend unavailable (guest or unconfigured)")
            return
        }
        var dto = SocialSyncEngine.profileDTO(for: profile, isPro: viewerIsPro)
        guard !dto.handle.isEmpty || !dto.displayName.isEmpty else { return }
        if let avatar = profile.avatarData, let path = await uploadAvatar(jpeg: avatar) {
            dto.avatarPath = path
        }
        do {
            try await pushProfile(dto)
            socialLog.info("claimProfile: pushed @\(dto.handle, privacy: .public)")
        } catch SocialBackendError.handleTaken {
            AppNotification.post(
                kind: .system,
                title: "Your handle is taken",
                body: "@\(dto.handle) was claimed by another athlete — pick a new one in Edit Profile.",
                in: context,
                dedupeToken: "handle-conflict",
                daily: false)
            try? context.save()
        } catch {
            // Offline/transient — the profile stays local and re-claims on the next edit/sign-in.
            socialLog.error("claimProfile push failed: \(error, privacy: .public)")
        }
    }

    /// The opportunistic publish sweep (runs alongside the workout sync on Today's appear):
    /// posts for newly-shared workouts go up (photos first), privacy-downgraded posts come down.
    /// `postPublishedAt` is stamped/cleared **on success only**, so failures retry next sweep —
    /// the same offline-first model as `SyncService`.
    func runPublishSweep(workouts: [Workout], profile: UserProfile?, in context: ModelContext) async {
        guard await isAvailable, let profile else { return }
        let actions = SocialSyncEngine.publishActions(workouts)
        guard !actions.publish.isEmpty || !actions.unpublish.isEmpty else { return }
        for workout in actions.publish {
            guard let dto = SocialSyncEngine.postDTO(for: workout, profile: profile) else { continue }
            if await publish(dto, photos: workout.orderedPhotosData) {
                workout.postPublishedAt = Date()
            }
        }
        for workout in actions.unpublish {
            if await unpublish(postID: workout.id) {
                workout.postPublishedAt = nil
            }
        }
        try? context.save()
    }
}

/// Previews, tests, guests-without-config: social stays local, nothing leaves the device.
@MainActor
final class StubSocialBackend: SocialBackending {
    var isAvailable: Bool { false }
    var viewerIsPro: Bool { false }
    func pushProfile(_ dto: SocialSyncEngine.ProfileDTO) async throws {}
    func uploadAvatar(jpeg: Data) async -> String? { nil }
    func handleAvailability(_ handle: String) async -> Bool? { nil }
    func publish(_ post: SocialSyncEngine.PostDTO, photos: [Data]) async -> Bool { false }
    func unpublish(postID: UUID) async -> Bool { false }
    func feed(scope: FeedScope, cursor: FeedCursor?, limit: Int) async -> FeedPage? { nil }
    func athletePage(handle: String) async -> AthletePage? { nil }
    func searchAthletes(query: String, limit: Int) async -> [AthleteHit]? { nil }
    func signedPhotoURLs(paths: [String]) async -> [String: URL] { [:] }
    func publicAvatarURL(path: String) -> URL? { nil }
    func setFollow(handle: String, following: Bool) async {}
    func pullFollowing() async -> Set<String>? { nil }
    func setReaction(postID: UUID, reacted: Bool) async {}
    func pushComment(_ comment: Comment) async {}
    func deleteComment(id: UUID) async {}
    func pullComments(postID: UUID) async -> [Comment]? { nil }
    func setBlock(handle: String, blocked: Bool) async {}
    func report(postID: UUID?, commentID: UUID?, handle: String?, reason: ReportReason, details: String?) async {}
}

/// The live Supabase transport. All SDK usage in the app is contained here + the provider.
@MainActor
final class SupabaseSocialBackend: SocialBackending {

    /// For stamping `is_pro` on the profile projection at publish (every `Feature` requires
    /// Pro, so probing any one of them reads the subscription itself).
    private let paywall: (any PaywallServing)?

    init(paywall: (any PaywallServing)? = nil) {
        self.paywall = paywall
    }

    var viewerIsPro: Bool { paywall?.isEntitled(to: .fullPlan) ?? false }

    private var client: SupabaseClient? { SupabaseClientProvider.client }

    /// Configured AND signed in (a session exists) — guests and dark builds fail this gate.
    var isAvailable: Bool {
        get async {
            guard let client else { return false }
            return (try? await client.auth.session) != nil
        }
    }

    private func session() async -> Session? {
        guard let client else { return nil }
        return try? await client.auth.session
    }

    // MARK: Profile

    func pushProfile(_ dto: SocialSyncEngine.ProfileDTO) async throws {
        guard let client, let session = await session() else { return }
        struct Row: Encodable {
            let id: UUID
            let handle: String
            let display_name: String
            let bio: String
            let public_location: String?
            let avatar_path: String?
            let discoverable: Bool
            let is_pro: Bool
            let updated_at: Date
        }
        let row = Row(id: session.user.id, handle: dto.handle, display_name: dto.displayName,
                      bio: dto.bio, public_location: dto.publicLocation,
                      avatar_path: dto.avatarPath, discoverable: dto.discoverable,
                      is_pro: dto.isPro, updated_at: Date())
        do {
            try await client.from("profiles").upsert(row).execute()
        } catch {
            // 23505 = unique_violation on profiles_handle_unique → someone owns that handle.
            if let pgError = error as? PostgrestError, pgError.code == "23505" {
                throw SocialBackendError.handleTaken
            }
            throw error
        }
    }

    /// Anon-callable by design (see the migration): gate on the client existing, NEVER on a
    /// session — guests are the whole point of this probe.
    func handleAvailability(_ handle: String) async -> Bool? {
        guard let client, !handle.isEmpty else { return nil }
        do {
            let available: Bool = try await client
                .rpc("handle_available", params: ["p_handle": handle])
                .execute().value
            return available
        } catch { return nil }
    }

    func uploadAvatar(jpeg: Data) async -> String? {
        guard let client, let session = await session() else { return nil }
        let path = "\(session.user.id.uuidString.lowercased())/avatar.jpg"
        do {
            try await client.storage.from("avatars")
                .upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg", upsert: true))
            return path
        } catch { return nil }
    }

    // MARK: Posts

    func publish(_ post: SocialSyncEngine.PostDTO, photos: [Data]) async -> Bool {
        guard let client, let session = await session() else { return false }
        var dto = post
        let uid = session.user.id.uuidString.lowercased()
        // Photos first — the row references their paths. Idempotent by deterministic path.
        var paths: [String] = []
        for (index, data) in photos.prefix(Workout.photoCap).enumerated() {
            let path = "\(uid)/\(post.id.lowercased())/\(index).jpg"
            do {
                try await client.storage.from("post-photos")
                    .upload(path, data: data, options: FileOptions(contentType: "image/jpeg", upsert: true))
                paths.append(path)
            } catch {
                return false   // partial photo set would render wrong — retry the whole publish later
            }
        }
        dto.photoPaths = paths
        struct Row: Encodable {
            let id: String, author_id: UUID, visibility: String, workout_type: String
            let started_at: Date, title: String, caption: String?, stat_line: String
            let distance_m: Double?, duration_s: Double?, total_volume_kg: Double?
            let total_sets: Int?, avg_pace_s_per_km: Double?, pr_badge: String?
            let muscles: [String: Double]?, route: [[Double]]?, map_style: String
            let ai_read: String?, photo_paths: [String]
        }
        let row = Row(id: dto.id, author_id: session.user.id, visibility: dto.visibility,
                      workout_type: dto.workoutType, started_at: dto.startedAt, title: dto.title,
                      caption: dto.caption, stat_line: dto.statLine, distance_m: dto.distanceM,
                      duration_s: dto.durationS, total_volume_kg: dto.totalVolumeKg,
                      total_sets: dto.totalSets, avg_pace_s_per_km: dto.avgPaceSPerKm,
                      pr_badge: dto.prBadge, muscles: dto.muscles, route: dto.route,
                      map_style: dto.mapStyle, ai_read: dto.aiRead, photo_paths: dto.photoPaths)
        do {
            try await client.from("posts").upsert(row).execute()
            return true
        } catch { return false }
    }

    func unpublish(postID: UUID) async -> Bool {
        guard let client, await isAvailable else { return false }
        do {
            try await client.from("posts").delete().eq("id", value: postID).execute()
            // Best-effort photo cleanup: list + remove the post's folder.
            if let session = await session() {
                let folder = "\(session.user.id.uuidString.lowercased())/\(postID.uuidString.lowercased())"
                if let objects = try? await client.storage.from("post-photos").list(path: folder), !objects.isEmpty {
                    _ = try? await client.storage.from("post-photos")
                        .remove(paths: objects.map { "\(folder)/\($0.name)" })
                }
            }
            return true
        } catch { return false }
    }

    func feed(scope: FeedScope, cursor: FeedCursor?, limit: Int) async -> FeedPage? {
        guard let client, await isAvailable else { return nil }
        struct Params: Encodable {
            let p_scope: String
            let p_cursor_created: Date?
            let p_cursor_id: UUID?
            let p_limit: Int
        }
        do {
            let rows: [SocialSyncEngine.FeedRow] = try await client
                .rpc("feed_page", params: Params(p_scope: scope.rawValue,
                                                 p_cursor_created: cursor?.created,
                                                 p_cursor_id: cursor?.id,
                                                 p_limit: limit))
                .execute().value
            let next = rows.count >= limit
                ? rows.last.map { FeedCursor(created: $0.createdAt, id: $0.id) }
                : nil
            return FeedPage(rows: rows, next: next)
        } catch { return nil }
    }

    func athletePage(handle: String) async -> AthletePage? {
        guard let client, await isAvailable, !handle.isEmpty else { return nil }
        struct ProfileRow: Decodable {
            let id: UUID
            let handle: String
            let display_name: String
            let bio: String
            let public_location: String?
            let avatar_path: String?
        }
        struct Params: Encodable {
            let p_scope: String
            let p_limit: Int
            let p_author: UUID
        }
        do {
            let profile: ProfileRow = try await client.from("profiles")
                .select("id,handle,display_name,bio,public_location,avatar_path")
                .eq("handle", value: handle)
                .single()
                .execute().value
            let rows: [SocialSyncEngine.FeedRow] = try await client
                .rpc("feed_page", params: Params(p_scope: FeedScope.everyone.rawValue,
                                                 p_limit: 50, p_author: profile.id))
                .execute().value
            return AthletePage(handle: profile.handle, displayName: profile.display_name,
                               bio: profile.bio, location: profile.public_location,
                               avatarPath: profile.avatar_path, rows: rows)
        } catch { return nil }
    }

    func searchAthletes(query: String, limit: Int) async -> [AthleteHit]? {
        guard let client, await isAvailable else { return nil }
        // Strip the @ people naturally type, and the ilike wildcards so user input can't widen
        // the pattern. Sub-2-char queries return empty rather than the whole directory.
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ",", with: "")
        guard q.count >= 2 else { return [] }
        struct Row: Decodable {
            let handle: String
            let display_name: String
            let public_location: String?
            let avatar_path: String?
        }
        do {
            let rows: [Row] = try await client.from("profiles")
                .select("handle,display_name,public_location,avatar_path")
                .eq("discoverable", value: true)
                .neq("handle", value: "")
                .or("handle.ilike.%\(q)%,display_name.ilike.%\(q)%")
                .limit(limit)
                .execute().value
            return rows.map {
                AthleteHit(handle: $0.handle, displayName: $0.display_name,
                           location: $0.public_location, avatarPath: $0.avatar_path)
            }
        } catch { return nil }
    }

    func signedPhotoURLs(paths: [String]) async -> [String: URL] {
        guard let client, !paths.isEmpty, await isAvailable else { return [:] }
        do {
            let results: [SignedURLResult] = try await client.storage.from("post-photos")
                .createSignedURLs(paths: paths, expiresIn: 3600)
            var byPath: [String: URL] = [:]
            for result in results {
                if case let .success(path, signedURL) = result { byPath[path] = signedURL }
            }
            return byPath
        } catch { return [:] }
    }

    func publicAvatarURL(path: String) -> URL? {
        guard let client, !path.isEmpty else { return nil }
        return try? client.storage.from("avatars").getPublicURL(path: path)
    }

    // MARK: Graph + engagement

    /// Handles are the client's stable key; the server keys on profile UUIDs — resolve first.
    private func profileID(forHandle handle: String) async -> UUID? {
        guard let client, !handle.isEmpty else { return nil }
        struct Row: Decodable { let id: UUID }
        let row: Row? = try? await client.from("profiles")
            .select("id").eq("handle", value: handle).single().execute().value
        return row?.id
    }

    func setFollow(handle: String, following: Bool) async {
        guard let client, let session = await session(),
              let followee = await profileID(forHandle: handle) else { return }
        if following {
            struct Row: Encodable { let follower_id: UUID; let followee_id: UUID }
            _ = try? await client.from("follows")
                .upsert(Row(follower_id: session.user.id, followee_id: followee)).execute()
        } else {
            _ = try? await client.from("follows").delete()
                .eq("follower_id", value: session.user.id)
                .eq("followee_id", value: followee).execute()
        }
    }

    func pullFollowing() async -> Set<String>? {
        guard let client, let session = await session() else { return nil }
        struct Row: Decodable {
            let followee: Handle
            struct Handle: Decodable { let handle: String }
            enum CodingKeys: String, CodingKey { case followee = "profiles" }
        }
        do {
            let rows: [Row] = try await client.from("follows")
                .select("profiles!follows_followee_id_fkey(handle)")
                .eq("follower_id", value: session.user.id)
                .execute().value
            return Set(rows.map(\.followee.handle).filter { !$0.isEmpty })
        } catch { return nil }
    }

    func setReaction(postID: UUID, reacted: Bool) async {
        guard let client, let session = await session() else { return }
        if reacted {
            struct Row: Encodable { let post_id: UUID; let user_id: UUID }
            _ = try? await client.from("reactions")
                .upsert(Row(post_id: postID, user_id: session.user.id)).execute()
        } else {
            _ = try? await client.from("reactions").delete()
                .eq("post_id", value: postID)
                .eq("user_id", value: session.user.id).execute()
        }
    }

    func pushComment(_ comment: Comment) async {
        guard let client, let session = await session() else { return }
        struct Row: Encodable {
            let id: UUID, post_id: UUID, author_id: UUID, body: String, created_at: Date
        }
        _ = try? await client.from("comments")
            .upsert(Row(id: comment.id, post_id: comment.postID,
                        author_id: session.user.id, body: comment.text,
                        created_at: comment.date)).execute()
    }

    func deleteComment(id: UUID) async {
        guard let client, await isAvailable else { return }
        _ = try? await client.from("comments").delete().eq("id", value: id).execute()
    }

    func pullComments(postID: UUID) async -> [Comment]? {
        guard let client, await isAvailable else { return nil }
        struct Row: Decodable {
            let id: UUID
            let post_id: UUID
            let body: String
            let created_at: Date
            let profiles: Author
            struct Author: Decodable { let display_name: String; let handle: String }
        }
        do {
            let rows: [Row] = try await client.from("comments")
                .select("id,post_id,body,created_at,profiles(display_name,handle)")
                .eq("post_id", value: postID)
                .order("created_at", ascending: true)
                .execute().value
            return rows.map {
                Comment(id: $0.id, postID: $0.post_id,
                        authorName: $0.profiles.display_name.isEmpty ? "Athlete" : $0.profiles.display_name,
                        authorHandle: $0.profiles.handle.isEmpty ? nil : $0.profiles.handle,
                        isCommunity: false, text: $0.body, date: $0.created_at)
            }
        } catch { return nil }
    }

    // MARK: Safety

    func setBlock(handle: String, blocked: Bool) async {
        guard let client, let session = await session(),
              let target = await profileID(forHandle: handle) else { return }
        if blocked {
            struct Row: Encodable { let blocker_id: UUID; let blocked_id: UUID }
            _ = try? await client.from("blocks")
                .upsert(Row(blocker_id: session.user.id, blocked_id: target)).execute()
        } else {
            _ = try? await client.from("blocks").delete()
                .eq("blocker_id", value: session.user.id)
                .eq("blocked_id", value: target).execute()
        }
    }

    func report(postID: UUID?, commentID: UUID?, handle: String?, reason: ReportReason, details: String?) async {
        guard let client, let session = await session() else { return }
        struct Row: Encodable {
            let reporter_id: UUID
            let post_id: UUID?
            let comment_id: UUID?
            let target_handle: String?
            let reason: String
            let details: String?
        }
        let reasonKey: String = switch reason {
        case .spam: "spam"
        case .inappropriate: "inappropriate"
        case .harassment: "harassment"
        case .other: "other"
        }
        _ = try? await client.from("reports")
            .insert(Row(reporter_id: session.user.id, post_id: postID, comment_id: commentID,
                        target_handle: handle, reason: reasonKey, details: details)).execute()
    }
}
