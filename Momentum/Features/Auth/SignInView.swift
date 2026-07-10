import SwiftUI
import AuthenticationServices

/// The welcome gate (PRD §8.11) — a full-bleed athletic photo with the white wordmark + tagline
/// centered over it. "Get started" stays the primary path (straight into onboarding as a guest);
/// athletes with an account sign in with Apple or Google right here (Apple must accompany any
/// third-party sign-in — App Store 4.8; Google runs through the Supabase OAuth web sheet).
struct SignInView: View {
    @Environment(AuthController.self) private var auth
    @State private var googleInFlight = false

    var body: some View {
        ZStack {
            // Full-bleed black-and-white hero. Clipped to a screen-sized layer so `scaledToFill`'s
            // overflow can't inflate the ZStack (which would push the button past the screen edges).
            Color.clear
                .overlay {
                    Image("WelcomeBackground")
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .ignoresSafeArea()
                .accessibilityHidden(true)

            // Scrim — clear at top (dark status bar reads over the bright sky), darkening toward the
            // bottom so the Get started button stays crisp.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.35),
                    .init(color: .black.opacity(0.35), location: 0.72),
                    .init(color: .black.opacity(0.85), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // Brand lockup, centered on the hero. A soft shadow keeps it legible over the photo.
            VStack(spacing: Theme.Space.sm) {
                Image("WordmarkWhite")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 40)   // fixed height; width follows the wordmark's aspect ratio
                    .accessibilityLabel("momentum")
                Text("keep moving")
                    .font(.serif(Theme.FontSize.body + 3, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .multilineTextAlignment(.center)
            }
            .shadow(color: .black.opacity(0.35), radius: 14, y: 2)

            // Primary: enter as a guest, straight into onboarding. Beneath it, the two account
            // paths for athletes who already have (or want) a synced identity.
            VStack(spacing: Theme.Space.sm) {
                Spacer()
                Button {
                    Haptics.light()
                    auth.continueAsGuest()
                } label: {
                    Text("Get started")
                        .font(.rounded(Theme.FontSize.body, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(.white))
                }
                .buttonStyle(.plain)

                Text("or sign in")
                    .font(.rounded(Theme.FontSize.label, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 2)

                SignInWithAppleButton(.signIn) { request in
                    auth.prepareAppleSignIn(request)
                } onCompletion: { result in
                    if case .success(let authResult) = result,
                       let credential = authResult.credential as? ASAuthorizationAppleIDCredential {
                        auth.signIn(credential: credential)
                    }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

                Button {
                    guard !googleInFlight else { return }
                    Haptics.light()
                    googleInFlight = true
                    Task {
                        _ = await auth.signInWithGoogle()
                        googleInFlight = false
                    }
                } label: {
                    HStack(spacing: Theme.Space.sm) {
                        if googleInFlight {
                            ProgressView().tint(.black)
                        } else {
                            Text("G")
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                                .foregroundStyle(.black)
                        }
                        Text("Continue with Google")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.black)
                    }
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(.white))
                }
                .buttonStyle(.plain)
                .disabled(googleInFlight)
                .accessibilityLabel("Continue with Google")
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xl)
        }
    }
}

#Preview {
    SignInView().environment(AuthController(userID: nil))
}
