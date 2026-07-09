import SwiftUI
import AuthenticationServices

/// The welcome gate (PRD §8.11) — a full-bleed athletic photo with the white wordmark + tagline
/// centered over it, and a single "Get started" that drops the athlete straight into onboarding
/// (as a guest — Sign in with Apple is offered at the end of onboarding, once there's a plan to save).
struct SignInView: View {
    @Environment(AuthController.self) private var auth

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

            // The only CTA — enters as a guest and goes straight into onboarding.
            VStack {
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
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xxl)
        }
    }
}

#Preview {
    SignInView().environment(AuthController(userID: nil))
}
