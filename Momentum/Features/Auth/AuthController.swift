import SwiftUI
import AuthenticationServices
import CryptoKit
import Supabase
import os

/// Auth-flow breadcrumbs (deep links especially) — a dropped callback is invisible without them.
private let authLog = Logger(subsystem: "com.ephraimbel.momentum.app", category: "auth")

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
    /// The last REAL account (Apple/Google/email) whose local data lives on this device. Survives a
    /// plain sign-out (unlike `userIDKey`) so a DIFFERENT account signing in on a shared/hand-me-down
    /// device is detected and the prior owner's SwiftData wiped — see `noteRealSignIn`.
    private static let lastRealUserIDKey = "com.momentum.auth.lastRealUserID"

    /// The raw nonce for the in-flight Apple request. Apple gets its SHA-256 hash; Supabase gets
    /// the raw value — the pair is how the identity token is bound to this one request.
    private var pendingRawNonce: String?

    /// Fired once, on the very first Supabase session this install ever gets — the hook that
    /// claims guest-era local data (re-marks workouts dirty so they upload under the new uid).
    var onFirstCloudSession: (() -> Void)?

    /// Fired when a DIFFERENT real account signs in on a device that still holds a prior real
    /// account's local data (shared/hand-me-down device). The host wipes local SwiftData so the new
    /// person starts on a clean slate + re-onboards; guest→real upgrade and first sign-in never fire it.
    var onAccountSwitch: (() -> Void)?

    /// Record a real-account sign-in and, if it differs from the account whose data is on this device,
    /// fire `onAccountSwitch` (wipe + re-onboard). First-ever sign-in (`prior == nil`) and a guest
    /// upgrade (guests never write `lastRealUserIDKey`) both carry local data over, as intended.
    private func noteRealSignIn(_ incoming: String) {
        let prior = UserDefaults.standard.string(forKey: Self.lastRealUserIDKey)
        UserDefaults.standard.set(incoming, forKey: Self.lastRealUserIDKey)
        guard let prior, prior != incoming else { return }
        UserDefaults.standard.removeObject(forKey: Self.cloudSessionKey)   // new account = a fresh cloud claim
        onAccountSwitch?()
    }

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
        // Auth-flow UI tests: start signed OUT with a clean slate — local identity, the
        // first-cloud-session marker, and any lingering keychain Supabase session all cleared.
        if ProcessInfo.processInfo.arguments.contains("--reset-auth") {
            UserDefaults.standard.removeObject(forKey: Self.userIDKey)
            UserDefaults.standard.removeObject(forKey: Self.nameKey)
            UserDefaults.standard.removeObject(forKey: Self.emailKey)
            UserDefaults.standard.removeObject(forKey: Self.cloudSessionKey)
            UserDefaults.standard.removeObject(forKey: Self.lastRealUserIDKey)
            if let client = SupabaseClientProvider.client { Task { try? await client.auth.signOut() } }
            return
        }
        // Demos + UI tests skip the gate so seeded flows run straight to the app.
        // `--onboarding` also signs in (without seeding a profile) so the onboarding flow can be
        // presented over a clean no-profile state — no tabs render behind it, no map location prompt.
        if ProcessInfo.processInfo.arguments.contains("--seed-demo")
            || ProcessInfo.processInfo.arguments.contains("--seed-empty")
            || ProcessInfo.processInfo.arguments.contains("--onboarding") {
            userID = "demo-user"; displayName = "Alex Rivera"; return   // matches the seeded demo profile
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
        noteRealSignIn(userID)   // wipe + re-onboard if a DIFFERENT account owned this device's data
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
            let gid = "google:\(session.user.id.uuidString)"
            noteRealSignIn(gid)
            userID = gid
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

    // MARK: Email + password (the classic boxes on the sign-in page)

    /// Plain-words error for the gate's inline message; nil = success.
    enum EmailAuthOutcome: Equatable {
        case success
        case failure(String)
    }

    /// Sign IN with email + password. The @handle stays the social username — email is only
    /// how the account authenticates (standard social-app split).
    func signInWithEmail(_ email: String, password: String) async -> EmailAuthOutcome {
        guard let client = SupabaseClientProvider.client else {
            return .failure("Sign-in isn't available offline.")
        }
        do {
            let session = try await client.auth.signIn(email: email, password: password)
            adoptEmailSession(session)
            return .success
        } catch {
            let text = (error as? AuthError)?.message ?? ""
            if text.localizedCaseInsensitiveContains("not confirmed") {
                return .failure("Confirm your email first — check your inbox for the link we sent.")
            }
            return .failure("That email and password don't match an account.")
        }
    }

    /// Sign UP with email + password. With confirmations on (launch config) the account exists
    /// but has no session until they tap the emailed link — which deep-links back here via
    /// momentum://auth-callback and `handleAuthCallback` signs them in.
    func signUpWithEmail(_ email: String, password: String) async -> EmailAuthOutcome {
        guard let client = SupabaseClientProvider.client else {
            return .failure("Sign-up isn't available offline.")
        }
        do {
            let response = try await client.auth.signUp(
                email: email, password: password,
                redirectTo: URL(string: "momentum://auth-callback"))
            guard case .session(let session) = response else {
                // Confirmations are on: the session arrives via the emailed link instead.
                return .failure("Almost there — tap the link we just emailed you and you're in.")
            }
            adoptEmailSession(session)
            return .success
        } catch {
            let text = (error as? AuthError)?.message ?? ""
            if text.localizedCaseInsensitiveContains("already registered") {
                return .failure("That email already has an account — sign in instead.")
            }
            if text.localizedCaseInsensitiveContains("rate limit") {
                // The mailer's hourly cap (tight until custom SMTP lands) — be honest about it.
                return .failure("Too many sign-ups right now — give it a while and try again.")
            }
            if text.localizedCaseInsensitiveContains("password") {
                return .failure("Passwords need at least 8 characters.")
            }
            return .failure("Couldn't create the account — check the email and try again.")
        }
    }

    /// Send the password-reset email. The link comes back into the app via momentum://auth-callback,
    /// which signs them in and prompts for a new password (see `handleAuthCallback`).
    func sendPasswordReset(to email: String) async -> Bool {
        guard let client = SupabaseClientProvider.client, !email.isEmpty else { return false }
        do {
            try await client.auth.resetPasswordForEmail(email, redirectTo: URL(string: "momentum://auth-callback"))
            return true
        } catch { return false }
    }

    /// True while a reset-link session wants a new password — RootView presents the sheet.
    var needsNewPassword = false

    /// Handle the momentum://auth-callback deep link — email-confirmation and password-reset
    /// links land here (the OAuth sheet handles its own callback internally). Creates the
    /// session and, for recovery links, raises the set-new-password prompt.
    func handleAuthCallback(_ url: URL) {
        guard let client = SupabaseClientProvider.client,
              url.absoluteString.contains("auth-callback") else { return }
        authLog.info("auth callback received (fragment: \(url.fragment != nil, privacy: .public))")
        Task {
            var session: Session?
            do {
                session = try await client.auth.session(from: url)
            } catch {
                authLog.info("session(from:) rejected the callback: \(error, privacy: .public)")
            }
            if session == nil, let (access, refresh) = Self.fragmentTokens(in: url) {
                // GoTrue's /verify redirects with implicit-style fragment tokens; a PKCE-flow
                // client rejects those in `session(from:)` — adopt them directly instead.
                do {
                    session = try await client.auth.setSession(accessToken: access, refreshToken: refresh)
                } catch {
                    authLog.error("setSession(fragment tokens) failed: \(error, privacy: .public)")
                }
            }
            guard let session else {
                authLog.error("auth callback yielded no session — link ignored")
                return
            }
            authLog.info("auth callback adopted a session")
            adoptEmailSession(session)
            if url.absoluteString.contains("type=recovery") { needsNewPassword = true }
        }
    }

    /// `#access_token=…&refresh_token=…` out of a verify-redirect URL, or nil.
    private static func fragmentTokens(in url: URL) -> (access: String, refresh: String)? {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment else { return nil }
        var params: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            params[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
        }
        guard let access = params["access_token"], let refresh = params["refresh_token"] else { return nil }
        return (access, refresh)
    }

    /// Set a new password on the live session (the reset sheet's save).
    func updatePassword(_ password: String) async -> Bool {
        guard let client = SupabaseClientProvider.client else { return false }
        do {
            _ = try await client.auth.update(user: UserAttributes(password: password))
            return true
        } catch { return false }
    }

    /// Permanently delete the account server-side (App Store 5.1.1(v)): photos and avatar via
    /// the Storage API (SQL deletes on storage are forbidden), then one RPC whose auth.users
    /// delete cascades through every table — workouts, profile, posts, follows, comments —
    /// and frees the @handle. Local data stays on this device (offline-first: the athlete
    /// keeps their history, like a guest). Returns false with the account untouched on failure.
    func deleteAccount() async -> Bool {
        guard let client = SupabaseClientProvider.client,
              let session = try? await client.auth.session else { return false }
        let uid = session.user.id.uuidString.lowercased()
        // Best-effort blob removal as the owner. Post photos live at {uid}/{postId}/n.jpg —
        // a fixed two-level walk. Failures here don't block the delete: once the account row
        // is gone, every storage policy resolves false and the blobs are unreachable.
        _ = try? await client.storage.from("avatars").remove(paths: ["\(uid)/avatar.jpg"])
        if let folders = try? await client.storage.from("post-photos").list(path: uid) {
            for folder in folders {
                if let files = try? await client.storage.from("post-photos").list(path: "\(uid)/\(folder.name)"),
                   !files.isEmpty {
                    _ = try? await client.storage.from("post-photos")
                        .remove(paths: files.map { "\(uid)/\(folder.name)/\($0.name)" })
                }
            }
        }
        do {
            try await client.rpc("delete_my_account").execute()
        } catch {
            authLog.error("deleteAccount RPC failed: \(error, privacy: .public)")
            return false
        }
        authLog.info("account deleted server-side")
        signOut()   // the server session is already void; this clears the local identity
        // A future account on this device is a genuine first cloud session again — the
        // re-mark/re-claim hook must refire for it. Clearing the last-real-account marker keeps the
        // documented "local data stays, like a guest" behavior: the next sign-in carries it over
        // rather than wiping (account switch only wipes when a DIFFERENT account signs in mid-life).
        UserDefaults.standard.removeObject(forKey: Self.cloudSessionKey)
        UserDefaults.standard.removeObject(forKey: Self.lastRealUserIDKey)
        return true
    }

    /// Persist local identity off a Supabase email session (mirrors the Google path: prefixed id
    /// so `refresh()` skips the Apple credential check).
    private func adoptEmailSession(_ session: Session) {
        let eid = "email:\(session.user.id.uuidString)"
        noteRealSignIn(eid)
        userID = eid
        UserDefaults.standard.set(userID, forKey: Self.userIDKey)
        if let mail = session.user.email, !mail.isEmpty {
            self.email = mail
            UserDefaults.standard.set(mail, forKey: Self.emailKey)
        }
        markCloudSession()
        Haptics.success()
    }

    /// On launch, confirm the Apple credential is still valid; sign out if it was revoked. Skips the
    /// demo + guest + Google/email sessions, which have no Apple credential to validate. Also
    /// restores the Supabase session from the Keychain (refreshing the JWT if stale) so RLS'd calls
    /// work from cold launch.
    func refresh() {
        guard let userID, userID != "demo-user", userID != Self.guestID else { return }
        if let client = SupabaseClientProvider.client {
            Task { [weak self] in
                if (try? await client.auth.session) != nil { await self?.markCloudSession() }
            }
        }
        guard !userID.hasPrefix("google:"), !userID.hasPrefix("email:") else { return }   // Keychain sessions
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
