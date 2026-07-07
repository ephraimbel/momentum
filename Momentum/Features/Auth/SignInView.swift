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
            Image("BrandIcon")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 132, height: 132)
                .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Space.sm) {
                Image("WordmarkBlack")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 210)
                    .accessibilityLabel("momentum")
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

                // Try it now, commit later — local-only until they sign in (back up / sync / social).
                VStack(spacing: 4) {
                    Button { auth.continueAsGuest() } label: {
                        Text("Continue without an account")
                            .font(.rounded(Theme.FontSize.body, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background {
                                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
                            }
                    }
                    .buttonStyle(.plain)
                    Text("Saved on this device. Sign in anytime to back up & sync.")
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, Theme.Space.xs)
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
