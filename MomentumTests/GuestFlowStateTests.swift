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
