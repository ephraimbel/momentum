import SwiftUI
import AuthenticationServices
import CryptoKit
import Supabase

/// Sign in with Apple session (PRD §8.11) — the app's identity. Holds the stable Apple user
/// identifier (persisted) and the athlete's name (Apple only hands it over on the *first*
/// authorization, so we keep it). No passwords; private by default. When Supabase is configured,
/// a successful Apple sign-in is bridged to a Supabase session (`signInWithIdToken`) whose JWT
/// satisfies owner-only RLS for sync/social (docs/SOCIAL-BACKEND-SETUP.md); guests and the
/// unconfigured app skip the bridge entirely and stay local-only.
@MainActor
@Observable
final class AuthController {
    private static let userIDKey = "com.momentum.auth.userID"
    private static let nameKey = "com.momentum.auth.name"
    private static let emailKey = "com.momentum.auth.email"
    private static let cloudSessionKey = "com.momentum.auth.hadCloudSession"

    /// The raw nonce for the in-flight Apple request. Apple gets its SHA-256 hash; Supabase gets
    /// the raw value — the pair is how the identity token is bound to this one request.
    private var pendingRawNonce: String?

    /// Fired once, on the very first Supabase session this install ever gets — the hook that
    /// claims guest-era local data (re-marks workouts dirty so they upload under the new uid).
    var onFirstCloudSession: (() -> Void)?

    /// Sentinel userID for a guest (account-less, local-only) session.
    static let guestID = "guest"

    private(set) var userID: String?
    private(set) var displayName: String?
    /// Sign-in email (Apple first-auth / Google) — feeds handle suggestions; never shown publicly.
    private(set) var email: String?

    /// The app is "in" (past the gate) when there's any userID — a real Apple id *or* the guest one.
    var isSignedIn: Bool { userID != nil }
    /// A guest has full local use but no cloud backup/sync/social until they sign in with Apple.
    var isGuest: Bool { userID == Self.guestID }

    init(userID override: String? = nil) {
        if let override { userID = override; return }
        #if DEBUG
        // Demos + UI tests skip the gate so seeded flows run straight to the app.
        if ProcessInfo.processInfo.arguments.contains("--seed-demo") {
            userID = "demo-user"; displayName = "Demo Athlete"; return
        }
        #endif
        userID = UserDefaults.standard.string(forKey: Self.userIDKey)
        displayName = UserDefaults.standard.string(forKey: Self.nameKey)
        email = UserDefaults.standard.string(forKey: Self.emailKey)
    }

    /// Persist a successful Apple sign-in. `fullName` arrives only on the first authorization.
    /// Note: when upgrading from a guest, the local SwiftData (profile, workouts, plan) is keyed to
    /// the device container — it carries over untouched, so no re-onboarding.
    func signIn(userID: String, fullName: PersonNameComponents?, email: String?) {
        self.userID = userID
        UserDefaults.standard.set(userID, forKey: Self.userIDKey)
        if let fullName, let formatted = Self.format(fullName) {
            displayName = formatted
            UserDefaults.standard.set(formatted, forKey: Self.nameKey)
        }
        if let email, !email.isEmpty {   // Apple hands this over on the FIRST authorization only
            self.email = email
            UserDefaults.standard.set(email, forKey: Self.emailKey)
        }
        Haptics.success()
    }

    // MARK: Supabase bridge (docs/SOCIAL-BACKEND-SETUP.md)

    /// Configure the in-flight Apple request: scopes + the SHA-256-hashed nonce (Supabase later
    /// verifies the raw one against the identity token). No-op nonce when unconfigured — plain
    /// local sign-in keeps working with no backend.
    func prepareAppleSignIn(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
        guard SupabaseClientProvider.isConfigured else { return }
        let raw = Self.randomNonce()
        pendingRawNonce = raw
        request.nonce = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Credential-based entry point: persists identity locally (exactly as before), then bridges
    /// the Apple identity token to a Supabase session so RLS'd sync/social light up.
    func signIn(credential: ASAuthorizationAppleIDCredential) {
        signIn(userID: credential.user, fullName: credential.fullName, email: credential.email)
        guard SupabaseClientProvider.isConfigured,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else { return }
        let rawNonce = pendingRawNonce
        pendingRawNonce = nil
        Task { await bridgeToSupabase(idToken: idToken, rawNonce: rawNonce) }
    }

    private func bridgeToSupabase(idToken: String, rawNonce: String?) async {
        guard let client = SupabaseClientProvider.client else { return }
        do {
            _ = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: rawNonce))
            markCloudSession()
        } catch {
            // Stay signed in locally; the bridge retries on the next explicit sign-in. Offline-first:
            // nothing in the app blocks on this.
        }
    }

    /// First-ever cloud session on this install → fire the guest-data claim hook exactly once.
    private func markCloudSession() {
        guard !UserDefaults.standard.bool(forKey: Self.cloudSessionKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.cloudSessionKey)
        onFirstCloudSession?()
    }

    /// A CSPRNG nonce string (hex) for the Apple↔Supabase token binding.
    private static func randomNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Enter the app without an account — local-only (no cloud backup/sync/social). The athlete can
    /// Sign in with Apple later from Settings and keep everything they've logged.
    func continueAsGuest() {
        userID = Self.guestID
        displayName = nil
        email = nil
        UserDefaults.standard.set(Self.guestID, forKey: Self.userIDKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        Haptics.success()
    }

    func signOut() {
        userID = nil
        displayName = nil
        email = nil
        UserDefaults.standard.removeObject(forKey: Self.userIDKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        if let client = SupabaseClientProvider.client {
            Task { try? await client.auth.signOut() }
        }
    }

    /// Google sign-in via the Supabase OAuth web sheet (ASWebAuthenticationSession — no Google
    /// SDK, per the third-party-dependency rules). The SDK opens the sheet, captures the
    /// `momentum://auth-callback` redirect, and persists the session in the Keychain. Returns
    /// false on cancel/offline/unconfigured — the gate simply stays put.
    func signInWithGoogle() async -> Bool {
        guard let client = SupabaseClientProvider.client else { return false }
        do {
            let session = try await client.auth.signInWithOAuth(
                provider: .google,
                redirectTo: URL(string: "momentum://auth-callback"))
            let name = session.user.userMetadata["full_name"]?.stringValue
                ?? session.user.userMetadata["name"]?.stringValue
            // No Apple id to key on — the Supabase user id (prefixed so `refresh()` knows not to
            // run the Apple credential check against it) becomes the local identity.
            userID = "google:\(session.user.id.uuidString)"
            UserDefaults.standard.set(userID, forKey: Self.userIDKey)
            if let name, !name.isEmpty {
                displayName = name
                UserDefaults.standard.set(name, forKey: Self.nameKey)
            }
            if let mail = session.user.email, !mail.isEmpty {
                email = mail
                UserDefaults.standard.set(mail, forKey: Self.emailKey)
            }
            markCloudSession()
            Haptics.success()
            return true
        } catch {
            return false   // user cancelled the sheet, offline, or provider not configured
        }
    }

    /// On launch, confirm the Apple credential is still valid; sign out if it was revoked. Skips the
    /// demo + guest + Google sessions, which have no Apple credential to validate. Also restores the
    /// Supabase session from the Keychain (refreshing the JWT if stale) so RLS'd calls work from
    /// cold launch.
    func refresh() {
        guard let userID, userID != "demo-user", userID != Self.guestID else { return }
        if let client = SupabaseClientProvider.client {
            Task { [weak self] in
                if (try? await client.auth.session) != nil { await self?.markCloudSession() }
            }
        }
        guard !userID.hasPrefix("google:") else { return }   // Google sessions live in the Keychain
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { [weak self] state, _ in
            guard state == .revoked || state == .notFound else { return }
            Task { @MainActor in self?.signOut() }
        }
    }

    private static func format(_ name: PersonNameComponents) -> String? {
        let formatter = PersonNameComponentsFormatter()
        let s = formatter.string(from: name).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
}
