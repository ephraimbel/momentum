import SwiftUI
import AuthenticationServices

/// The login gate (PRD §8.11) — Sign in with Apple only, for now. Brand-forward and quiet: the
/// glowing orb, the wordmark, the one-liner, and the system sign-in button.
struct SignInView: View {
    @Environment(AuthController.self) private var auth
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer()
            IridescentOrb(size: 132)
            VStack(spacing: Theme.Space.sm) {
                Text("momentum").font(.display(40, weight: .bold)).foregroundStyle(Theme.ink)
                Text("keep moving").font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            VStack(spacing: Theme.Space.md) {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    if case .success(let authResult) = result,
                       let credential = authResult.credential as? ASAuthorizationAppleIDCredential {
                        auth.signIn(userID: credential.user, fullName: credential.fullName, email: credential.email)
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))

                Text("No passwords. Private by default — your training stays yours.")
                    .font(.rounded(Theme.FontSize.label, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}

#Preview {
    SignInView().environment(AuthController(userID: nil))
}
