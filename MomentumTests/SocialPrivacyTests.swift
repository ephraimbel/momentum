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

    /// The output must always satisfy the server's `^[a-z0-9_]{0,20}$` constraint — accented
    /// letters fold to ASCII instead of slipping through as "valid" handles the claim rejects.
    @Test func handleNormalizationFoldsToASCII() {
        #expect(SocialPrivacy.normalizedHandle("José") == "jose")
        #expect(SocialPrivacy.normalizedHandle("Åsa Öström") == "asaostrom")
        #expect(SocialPrivacy.normalizedHandle("François") == "francois")
        for raw in ["José", "Müller_99", "Zoë 🏃", "日本語"] {
            let normalized = SocialPrivacy.normalizedHandle(raw)
            #expect(normalized.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
            })
        }
    }

    /// The reserved list mirrors the SQL migration — every entry must be self-normalized (or the
    /// client check could never match what a user can actually type).
    @Test func reservedHandlesAreEnforcedAndNormalized() {
        #expect(!SocialPrivacy.reservedHandles.isEmpty)
        #expect(SocialPrivacy.isReservedHandle("momentum"))
        #expect(SocialPrivacy.isReservedHandle("ADMIN"))          // case-insensitive
        #expect(!SocialPrivacy.isReservedHandle("maya_runs"))
        for reserved in SocialPrivacy.reservedHandles {
            #expect(SocialPrivacy.normalizedHandle(reserved) == reserved)
        }
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

    /// Routes ride shared posts by default (2026-08-06 — the old opt-in default had no UI and
    /// silently glyph'd every own post); opting out still hides them, and private never shows one.
    @Test func routeFollowsShareAndOptOut() {
        let p = UserProfile()
        let w = Workout(); w.privacy = .public
        #expect(SocialPrivacy.showsRoute(w, profile: p))             // shared → route, by default
        p.publicRouteMaps = false
        #expect(!SocialPrivacy.showsRoute(w, profile: p))            // opted out → hidden
        p.publicRouteMaps = true
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

    /// Filling the Edit Profile location field IS the opt-in; clearing it takes the location back
    /// off the wire; a coarser choice already made is never silently sharpened.
    @Test func typingALocationOptsInAtCityPrecision() {
        let off = LocationGranularity.off.rawValue
        #expect(SocialPrivacy.granularity(forCity: "Austin, TX", current: off) == .city)
        #expect(SocialPrivacy.granularity(forCity: "", current: LocationGranularity.city.rawValue) == .off)
        #expect(SocialPrivacy.granularity(forCity: "   ", current: LocationGranularity.city.rawValue) == .off)
        #expect(SocialPrivacy.granularity(forCity: "Austin, TX",
                                          current: LocationGranularity.region.rawValue) == .region)
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
