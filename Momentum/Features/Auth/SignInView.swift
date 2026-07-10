import SwiftUI
import AuthenticationServices

/// The entry gate (PRD §8.11), two beats:
/// 1. **Welcome** — the full-bleed athletic hero with the wordmark and a single "Get started".
///    Pure brand, no forms (decision 2026-07-10: auth moved off the welcome).
/// 2. **Sign in** — the app icon centered up top, then the account options: Sign in with Apple
///    (must accompany any third-party login — App Store 4.8), Continue with Google (Supabase
///    OAuth web sheet), and a quiet guest path so nobody is ever blocked at the door.
struct SignInView: View {
    @Environment(AuthController.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingSignIn = false
    @State private var googleInFlight = false

    var body: some View {
        ZStack {
            welcome
            if showingSignIn {
                signInPage
                    .transition(reduceMotion
                        ? .opacity.animation(.easeOut(duration: 0.2))
                        : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.28), value: showingSignIn)
    }

    // MARK: Beat 1 — the welcome (brand only)

    private var welcome: some View {
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

            // The only CTA — everything else lives on the sign-in beat.
            VStack {
                Spacer()
                Button {
                    Haptics.light()
                    showingSignIn = true
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

    // MARK: Beat 2 — the sign-in page (icon on top, options under)

    private var signInPage: some View {
        ZStack(alignment: .topLeading) {
            Theme.background.ignoresSafeArea()

            Button {
                Haptics.light()
                showingSignIn = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .padding(.leading, Theme.Space.sm)

            VStack(spacing: 0) {
                Spacer(minLength: Theme.Space.xxl)

                BrandMark(size: 96)
                    .elevation(Theme.Elevation.float)

                VStack(spacing: Theme.Space.xs) {
                    Text("Welcome to momentum")
                        .font(.display(26, weight: .black))
                        .foregroundStyle(Theme.ink)
                    Text("Back up your training, claim your @handle, and join the community.")
                        .font(.rounded(Theme.FontSize.body, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, Theme.Space.lg)

                VStack(spacing: Theme.Space.sm) {
                    SignInWithAppleButton(.signIn) { request in
                        auth.prepareAppleSignIn(request)
                    } onCompletion: { result in
                        if case .success(let authResult) = result,
                           let credential = authResult.credential as? ASAuthorizationAppleIDCredential {
                            auth.signIn(credential: credential)
                        }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 52)
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
                                ProgressView().tint(Theme.ink)
                            } else {
                                Text("G")
                                    .font(.system(size: 19, weight: .bold, design: .rounded))
                                    .foregroundStyle(Theme.ink)
                            }
                            Text("Continue with Google")
                                .font(.system(size: 19, weight: .medium))
                                .foregroundStyle(Theme.ink)
                        }
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.hairline))
                    }
                    .buttonStyle(.plain)
                    .disabled(googleInFlight)
                    .accessibilityLabel("Continue with Google")
                }
                .padding(.top, Theme.Space.xl)

                // The guest door stays open (guest-first principle) — quiet, never blocking.
                Button {
                    Haptics.light()
                    auth.continueAsGuest()
                } label: {
                    Text("Continue without an account")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, Theme.Space.md)

                Spacer()
                Spacer()
            }
            .padding(.horizontal, Theme.Space.xl)
        }
    }
}

#Preview {
    SignInView().environment(AuthController(userID: nil))
}
