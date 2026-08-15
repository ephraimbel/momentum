import SwiftUI
import AuthenticationServices
import AVFoundation

/// The entry, two beats:
/// 1. **Welcome** — the full-bleed athletic hero with the wordmark and a single "Get started" that
///    goes straight into onboarding. **No account is asked for here** (decision 2026-07-27,
///    supersedes the 2026-07-10 "auth moved off the welcome" half-step and PRD §8.11's
///    sign-in-first ordering): a login wall on launch is the cheapest place in the funnel to lose
///    someone, so the account moved to the LAST beat of onboarding, after the paywall. "I already
///    have an account" is the returning athlete's door and sits right under the primary CTA.
/// 2. **Account** — `AccountOptionsView`: Sign in with Apple (must accompany any third-party login,
///    App Store 4.8), Continue with Google (Supabase OAuth web sheet), email + password, and a
///    quiet guest path so nobody is ever blocked at the door.
struct SignInView: View {
    @Environment(AuthController.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// True when presented as a cover (Settings → guest "more ways to sign in"): skips the
    /// welcome hero and the back chevron dismisses the cover instead of returning to it.
    private let presentedAsSheet: Bool
    /// Someone has already trained on this device — they signed out, or an Apple credential was
    /// revoked. The welcome then offers to pick that training back up instead of starting over
    /// (and, just as importantly, never runs a second athlete through setup on top of it).
    private let hasLocalProfile: Bool
    private let existingName: String?

    init(startOnSignInPage: Bool = false, hasLocalProfile: Bool = false, existingName: String? = nil) {
        presentedAsSheet = startOnSignInPage
        self.hasLocalProfile = hasLocalProfile
        let trimmed = existingName?.trimmingCharacters(in: .whitespaces) ?? ""
        self.existingName = trimmed.isEmpty ? nil : trimmed
        var onSignInPage = startOnSignInPage
        #if DEBUG
        // Sim verification deep links: land straight on the account beat (taps are unreliable).
        let args = ProcessInfo.processInfo.arguments
        onSignInPage = onSignInPage || args.contains("--signin-page") || args.contains("--signin-create")
        #endif
        _showingSignIn = State(initialValue: onSignInPage)
    }

    @State private var showingSignIn: Bool
    @State private var welcomeAppeared = false   // drives the lockup's one-time settle-in

    var body: some View {
        ZStack {
            if !presentedAsSheet { welcome }
            if showingSignIn {
                AccountOptionsView(presentation: presentedAsSheet ? .sheet : .gate,
                                   hasLocalProfile: hasLocalProfile,
                                   onBack: { showingSignIn = false })
                    .transition(reduceMotion
                        ? .opacity.animation(.easeOut(duration: 0.2))
                        : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.28), value: showingSignIn)
    }

    // MARK: Beat 1 — the welcome (brand only)

    /// Named after the profile when there is one, so a second person on a hand-me-down phone can
    /// see whose data they'd be picking up — and "I already have an account" is right underneath.
    /// Falls back to a plain "Continue" rather than "Continue as me" when the name is blank.
    private var primaryTitle: String {
        guard hasLocalProfile else { return "Get started" }
        return existingName.map { "Continue as \($0)" } ?? "Continue"
    }

    private var welcome: some View {
        ZStack {
            // The brand film, full-bleed (owner call 2026-08-11, replacing the static photo AND
            // the centered lockup): it plays ONCE, muted, and settles on its closing
            // "momentum keep moving" card — so the screen ends in stillness with the brand on it,
            // instead of looping restlessly under the CTAs. The poster underlay is the film's own
            // first frame, so the player readying never flashes black. Clipped to a screen-sized
            // layer so `scaledToFill`'s overflow can't inflate the ZStack (which would push the
            // CTA off-screen).
            Color.clear
                .overlay {
                    Image("WelcomePoster")
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .ignoresSafeArea()
                .accessibilityHidden(true)
            WelcomeFilmView()
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

            // No centered lockup anymore (owner call 2026-08-11): the film's own closing card
            // carries the wordmark and motto, and a static overlay would double-brand the ending.

            // The positioning line sits right above the CTA pair, all anchored to the bottom.
            VStack(spacing: Theme.Space.md) {
                Spacer()
                Text("From your first 5K to your first ultra.")
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 1)
                VStack(spacing: Theme.Space.xs) {
                    Button {
                        Haptics.light()
                        // No account either way — setup runs local-only and the account is offered
                        // on the last beat. With training already on this device we're resuming it,
                        // not starting a fresh session, so the ownership marker stays put.
                        if hasLocalProfile { auth.continueAsGuest(celebrate: false) }
                        else { auth.beginFreshLocalSession() }
                    } label: {
                        Text(primaryTitle)
                            .font(.rounded(Theme.FontSize.body, weight: .bold))
                            .foregroundStyle(.black)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, Theme.Space.md)
                            .frame(maxWidth: .infinity).frame(height: 56)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(.white))
                            .shadow(color: .black.opacity(0.28), radius: 20, y: 8)   // lifts the CTA off the photo
                    }
                    .buttonStyle(.plain)

                    // The returning athlete's door — reinstalls, a second device, and the second
                    // person on a hand-me-down phone all need to reach the account page without
                    // walking setup first.
                    Button {
                        Haptics.light()
                        showingSignIn = true
                    } label: {
                        Text("I already have an account")
                            .font(.rounded(Theme.FontSize.body, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.45), radius: 8, y: 1)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)   // must never truncate: it's the only way back in
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.lg)
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
}

// MARK: - The welcome film

/// The brand film behind the welcome: plays ONCE, muted, then holds its final frame — the
/// "momentum keep moving" closing card — so the welcome settles into the same stillness the old
/// static hero had, with the brand carried by the film itself (owner call 2026-08-11; loop was
/// considered and rejected — endless motion under the CTAs reads restless and burns battery).
/// Reduce Motion: no playback at all, the view opens directly on the closing card. The audio
/// track is stripped from the bundled asset, so playback can never duck the athlete's music.
private struct WelcomeFilmView: UIViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        // Missing asset → the poster underlay simply stays; the welcome still works.
        guard let url = Bundle.main.url(forResource: "WelcomeVideo", withExtension: "mov") else { return view }
        view.playerLayer.videoGravity = .resizeAspectFill
        let reduceMotion = reduceMotion
        // Player construction waits one runloop turn: bringing up AVFoundation inside `makeUIView`
        // sat on the app's very first frame — the first screen a brand-new user ever sees. The
        // poster underlay holds the identical opening frame until the player attaches.
        DispatchQueue.main.async {
            let player = AVPlayer(url: url)
            player.isMuted = true
            player.actionAtItemEnd = .pause                   // hold the closing card; never loop
            player.preventsDisplaySleepDuringVideoPlayback = false
            view.playerLayer.player = player
            if reduceMotion {
                // Straight to the closing card — same destination, no motion. The absurd target
                // time clamps to the end of the item.
                player.seek(to: CMTime(seconds: 9_999, preferredTimescale: 600))
            } else {
                player.play()
            }
        }
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {}
}

// MARK: - The account page

/// Every way into an account, in one column: email + password, Sign in with Apple, Continue with
/// Google. Rendered in three places, which is why it's its own view rather than a beat of
/// `SignInView`:
///
/// - `.gate` — beat 2 of the welcome, for someone who already has an account. Back chevron; the
///   guest door ("Continue without an account") stays open at the bottom.
/// - `.sheet` — Settings → guest upgrade, presented as a cover. Close button; no guest row (they
///   already are one), and a successful sign-in dismisses.
/// - `.onboardingBeat` — the LAST beat of onboarding, after the paywall (2026-07-27). No chrome to
///   escape through, "Not now" instead of a guest row, and signing in hands back to the flow.
///   Everything the athlete just built is already on disk, so declining costs them nothing but
///   cloud backup — and Settings keeps this door open forever.
struct AccountOptionsView: View {
    enum Presentation { case gate, sheet, onboardingBeat }

    let presentation: Presentation
    /// `.gate` only — whether training already lives on this device, so the guest door knows
    /// whether it is resuming a session or starting a fresh one (see `footer`).
    var hasLocalProfile = false
    /// `.gate` only — return to the welcome hero.
    var onBack: (() -> Void)?
    /// `.onboardingBeat` only — "Not now"; the athlete stays a guest and enters the app.
    var onSkip: (() -> Void)?
    /// `.onboardingBeat` only — a real account landed; hand back to the onboarding flow.
    var onSignedIn: (() -> Void)?

    @Environment(AuthController.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var googleInFlight = false
    @State private var resetInFlight = false
    // Email + password (the classic boxes; the @handle stays the social username — email only signs in)
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

    init(presentation: Presentation,
         hasLocalProfile: Bool = false,
         onBack: (() -> Void)? = nil,
         onSkip: (() -> Void)? = nil,
         onSignedIn: (() -> Void)? = nil) {
        self.presentation = presentation
        self.hasLocalProfile = hasLocalProfile
        self.onBack = onBack
        self.onSkip = onSkip
        self.onSignedIn = onSignedIn
        // On the onboarding beat the athlete has, by definition, just built something new — start
        // them on Create account rather than making them find the toggle.
        var creating = presentation == .onboardingBeat
        #if DEBUG
        creating = creating || ProcessInfo.processInfo.arguments.contains("--signin-create")
        #endif
        _isCreatingAccount = State(initialValue: creating)
    }

    private var isBeat: Bool { presentation == .onboardingBeat }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The onboarding flow owns its own canvas and padding; don't paint a second one over it.
            if !isBeat { Theme.background.ignoresSafeArea() }

            if !isBeat {
                Button {
                    Haptics.light()
                    if presentation == .sheet { dismiss() } else { onBack?() }
                } label: {
                    Image(systemName: presentation == .sheet ? "xmark" : "chevron.left")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(presentation == .sheet ? "Close" : "Back")
                .padding(.leading, Theme.Space.sm)
                .zIndex(1)   // keep Close/Back above the ScrollView below, or the scroll layer eats its taps
            }

            // Scrolls so the whole column stays reachable with the keyboard up on small screens.
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    BrandMark(size: isBeat ? 72 : 88)
                        .elevation(Theme.Elevation.float)
                        .padding(.top, isBeat ? Theme.Space.sm : Theme.Space.xxl)

                    VStack(spacing: Theme.Space.xs) {
                        Text(title)
                            .font(.display(26, weight: .black))
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.center)
                            .contentTransition(.opacity)
                        Text(subtitle)
                            .font(.rounded(Theme.FontSize.body, weight: .medium))
                            .foregroundStyle(Theme.inkSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
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
                                    // In-flight feedback: without the latch, impatient re-taps on
                                    // a slow network sent duplicate reset emails against the
                                    // mailer's tight hourly budget (audit 2026-08-11).
                                    if resetInFlight {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Text("Forgot password?")
                                            .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                                            .foregroundStyle(Theme.inkSecondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(resetInFlight)
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
                        // One sign-in at a time: launching Apple while an email submit is in
                        // flight let the slower winner silently flip the identity afterwards
                        // (audit 2026-08-11).
                        .disabled(emailInFlight || googleInFlight)

                        Button {
                            guard !googleInFlight, !emailInFlight else { return }
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
                                    // The official multicolor G (Google's sign-in branding rules
                                    // want the real mark and "Continue with Google" wording).
                                    Image("GoogleG")
                                        .resizable().interpolation(.high).scaledToFit()
                                        .frame(width: 20, height: 20)
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

                    footer
                }
                .padding(.horizontal, isBeat ? 0 : Theme.Space.xl)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        // A real account landed. `.gate` needs nothing — RootView's signed-in branch takes over.
        .onChange(of: auth.userID) { _, id in
            guard let id, id != AuthController.guestID else { return }
            switch presentation {
            case .sheet: dismiss()
            case .onboardingBeat: onSignedIn?()
            case .gate: break
            }
        }
    }

    /// The way out of this screen, which is different in all three places it appears.
    @ViewBuilder
    private var footer: some View {
        switch presentation {
        case .gate:
            // The guest door stays open (guest-first principle) — quiet, never blocking.
            Button {
                Haptics.light()
                // This door also leads into setup when there's no training here yet, so it has to
                // release the prior owner's claim exactly like "Get started" does — otherwise
                // signing in on the final beat reads as an account switch and wipes the plan the
                // athlete just built. `AuthController.isOnboarding` is the backstop; this keeps the
                // cloud-claim marker honest too, so their guest-era data actually uploads.
                if hasLocalProfile { auth.continueAsGuest() } else { auth.beginFreshLocalSession() }
            } label: {
                Text("Continue without an account")
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Not while a sign-in is resolving: entering as a guest mid-flight let the slow
            // success flip the identity to the email account moments later, silently overriding
            // the guest choice (audit 2026-08-11).
            .disabled(emailInFlight || googleInFlight)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.xl)
        case .sheet:
            // Hidden when a guest opened this from Settings (they're already one).
            Spacer().frame(height: Theme.Space.xl)
        case .onboardingBeat:
            // Never `continueAsGuest()` here: they already ARE the guest, so `auth.userID` wouldn't
            // change and the onChange above would never fire — a dead button on the last screen of
            // onboarding. Skipping is the flow's business, so hand it straight back.
            Button {
                Haptics.light()
                onSkip?()
            } label: {
                Text("Not now")
                    // Secondary, not tertiary: this is the ONLY way off the last screen of
                    // onboarding, so it has to stay comfortably readable rather than whisper-quiet.
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.xl)
        }
    }

    private var title: String {
        switch presentation {
        case .onboardingBeat: "Save your progress"
        case .gate, .sheet: isCreatingAccount ? "Create your account" : "Welcome to momentum"
        }
    }

    private var subtitle: String {
        // The old line promised an @handle and a community; the handle claim left onboarding and
        // community is back-burnered (2026-07-16). Say what an account actually does TODAY, and
        // nothing more: sync is upload-only — there is no download/restore path yet — so any
        // promise of picking your training up on another phone would be a promise we can't keep.
        switch presentation {
        case .onboardingBeat:
            "An account keeps a backup of your training off this phone. You can also do this later in Settings."
        case .gate, .sheet:
            "An account keeps a backup of your training off this phone."
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
            // Success routes through auth.userID (the onChange above) — nothing to do here.
        }
    }

    private func sendReset() {
        guard !resetInFlight else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@") else {
            authMessage = "Enter your email above first, then tap Forgot password."
            return
        }
        resetInFlight = true
        Task {
            let sent = await auth.sendPasswordReset(to: address)
            resetInFlight = false
            withAnimation(.easeOut(duration: 0.15)) {
                authMessage = sent
                    ? "Check \(address) for a reset link."
                    : "Couldn't send a reset link. Try again in a moment."
            }
        }
    }
}

#Preview {
    SignInView().environment(AuthController(userID: nil))
}
