import Testing
@testable import Momentum

/// Conservative-by-default social visibility rules (PRD §11, docs/SOCIAL-LAYER.md).
@MainActor
struct SocialPrivacyTests {

    @Test func handleNormalization() {
        #expect(SocialPrivacy.normalizedHandle("Ephraim B!") == "ephraimb")
        #expect(SocialPrivacy.normalizedHandle("  John_Doe-123 ") == "john_doe123")
        #expect(SocialPrivacy.normalizedHandle("RUN.fast 🏃") == "runfast")
        #expect(SocialPrivacy.normalizedHandle(String(repeating: "a", count: 40)).count == 20)
    }

    @Test func defaultsAreFullyPrivate() {
        let p = UserProfile()
        #expect(SocialPrivacy.defaultVisibility(p) == .private)
        #expect(!p.appearOnMap)
        #expect(!p.discoverable)
        #expect(SocialPrivacy.publicLocation(p) == nil)               // off by default
        #expect(SocialPrivacy.exposureSummary(p) == "Private — nothing is shared")
    }

    @Test func sharedWorkoutDetection() {
        let priv = Workout(); priv.privacy = .private
        let friends = Workout(); friends.privacy = .friends
        let pub = Workout(); pub.privacy = .public
        #expect(!SocialPrivacy.isShared(priv))
        #expect(SocialPrivacy.isShared(friends))
        #expect(SocialPrivacy.isShared(pub))
    }

    @Test func routeRequiresShareAndOptIn() {
        let p = UserProfile()
        let w = Workout(); w.privacy = .public
        #expect(!SocialPrivacy.showsRoute(w, profile: p))             // route maps off by default
        p.publicRouteMaps = true
        #expect(SocialPrivacy.showsRoute(w, profile: p))             // opted in + public → shown
        w.privacy = .private
        #expect(!SocialPrivacy.showsRoute(w, profile: p))            // private never shows route
    }

    @Test func locationHonorsGranularity() {
        let p = UserProfile(); p.city = "Austin"
        #expect(SocialPrivacy.publicLocation(p) == nil)              // granularity off
        p.locationGranularity = LocationGranularity.city.rawValue
        #expect(SocialPrivacy.publicLocation(p) == "Austin")
        p.city = "   "
        #expect(SocialPrivacy.publicLocation(p) == nil)             // empty city → nothing
    }

    @Test func exposureSummaryReflectsOptIns() {
        let p = UserProfile()
        p.defaultWorkoutVisibility = WorkoutPrivacy.public.rawValue
        p.appearOnMap = true
        let summary = SocialPrivacy.exposureSummary(p)
        #expect(summary.contains("everyone"))
        #expect(summary.contains("map"))
    }
}
