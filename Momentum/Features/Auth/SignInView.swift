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
    @Environment(\.dismiss) private var dismiss

    /// True when presented as a cover (Settings → guest "more ways to sign in"): skips the
    /// welcome hero and the back chevron dismisses the cover instead of returning to it.
    private let presentedAsSheet: Bool

    init(startOnSignInPage: Bool = false) {
        presentedAsSheet = startOnSignInPage
        var onSignInPage = startOnSignInPage
        var creating = false
        #if DEBUG
        // Sim verification deep links: land straight on the sign-in beat (taps are unreliable).
        let args = ProcessInfo.processInfo.arguments
        onSignInPage = onSignInPage || args.contains("--signin-page") || args.contains("--signin-create")
        creating = args.contains("--signin-create")
        #endif
        _showingSignIn = State(initialValue: onSignInPage)
        _isCreatingAccount = State(initialValue: creating)
    }

    @State private var showingSignIn: Bool
    @State private var googleInFlight = false
    @State private var welcomeAppeared = false   // drives the lockup's one-time settle-in

    // Email + password (the classic boxes; @handle stays the social username — email only signs in)
    @State private var email = ""
    @State private var password = ""
    @State private var isCreatingAccount: Bool
    @State private var emailInFlight = false
    @State private var authMessage: String?
    /// Failures from the Apple/Google buttons. Deliberately separate from `authMessage`: that one
    /// renders inside the email block, which sits a full screen above the OAuth buttons — a message
    /// shown there for a Google failure would land off-screen for anyone who scrolled down to tap it.
    @State private var oauthMessage: String?
    @FocusState private var focusedField: Field?
    private enum Field { case email, password }

    var body: some View {
        ZStack {
            if !presentedAsSheet { welcome }
            if showingSignIn {
                signInPage
                    .transition(reduceMotion
                        ? .opacity.animation(.easeOut(duration: 0.2))
                        : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.28), value: showingSignIn)
        // Presented from Settings (guest upgrade): a successful sign-in closes the cover.
        .onChange(of: auth.userID) { _, id in
            if presentedAsSheet, let id, id != AuthController.guestID { dismiss() }
        }
    }

    // MARK: Beat 1 — the welcome (brand only)

    private var welcome: some View {
        ZStack {
            // Full-bleed black-and-white hero of the runners. Clipped to a screen-sized layer so
            // `scaledToFill`'s overflow can't inflate the ZStack (which would push the CTA off-screen).
            Color.clear
                .overlay {
                    Image("WelcomeBackground")
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .ignoresSafeArea()
                .accessibilityHidden(true)

            // Scrim — clear over the runners up top, darkening toward the bottom so the positioning
            // line and the Get started button stay crisp.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.40),
                    .init(color: .black.opacity(0.34), location: 0.74),
                    .init(color: .black.opacity(0.88), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // Centered brand lockup: the wordmark with the motto right under it. A soft shadow keeps
            // it legible over the photo.
            VStack(spacing: Theme.Space.sm) {
                Image("WordmarkWhite")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 40)   // fixed height; width follows the wordmark's aspect ratio
                    .accessibilityLabel("momentum")
                Text("keep moving")
                    .font(.serif(24, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .multilineTextAlignment(.center)
            }
            .shadow(color: .black.opacity(0.4), radius: 14, y: 2)
            .opacity(welcomeAppeared || reduceMotion ? 1 : 0)
            .offset(y: welcomeAppeared || reduceMotion ? 0 : 12)

            // The positioning line sits right above the single CTA, both anchored to the bottom.
            VStack(spacing: Theme.Space.md) {
                Spacer()
                Text("From your first 5K to your first ultra.")
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 1)
                Button {
                    Haptics.light()
                    showingSignIn = true
                } label: {
                    Text("Get started")
                        .font(.rounded(Theme.FontSize.body, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(.white))
                        .shadow(color: .black.opacity(0.28), radius: 20, y: 8)   // lifts the CTA off the photo
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xxl)
            .opacity(welcomeAppeared || reduceMotion ? 1 : 0)
            .offset(y: welcomeAppeared || reduceMotion ? 0 : 18)
        }
        // A quiet settle-in so the brand lands on the photo instead of snapping in. Honors Reduce
        // Motion (no transform, no fade).
        .onAppear {
            guard !reduceMotion else { welcomeAppeared = true; return }
            withAnimation(.easeOut(duration: 0.65).delay(0.12)) { welcomeAppeared = true }
        }
    }

    // MARK: Beat 2 — the sign-in page (icon on top, options under)

    private var signInPage: some View {
        ZStack(alignment: .topLeading) {
            Theme.background.ignoresSafeArea()

            Button {
                Haptics.light()
                if presentedAsSheet { dismiss() } else { showingSignIn = false }
            } label: {
                Image(systemName: presentedAsSheet ? "xmark" : "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(presentedAsSheet ? "Close" : "Back")
            .padding(.leading, Theme.Space.sm)
            .zIndex(1)   // keep Close/Back above the ScrollView below, or the scroll layer eats its taps

            // Scrolls so the whole column stays reachable with the keyboard up on small screens.
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    BrandMark(size: 88)
                        .elevation(Theme.Elevation.float)
                        .padding(.top, Theme.Space.xxl)

                    VStack(spacing: Theme.Space.xs) {
                        Text(isCreatingAccount ? "Create your account" : "Welcome to momentum")
                            .font(.display(26, weight: .black))
                            .foregroundStyle(Theme.ink)
                            .contentTransition(.opacity)
                        Text("Back up your training, claim your @handle, and join the community.")
                            .font(.rounded(Theme.FontSize.body, weight: .medium))
                            .foregroundStyle(Theme.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, Theme.Space.lg)

                    // The classic boxes: email + password, with sign-in ↔ create-account toggle.
                    VStack(spacing: Theme.Space.sm) {
                        field {
                            TextField("Email", text: $email)
                                .keyboardType(.emailAddress)
                                .textContentType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .email)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
                        }
                        field {
                            Group {
                                if Self.uiTestPlainPassword {
                                    // UI tests: a plain field so iOS's password AutoFill (the
                                    // "Use Strong Password?" takeover and the post-signup "Save
                                    // Password?" panel, both untappable from XCUITest) never
                                    // engages. Real athletes always get the SecureField below.
                                    TextField("Password", text: $password)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                } else {
                                    SecureField("Password", text: $password)
                                        .textContentType(isCreatingAccount ? .newPassword : .password)
                                }
                            }
                            .focused($focusedField, equals: .password)
                            .submitLabel(.go)
                            .onSubmit { submitEmailAuth() }
                        }
                        if let authMessage {
                            Text(authMessage)
                                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                                .foregroundStyle(Theme.inkSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.opacity)
                        }
                        Button {
                            submitEmailAuth()
                        } label: {
                            Group {
                                if emailInFlight {
                                    ProgressView().tint(Theme.background)
                                } else {
                                    Text(isCreatingAccount ? "Create account" : "Sign in")
                                        .font(.rounded(Theme.FontSize.body, weight: .bold))
                                }
                            }
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.ink))
                        }
                        .buttonStyle(.plain)
                        .disabled(emailInFlight || email.isEmpty || password.isEmpty)
                        .opacity(email.isEmpty || password.isEmpty ? 0.5 : 1)

                        HStack {
                            Button {
                                Haptics.light()
                                withAnimation(.easeOut(duration: 0.15)) {
                                    isCreatingAccount.toggle()
                                    authMessage = nil
                                }
                            } label: {
                                Text(isCreatingAccount ? "Have an account? Sign in" : "New here? Create an account")
                                    .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                                    .foregroundStyle(Theme.ink)
                            }
                            .buttonStyle(.plain)
                            Spacer(minLength: 0)
                            if !isCreatingAccount {
                                Button {
                                    Haptics.light()
                                    sendReset()
                                } label: {
                                    Text("Forgot password?")
                                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                                        .foregroundStyle(Theme.inkSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 2)
                    }
                    .padding(.top, Theme.Space.xl)

                    HStack(spacing: Theme.Space.sm) {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        Text("or")
                            .font(.rounded(Theme.FontSize.label, weight: .semibold))
                            .foregroundStyle(Theme.inkTertiary)
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                    .padding(.vertical, Theme.Space.md)

                    VStack(spacing: Theme.Space.sm) {
                        SignInWithAppleButton(.signIn) { request in
                            auth.prepareAppleSignIn(request)
                        } onCompletion: { result in
                            switch result {
                            case .success(let authResult):
                                if let credential = authResult.credential as? ASAuthorizationAppleIDCredential {
                                    auth.signIn(credential: credential)
                                }
                            case .failure(let error):
                                // Dismissing the Apple sheet reports as `.canceled` — that's a
                                // choice, not a fault, and must stay silent. Anything else left the
                                // athlete on a gate that had just refused them without saying why.
                                let code = (error as? ASAuthorizationError)?.code
                                if code != .canceled {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        oauthMessage = "Apple sign-in didn't complete. Check your connection and try again."
                                    }
                                }
                            }
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

                        Button {
                            guard !googleInFlight else { return }
                            Haptics.light()
                            googleInFlight = true
                            oauthMessage = nil
                            Task {
                                // The result used to be discarded, so a failure — offline, the
                                // provider not configured, the sheet erroring — stopped the spinner
                                // and said nothing. A gate that silently refuses you is a dead end.
                                let ok = await auth.signInWithGoogle()
                                googleInFlight = false
                                if !ok, !auth.isSignedIn {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        oauthMessage = "Google sign-in didn't complete. Check your connection and try again."
                                    }
                                }
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

                        if let oauthMessage {
                            Text(oauthMessage)
                                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                                .foregroundStyle(Theme.inkSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.opacity)
                        }
                    }

                    // The guest door stays open (guest-first principle) — quiet, never blocking.
                    // Hidden when a guest opened this from Settings (they're already one).
                    if !presentedAsSheet {
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
                        .padding(.top, Theme.Space.sm)
                        .padding(.bottom, Theme.Space.xl)
                    } else {
                        Spacer().frame(height: Theme.Space.xl)
                    }
                }
                .padding(.horizontal, Theme.Space.xl)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    /// UI-test escape hatch (--uitest-password): even `.oneTimeCode` content types still trip
    /// iOS's save-password heuristics intermittently, so tests swap in a plain TextField.
    private static var uiTestPlainPassword: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--uitest-password")
        #else
        false
        #endif
    }

    /// The boxed text-field chrome shared by the email and password inputs.
    private func field<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.rounded(Theme.FontSize.body, weight: .medium))
            .foregroundStyle(Theme.ink)
            .frame(height: 52)
            .padding(.horizontal, Theme.Space.md)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.hairline))
    }

    private func submitEmailAuth() {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !emailInFlight, !address.isEmpty, !password.isEmpty else { return }
        guard address.contains("@"), address.contains(".") else {
            authMessage = "That doesn't look like an email address."
            return
        }
        if isCreatingAccount && password.count < 8 {
            authMessage = "Passwords need at least 8 characters."
            return
        }
        Haptics.light()
        focusedField = nil
        authMessage = nil
        emailInFlight = true
        let creating = isCreatingAccount
        Task {
            let outcome = creating
                ? await auth.signUpWithEmail(address, password: password)
                : await auth.signInWithEmail(address, password: password)
            emailInFlight = false
            if case .failure(let message) = outcome {
                withAnimation(.easeOut(duration: 0.15)) { authMessage = message }
            }
            // Success dismisses the gate via auth.userID — nothing to do here.
        }
    }

    private func sendReset() {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@") else {
            authMessage = "Enter your email above first, then tap Forgot password."
            return
        }
        Task {
            let sent = await auth.sendPasswordReset(to: address)
            withAnimation(.easeOut(duration: 0.15)) {
                authMessage = sent
                    ? "Check \(address) for a reset link."
                    : "Couldn't send a reset link — try again in a moment."
            }
        }
    }
}

#Preview {
    SignInView().environment(AuthController(userID: nil))
}
