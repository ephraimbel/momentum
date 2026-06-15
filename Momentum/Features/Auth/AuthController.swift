import SwiftUI
import AuthenticationServices

/// Sign in with Apple session (PRD §8.11) — the app's identity for now. Holds the stable Apple user
/// identifier (persisted) and the athlete's name (Apple only hands it over on the *first*
/// authorization, so we keep it). No passwords; private by default. The Supabase session/JWT for
/// owner-scoped cloud sync layers on top of this later (see docs/SYNC-SETUP.md).
@MainActor
@Observable
final class AuthController {
    private static let userIDKey = "com.momentum.auth.userID"
    private static let nameKey = "com.momentum.auth.name"

    private(set) var userID: String?
    private(set) var displayName: String?

    var isSignedIn: Bool { userID != nil }

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
    }

    /// Persist a successful Apple sign-in. `fullName` arrives only on the first authorization.
    func signIn(userID: String, fullName: PersonNameComponents?, email: String?) {
        self.userID = userID
        UserDefaults.standard.set(userID, forKey: Self.userIDKey)
        if let fullName, let formatted = Self.format(fullName) {
            displayName = formatted
            UserDefaults.standard.set(formatted, forKey: Self.nameKey)
        }
        Haptics.success()
    }

    func signOut() {
        userID = nil
        displayName = nil
        UserDefaults.standard.removeObject(forKey: Self.userIDKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
    }

    /// On launch, confirm the Apple credential is still valid; sign out if it was revoked.
    func refresh() {
        guard let userID, userID != "demo-user" else { return }
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
