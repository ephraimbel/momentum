import Testing
import Foundation
@testable import Momentum

/// The guest → real-account identity state machine (AuthController) — the rules that decide
/// whether local SwiftData **carries over** (guest upgrade, first sign-in, same account returning)
/// or is **wiped** (a DIFFERENT real account signing in on a shared/hand-me-down device).
/// These rules are the backbone of "Continue without an account": a guest must be able to sign
/// in later and keep everything they logged, while a stranger's sign-in must never inherit it.
///
/// Serialized: every case mutates the same `UserDefaults.standard` keys the controller persists to.
@MainActor
@Suite(.serialized)
struct GuestFlowStateTests {

    /// The controller's persistence keys (mirrored — they're private in AuthController).
    private static let keys = [
        "com.momentum.auth.userID",
        "com.momentum.auth.name",
        "com.momentum.auth.email",
        "com.momentum.auth.hadCloudSession",
        "com.momentum.auth.lastRealUserID",
    ]

    /// Start every test from a signed-out-with-no-history device.
    private func freshDefaults() {
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    // ── Guest creation ───────────────────────────────────────────────────────────

    // ── Billing identity ─────────────────────────────────────────────────────────

    /// `onIdentityChange` is what links the RevenueCat customer to the account. Every path that
    /// assigns `userID` has to fire it: miss one and that provider's athletes silently keep an
    /// anonymous customer, so a reinstall reads as a new purchaser and revenue can't be joined to a
    /// user. Apple and sign-out are covered here; Google/email go through Supabase and can't be
    /// driven from a unit test, so the invariant is documented on the property itself.
    @Test func appleSignInAndSignOutReportTheBillingIdentity() {
        freshDefaults()
        let auth = AuthController(userID: nil)
        var reported: [String?] = []
        auth.onIdentityChange = { reported.append($0) }

        auth.signIn(userID: "apple-user-1", fullName: nil, email: nil)
        #expect(reported == ["apple-user-1"])

        auth.signOut()
        #expect(reported == ["apple-user-1", nil])   // released back to an anonymous customer
    }

    /// A guest is not a billing identity — they must stay anonymous, not be linked under the
    /// shared guest sentinel, which would pool every guest on this device into one RC customer.
    @Test func guestDoesNotBecomeABillingIdentity() {
        freshDefaults()
        let auth = AuthController(userID: nil)
        var reported: [String?] = []
        auth.onIdentityChange = { reported.append($0) }

        auth.continueAsGuest()
        #expect(reported.allSatisfy { $0 == nil })
    }

    @Test func guestEntryCreatesPersistedLocalIdentity() {
        freshDefaults()
        let auth = AuthController(userID: nil)
        #expect(!auth.isSignedIn)

        auth.continueAsGuest()

        #expect(auth.isSignedIn, "guest is past the gate")
        #expect(auth.isGuest)
        #expect(auth.userID == AuthController.guestID)
        #expect(auth.displayName == nil)
        // Persisted: a relaunch restores the guest session (no re-gate).
        let relaunched = AuthController(userID: nil)
        #expect(relaunched.isGuest, "guest session must survive relaunch")
        // Guests must NOT be recorded as the device's real account — that record is what
        // triggers the wipe for a different account, and a guest has no claim to it.
        #expect(UserDefaults.standard.string(forKey: "com.momentum.auth.lastRealUserID") == nil)
    }

    // ── Carry-over paths (no wipe) ───────────────────────────────────────────────

    @Test func guestUpgradeCarriesDataOver() {
        freshDefaults()
        let auth = AuthController(userID: nil)
        auth.continueAsGuest()

        var wiped = false
        auth.onAccountSwitch = { wiped = true }
        auth.signIn(userID: "apple-user-A", fullName: nil, email: "a@example.com")

        #expect(!wiped, "guest → real upgrade must NOT wipe local data")
        #expect(!auth.isGuest)
        #expect(auth.userID == "apple-user-A")
        #expect(UserDefaults.standard.string(forKey: "com.momentum.auth.lastRealUserID") == "apple-user-A")
    }

    @Test func firstEverSignInCarriesDataOver() {
        freshDefaults()
        let auth = AuthController(userID: nil)
        var wiped = false
        auth.onAccountSwitch = { wiped = true }

        auth.signIn(userID: "apple-user-A", fullName: nil, email: nil)

        #expect(!wiped, "first-ever sign-in on a device carries local data over")
    }

    @Test func sameAccountReturningCarriesDataOver() {
        freshDefaults()
        let auth = AuthController(userID: nil)
        auth.signIn(userID: "apple-user-A", fullName: nil, email: nil)
        auth.signOut()
        #expect(!auth.isSignedIn)
        // The device remembers whose data it holds even after sign-out (load-bearing).
        #expect(UserDefaults.standard.string(forKey: "com.momentum.auth.lastRealUserID") == "apple-user-A")

        var wiped = false
        auth.onAccountSwitch = { wiped = true }
        auth.signIn(userID: "apple-user-A", fullName: nil, email: nil)

        #expect(!wiped, "the same account signing back in keeps its own data")
    }

    // ── The welcome's "Get started" (2026-07-27: setup runs before the account) ───

    /// The load-bearing one. Since the account moved to the LAST beat of onboarding, the athlete
    /// signs in *after* building a profile and plan — so `noteRealSignIn` runs with five minutes of
    /// their work already on disk. If a prior owner's claim were still on the device, that sign-in
    /// would read as an account switch and delete everything they just made. "Get started" releases
    /// the claim up front, when there is nothing to lose.
    @Test func freshStartReleasesPriorOwnershipSoTheFinalSignInNeverWipes() {
        freshDefaults()
        let auth = AuthController(userID: nil)
        auth.signIn(userID: "apple-user-A", fullName: nil, email: nil)
        auth.signOut()
        #expect(UserDefaults.standard.string(forKey: "com.momentum.auth.lastRealUserID") == "apple-user-A")

        auth.beginFreshLocalSession()
        #expect(auth.isGuest, "setup runs local-only")
        #expect(UserDefaults.standard.string(forKey: "com.momentum.auth.lastRealUserID") == nil,
                "the prior owner's claim is released at Get started")

        var wiped = false
        auth.onAccountSwitch = { wiped = true }
        auth.signIn(userID: "apple-user-B", fullName: nil, email: nil)

        #expect(!wiped, "signing in on the LAST beat must never delete the plan just built")
        #expect(auth.userID == "apple-user-B")
    }

    /// The structural guarantee behind the reorder. The account beat sits at the END of onboarding,
    /// so a sign-in there lands with a brand-new profile and plan already on disk. It must never be
    /// read as a hand-me-down account switch — that wipe would delete everything the athlete just
    /// built and drop them into the app as a nameless "Athlete" with no plan.
    ///
    /// This must hold for EVERY route into setup, not just "Get started" — the account page's
    /// "Continue without an account" is a second one — so the guard is the flow being on screen,
    /// not the door they came through.
    @Test func signingInDuringOnboardingNeverWipesTheProfileJustBuilt() {
        freshDefaults()
        let auth = AuthController(userID: nil)
        auth.signIn(userID: "apple-user-A", fullName: nil, email: nil)
        auth.signOut()
        auth.continueAsGuest()          // the account page's guest door — does NOT release the claim
        auth.isOnboarding = true        // …and setup is now on screen, building a profile

        var wiped = false
        auth.onAccountSwitch = { wiped = true }
        auth.signIn(userID: "apple-user-B", fullName: nil, email: nil)

        #expect(!wiped, "the plan built during setup must survive the sign-in that ends it")
        #expect(auth.userID == "apple-user-B")
        // The claim still transfers, so a genuine switch LATER (from Settings) still wipes.
        #expect(UserDefaults.standard.string(forKey: "com.momentum.auth.lastRealUserID") == "apple-user-B")
        // …and account B's data is treated as a fresh cloud claim, so it actually uploads.
        #expect(!UserDefaults.standard.bool(forKey: "com.momentum.auth.hadCloudSession"))
    }

    /// The suppression is scoped to the flow: once onboarding is off screen, a different account
    /// signing in on a shared device still wipes.
    @Test func wipeResumesOnceOnboardingIsOffScreen() {
        freshDefaults()
        let auth = AuthController(userID: nil)
        auth.signIn(userID: "apple-user-A", fullName: nil, email: nil)
        auth.signOut()
        auth.isOnboarding = true
        auth.isOnboarding = false       // setup finished

        var wiped = false
        auth.onAccountSwitch = { wiped = true }
        auth.signIn(userID: "apple-user-B", fullName: nil, email: nil)

        #expect(wiped, "a different account on a shared device must still start from a clean slate")
    }

    /// A fresh start also re-arms the cloud claim, so the account beat's sign-in re-marks local
    /// data dirty and uploads what was logged as a guest (`onFirstCloudSession`).
    @Test func freshStartReArmsTheCloudClaim() {
        freshDefaults()
        UserDefaults.standard.set(true, forKey: "com.momentum.auth.hadCloudSession")
        let auth = AuthController(userID: nil)

        auth.beginFreshLocalSession()

        #expect(!UserDefaults.standard.bool(forKey: "com.momentum.auth.hadCloudSession"))
    }

    /// It is also a guest entry, so it must not become a billing identity or claim the device.
    @Test func freshStartOnACleanDeviceIsJustAGuest() {
        freshDefaults()
        let auth = AuthController(userID: nil)
        var reported: [String?] = []
        auth.onIdentityChange = { reported.append($0) }

        auth.beginFreshLocalSession()

        #expect(auth.isGuest)
        #expect(reported.allSatisfy { $0 == nil })
        #expect(UserDefaults.standard.string(forKey: "com.momentum.auth.lastRealUserID") == nil)
        // Persisted, so a relaunch mid-onboarding resumes instead of re-showing the welcome.
        #expect(AuthController(userID: nil).isGuest)
    }

    // ── Wipe paths (different real account) ──────────────────────────────────────

    @Test func differentAccountSignInWipes() {
        freshDefaults()
        let auth = AuthController(userID: nil)
        auth.signIn(userID: "apple-user-A", fullName: nil, email: nil)
        auth.signOut()

        var wiped = false
        auth.onAccountSwitch = { wiped = true }
        auth.signIn(userID: "apple-user-B", fullName: nil, email: nil)

        #expect(wiped, "a DIFFERENT account on a shared device must start from a clean slate")
        #expect(UserDefaults.standard.string(forKey: "com.momentum.auth.lastRealUserID") == "apple-user-B")
    }

    @Test func guestInterludeDoesNotMaskAccountSwitch() {
        freshDefaults()
        let auth = AuthController(userID: nil)
        auth.signIn(userID: "apple-user-A", fullName: nil, email: nil)
        auth.signOut()
        auth.continueAsGuest()   // hand-me-down device used account-less for a while

        var wiped = false
        auth.onAccountSwitch = { wiped = true }
        auth.signIn(userID: "apple-user-B", fullName: nil, email: nil)

        #expect(wiped, "a guest interlude must not defeat the different-account wipe")
    }

    @Test func accountSwitchResetsCloudClaimMarker() {
        freshDefaults()
        UserDefaults.standard.set(true, forKey: "com.momentum.auth.hadCloudSession")   // A already claimed
        let auth = AuthController(userID: nil)
        auth.signIn(userID: "apple-user-A", fullName: nil, email: nil)
        auth.signOut()

        auth.signIn(userID: "apple-user-B", fullName: nil, email: nil)

        #expect(!UserDefaults.standard.bool(forKey: "com.momentum.auth.hadCloudSession"),
                "account B's first cloud session must re-fire the claim hook (re-mark + re-upload)")
    }
}
