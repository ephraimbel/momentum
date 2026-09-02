import Testing
import Foundation
@testable import Momentum

/// The publish contract (docs/SOCIAL-LAYER.md Slice 6): what leaves the device for the social
/// backend, and what privacy keeps home. Pure fixtures — no network.
@MainActor
struct SocialSyncEngineTests {

    private func profile(shareAll: Bool = true) -> UserProfile {
        let p = UserProfile()
        p.displayName = "Test Athlete"
        p.handle = "testathlete"
        if shareAll {
            p.publicRouteMaps = true
            p.showExactNumbers = true
        }
        return p
    }

    private func run(_ privacy: WorkoutPrivacy, points: Int = 0) -> Workout {
        let w = Workout(); w.type = .run; w.privacy = privacy; w.durationS = 1800
        if points > 0 {
            let g = GPSDetail(); g.distanceM = 5000
            for i in 0..<points {
                let s = LocationSample()
                s.lat = 37.0 + Double(i) * 0.001    // ~111 m per step
                s.lon = -122.0
                s.t = w.startedAt.addingTimeInterval(Double(i)); s.accepted = true
                g.samples.append(s)
            }
            w.gps = g
        }
        return w
    }

    // MARK: postDTO — privacy gates

    @Test func privateWorkoutNeverBecomesAPost() {
        #expect(SocialSyncEngine.postDTO(for: run(.private), profile: profile()) == nil)
    }

    @Test func sharedWorkoutCarriesVisibilityVerbatim() {
        #expect(SocialSyncEngine.postDTO(for: run(.public), profile: profile())?.visibility == "public")
        #expect(SocialSyncEngine.postDTO(for: run(.friends), profile: profile())?.visibility == "friends")
    }

    @Test func routeAbsentWithoutRouteMapsOptIn() {
        let p = profile(); p.publicRouteMaps = false
        let dto = SocialSyncEngine.postDTO(for: run(.public, points: 20), profile: p)
        #expect(dto?.route == nil)
    }

    @Test func routePresentAndTrimmedWhenOptedIn() {
        // 20 points ~111 m apart ≈ 2.1 km — long enough to survive a 200 m end-trim.
        let dto = SocialSyncEngine.postDTO(for: run(.public, points: 20), profile: profile())
        let route = try! #require(dto?.route)
        #expect(route.count < 20)                       // ends removed
        #expect(route.first![0] > 37.0)                 // precise start point gone
        #expect(route.last![0] < 37.0 + 19 * 0.001)     // precise end point gone
    }

    @Test func exactNumbersOffOmitsStatsEntirely() {
        let p = profile(); p.showExactNumbers = false
        let dto = SocialSyncEngine.postDTO(for: run(.public, points: 20), profile: p)
        #expect(dto?.statLine == "")
        #expect(dto?.distanceM == nil)
        #expect(dto?.avgPaceSPerKm == nil)
    }

    @Test func untitledWorkoutFallsBackToSportTitle() {
        let dto = SocialSyncEngine.postDTO(for: run(.public), profile: profile())
        #expect(dto?.title == WorkoutType.run.title)
    }

    @Test func selectedPhotoCoverPublishesAsTheRemoteFirstFrame() {
        let workout = run(.public)
        workout.coverIsPhoto = true
        #expect(SocialSyncEngine.postDTO(for: workout, profile: profile())?.coverIsPhoto == true)
    }

    @Test func earnedContextSurvivesThePublishBoundary() {
        let workout = run(.public)
        let dto = SocialSyncEngine.postDTO(
            for: workout, profile: profile(), earnedContext: "First 5K")
        #expect(dto?.earnedContext == "First 5K")
    }

    // MARK: publishActions — the sweep predicate

    @Test func sweepPublishesSharedUnstampedOldestFirst() {
        let old = run(.public); old.startedAt = Date().addingTimeInterval(-86_400)
        let new = run(.friends)
        let published = run(.public); published.postPublishedAt = Date()
        let priv = run(.private)
        let actions = SocialSyncEngine.publishActions([new, priv, published, old])
        #expect(actions.publish.map(\.id) == [old.id, new.id])   // oldest first, stamped skipped
        #expect(actions.unpublish.isEmpty)
    }

    @Test func sweepUnpublishesPrivacyDowngrades() {
        let downgraded = run(.private); downgraded.postPublishedAt = Date()
        let stillShared = run(.public); stillShared.postPublishedAt = Date()
        let actions = SocialSyncEngine.publishActions([downgraded, stillShared])
        #expect(actions.unpublish.map(\.id) == [downgraded.id])
        #expect(actions.publish.isEmpty)
    }

    // MARK: markEdited — editing an activity you already posted

    /// The gap this closes: `publishActions` only ever publishes an UNSTAMPED workout, so before
    /// `markEdited` existed every edit to an already-published post — a rename, a photo attached
    /// days later, a new caption — stayed on the device forever.
    @Test func editingAPublishedPostQueuesItForRepublish() {
        let w = run(.public); w.postPublishedAt = Date(); w.syncedAt = Date()
        SocialSyncEngine.markEdited(w)
        #expect(w.syncedAt == nil)
        #expect(w.postPublishedAt == nil, "a shared post must go back in the publish queue")
        #expect(SocialSyncEngine.publishActions([w]).publish.map(\.id) == [w.id])
    }

    /// The privacy bug inside the same gap: narrowing Everyone → Friends leaves the workout SHARED,
    /// so the stamp survived, the sweep saw nothing to do, and the server kept serving the post at
    /// its old audience. The re-publish upserts the row with the new visibility.
    @Test func narrowingTheAudienceRepublishesRatherThanDoingNothing() {
        let w = run(.public); w.postPublishedAt = Date()
        w.privacy = .friends
        SocialSyncEngine.markEdited(w)
        let actions = SocialSyncEngine.publishActions([w])
        #expect(actions.publish.map(\.id) == [w.id])
        #expect(actions.unpublish.isEmpty)
        #expect(SocialSyncEngine.postDTO(for: w, profile: profile())?.visibility == "friends")
    }

    /// ⚠️ The one case that must NOT clear the stamp. Going private is a DELETE, and the stamp is
    /// the only record that a server post exists to delete — clearing it here would strand the post
    /// online with nothing left to reconcile it.
    @Test func goingPrivateKeepsItsStampSoTheSweepCanDeleteThePost() {
        let w = run(.public); w.postPublishedAt = Date()
        w.privacy = .private
        SocialSyncEngine.markEdited(w)
        #expect(w.postPublishedAt != nil, "the unpublish path needs this stamp")
        let actions = SocialSyncEngine.publishActions([w])
        #expect(actions.unpublish.map(\.id) == [w.id])
        #expect(actions.publish.isEmpty)
    }

    /// A private workout has no post; editing it must not invent one, only re-sync the backup.
    @Test func editingAPrivateWorkoutPublishesNothing() {
        let w = run(.private); w.syncedAt = Date()
        SocialSyncEngine.markEdited(w)
        #expect(w.syncedAt == nil)
        let actions = SocialSyncEngine.publishActions([w])
        #expect(actions.publish.isEmpty)
        #expect(actions.unpublish.isEmpty)
    }

    // MARK: feedItem — remote rows render through the same card

    @Test func feedRowMapsToFeedItem() {
        var row = SocialSyncEngine.FeedRow(
            id: UUID(), authorId: UUID(), authorName: "Maya", authorHandle: "maya",
            authorLocation: "Austin, TX", avatarPath: nil, workoutType: "run",
            startedAt: Date(), title: "Tempo", caption: "Negative split.",
            statLine: "5.0 mi · 40:00", prBadge: nil, muscles: ["chest": 0.5, "not-a-muscle": 1],
            route: [[37.0, -122.0], [37.1, -122.0]], mapStyle: "standard", aiRead: nil,
            photoPaths: [], reactionCount: 5, viewerReacted: true, createdAt: Date())
        row.coverIsPhoto = true
        let item = SocialSyncEngine.feedItem(from: row, photos: [], avatar: nil)
        #expect(item.isCommunity == false)                 // a real athlete, never badged
        #expect(item.baseReactions == 4)                   // server count minus the viewer's own
        #expect(item.type == .run)
        #expect(item.muscles == [.chest: 0.5])             // unknown muscle keys dropped
        #expect(item.routeLatLon?.count == 2)
        #expect(item.authorHandle == "maya")
        #expect(item.coverIsPhoto == true)
    }

    @Test func feedRowSingletonRouteDropsToNil() {
        let row = SocialSyncEngine.FeedRow(
            id: UUID(), authorId: UUID(), authorName: "A", authorHandle: nil,
            authorLocation: nil, avatarPath: nil, workoutType: "run", startedAt: Date(),
            title: "Run", caption: nil, statLine: "", prBadge: nil, muscles: nil,
            route: [[37.0, -122.0]], mapStyle: "bogus-style", aiRead: nil, photoPaths: [],
            reactionCount: 0, viewerReacted: false, createdAt: Date())
        let item = SocialSyncEngine.feedItem(from: row, photos: [], avatar: nil)
        #expect(item.routeLatLon == nil)                   // not drawable → glyph media
        #expect(item.mapStyle == .standard)                // unknown style falls back
    }

    @Test func malformedFeedRouteIsSanitizedAtTheNetworkBoundary() {
        let row = SocialSyncEngine.FeedRow(
            id: UUID(), authorId: UUID(), authorName: "A", authorHandle: nil,
            authorLocation: nil, avatarPath: nil, workoutType: "run", startedAt: Date(),
            title: "Run", caption: nil, statLine: "", prBadge: nil, muscles: nil,
            route: [[], [37], [Double.nan, -122], [37, -122], [37, -122], [37.1, -122.1]],
            mapStyle: "standard", aiRead: nil, photoPaths: [], reactionCount: 0,
            viewerReacted: false, createdAt: Date())

        let item = SocialSyncEngine.feedItem(from: row, photos: [], avatar: nil)

        #expect(item.routeLatLon == [[37, -122], [37.1, -122.1]])
        #expect(item.hasRenderableRoute)
    }

    // MARK: profileDTO — redaction

    @Test func profileLocationHonorsGranularity() {
        let p = profile(); p.city = "Austin, TX"
        p.locationGranularity = LocationGranularity.off.rawValue
        #expect(SocialSyncEngine.profileDTO(for: p).publicLocation == nil)   // raw city never uploads
        p.locationGranularity = LocationGranularity.city.rawValue
        #expect(SocialSyncEngine.profileDTO(for: p).publicLocation == "Austin, TX")
    }

    @Test func profileHandleIsNormalized() {
        let p = profile(); p.handle = "Test Athlete!"
        #expect(SocialSyncEngine.profileDTO(for: p).handle == "testathlete")
    }
}

/// End-trimming: precise start/finish never leave the device on a shared route.
struct RouteTrimmerTests {

    /// A straight north-going path with ~111 m between points.
    private func path(_ points: Int) -> [[Double]] {
        (0..<points).map { [37.0 + Double($0) * 0.001, -122.0] }
    }

    @Test func trimsRoughlyTheRequestedMetersFromEachEnd() {
        let trimmed = try! #require(RouteTrimmer.trimmed(path(30), trimM: 200))
        // 200 m ≈ 2 points at 111 m spacing → first/last ~2 points gone from each end.
        #expect(trimmed.count <= 27 && trimmed.count >= 25)
        #expect(trimmed.first![0] >= 37.002 - 0.0001)
        #expect(trimmed.last![0] <= 37.027 + 0.0001)
    }

    @Test func shortLoopIsNeverShared() {
        // ~440 m total < 2.5 × 200 m — trimming both ends would still reveal the whole circuit.
        #expect(RouteTrimmer.trimmed(path(5), trimM: 200) == nil)
    }

    @Test func nilAndTrivialPathsStayNil() {
        #expect(RouteTrimmer.trimmed(nil) == nil)
        #expect(RouteTrimmer.trimmed([[37.0, -122.0]]) == nil)
    }

    @Test func haversineIsSane() {
        // One degree of latitude ≈ 111.19 km.
        let d = RouteTrimmer.meters([37.0, -122.0], [38.0, -122.0])
        #expect(abs(d - 111_190) < 500)
    }
}
