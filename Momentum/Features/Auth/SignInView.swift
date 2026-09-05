import SwiftUI
import AuthenticationServices
import AVFoundation

/// The entry, two beats:
/// 1. **Welcome** — the full-bleed athletic hero with the wordmark and a single "Build my plan" that
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
    @Environment(Services.self) private var services
    @Environment(\.scenePhase) private var scenePhase
    @ReducedMotionPreference private var reduceMotion

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
    @State private var welcomeAppeared = false   // drives the actions' one-time settle-in

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

    // MARK: Beat 1 — the welcome (brand film → personal setup)

    /// Named after the profile when there is one, so a second person on a hand-me-down phone can
    /// see whose data they'd be picking up — and "I already have an account" is right underneath.
    /// Falls back to a plain "Continue" rather than "Continue as me" when the name is blank.
    private var primaryTitle: String {
        guard hasLocalProfile else { return "Build my plan" }
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
                    Image(reduceMotion ? "WelcomeClosingPoster" : "WelcomePoster")
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .ignoresSafeArea()
                .accessibilityHidden(true)
            // Reduce Motion gets the actual closing card immediately, with no player or seek.
            if !reduceMotion {
                WelcomeFilmView(paused: showingSignIn || scenePhase != .active)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }

            // The film owns the message. Shade only the lower action area for legibility.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.58),
                    .init(color: .black.opacity(0.34), location: 0.84),
                    .init(color: .black.opacity(0.88), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // No centered lockup anymore (owner call 2026-08-11): the film's own closing card
            // carries the wordmark and motto, and a static overlay would double-brand the ending.

            // The film's MOMENTUM / KEEP MOVING close is the only headline. The controls sit
            // below it in the UI face, giving the brand room to land without a competing lockup.
            VStack(spacing: Theme.Space.md) {
                Spacer()
                VStack(spacing: Theme.Space.xs) {
                    Button {
                        Haptics.light()
                        // The door metric: this is the tap that turns an install into a funnel.
                        services.analytics.log(.welcomeAction(action: hasLocalProfile ? "resume"
                                                                                      : "get_started"))
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
                            .frame(maxWidth: .infinity).frame(height: 60)
                            .background(Capsule().fill(LinearGradient(colors: [.white, Color(hex: "F2F2F4")],
                                                                      startPoint: .top, endPoint: .bottom)))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1))
                            .shadow(color: .black.opacity(0.28), radius: 20, y: 8)   // lifts the CTA off the film
                    }
                    .buttonStyle(RaisedPressStyle())

                    // The returning athlete's door — reinstalls, a second device, and the second
                    // person on a hand-me-down phone all need to reach the account page without
                    // walking setup first.
                    Button {
                        Haptics.light()
                        services.analytics.log(.welcomeAction(action: "have_account"))
                        showingSignIn = true
                    } label: {
                        Text("I already have an account")
                            .font(.rounded(15, weight: .medium))
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
        // A quiet settle-in for the actions over the film. Honors Reduce
        // Motion (no transform, no fade).
        .onAppear {
            // A remembered athlete never waits at the gate (owner call 2026-08-20, "Strava just
            // opens"): training already on this device + no deliberate sign-out means the gate is
            // a formality — walk them straight back in as the local athlete. The welcome still
            // holds for true first-runs (no profile) and for anyone who chose to sign out
            // (Settings, account deletion, a revoked Apple credential).
            if hasLocalProfile, !AuthController.wasExplicitlySignedOut,
               !ProcessInfo.processInfo.arguments.contains("--reset-auth") {   // auth UI tests need the gate
                // Walked straight through without seeing the gate — logged so these launches don't
                // read as welcome bounces (they never had a welcome to bounce off).
                services.analytics.log(.welcomeAction(action: "auto_resume"))
                auth.continueAsGuest(celebrate: false)
                return
            }
            guard !reduceMotion else { welcomeAppeared = true; return }
            withAnimation(.easeOut(duration: 0.65).delay(0.12)) { welcomeAppeared = true }
        }
    }
}

// MARK: - The welcome film

/// The brand film behind the welcome: plays ONCE, with sound, then holds its final frame — the
/// "momentum keep moving" closing card — so the welcome settles into the same stillness the old
/// static hero had, with the brand carried by the film itself (owner call 2026-08-11; loop was
/// considered and rejected — endless motion under the CTAs reads restless and burns battery).
/// Reduce Motion: the parent shows the bundled closing still and never creates this player.
/// Sound is ON (owner call 2026-08-15): the bundled asset carries its AAC track again, and the
/// audio session is `.playback` + `.mixWithOthers` — deliberate on both counts. `.playback` so the
/// film is heard even with the ringer switch on silent (an `.ambient` film would simply never be
/// heard on the many phones that live in silent mode), and `.mixWithOthers` so it layers over an
/// athlete's running playlist instead of killing their session — never interrupt, never duck.
private struct WelcomeFilmView: UIViewRepresentable {
    /// True while another beat covers the welcome (the account page slides in over it, the welcome
    /// itself stays mounted underneath): playback holds — frame AND sound — and resumes when the
    /// athlete comes back. Muted, this leak was invisible; with sound on, a film playing under the
    /// sign-in page is exactly the "clicked off but still hear it" bug.
    var paused = false

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        // UIKit creates the layer using the class above.
        // swiftlint:disable:next force_cast
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var paused = false
        var dismantled = false
        private var audioConfigured = false

        func updatePlayback() {
            guard !dismantled, let player = playerLayer.player else { return }
            if paused {
                player.pause()
            } else {
                if !audioConfigured {
                    try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
                    audioConfigured = true
                }
                player.isMuted = false
                player.play()
            }
        }
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.paused = paused
        guard let url = Bundle.main.url(forResource: "WelcomeVideo", withExtension: "mov") else { return view }
        view.playerLayer.videoGravity = .resizeAspectFill
        // Keep AVFoundation off the first frame. Read the latest state after the deferral: a
        // quick tap may already have covered or removed the film before its player is ready.
        DispatchQueue.main.async {
            guard !view.dismantled else { return }
            let player = AVPlayer(url: url)
            player.actionAtItemEnd = .pause
            player.preventsDisplaySleepDuringVideoPlayback = false
            view.playerLayer.player = player
            view.updatePlayback()
        }
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.paused = paused
        uiView.updatePlayback()
    }

    static func dismantleUIView(_ uiView: PlayerView, coordinator: ()) {
        uiView.dismantled = true
        uiView.playerLayer.player?.pause()
        uiView.playerLayer.player = nil
    }
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
    /// The Apple button ships its own fixed palette, so it has to be told which surface it is on.
    @Environment(\.colorScheme) private var colorScheme

    @State private var googleInFlight = false
    @State private var resetInFlight = false
    // Email + password (the classic boxes; the @handle stays the social username — email only signs in)
    @State private var email = ""
    @State private var password = ""
    @State private var isCreatingAccount: Bool
    @State private var emailInFlight = false
    @State private var authMessage: String?
    /// Whether `authMessage` is a refusal or a "this worked, here's what's next".
    ///
    /// Set explicitly by whoever writes the message — never inferred from the text. The first cut
    /// sniffed a string prefix, which quietly mis-filed the successful sign-up confirmation
    /// ("Almost there…") as an error the moment the styling started to differ.
    @State private var messageKind: AuthMessageKind = .error
    /// Failures from the Apple/Google buttons. Deliberately separate from `authMessage`: that one
    /// renders inside the email block, which sits a full screen above the OAuth buttons — a message
    /// shown there for a Google failure would land off-screen for anyone who scrolled down to tap it.
    @State private var oauthMessage: String?
    @FocusState private var focusedField: Field?
    fileprivate enum Field { case email, password }
    /// Show the password in the clear. Standard on any serious sign-in form: a typo in an
    /// invisible field is the single most common reason a correct password "fails".
    @State private var revealPassword = false

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
        #if DEBUG
        // `--signin-prefill`: land with the form filled so the ENABLED CTA, the reveal control and
        // the focus ring are screenshot-verifiable (a sim can't type, and the UI-test password mode
        // deliberately swaps in a plain field, which hides the reveal).
        if ProcessInfo.processInfo.arguments.contains("--signin-prefill") {
            _email = State(initialValue: "maya@momentumco.app")
            _password = State(initialValue: "correcthorse")
        }
        #endif
    }

    private var isBeat: Bool { presentation == .onboardingBeat }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The onboarding flow owns its own canvas and padding; don't paint a second one over it.
            if !isBeat { OnboardingCanvas() }

            if !isBeat {
                // The app's own chrome treatment (the glass circle the paywall and the recorder
                // wear), not a bare glyph floating in the corner — this is the first screen a new
                // athlete sees, and a naked chevron is the tell that it was assembled rather than
                // designed. The 44pt tap target is unchanged.
                GlassCircleButton(systemName: presentation == .sheet ? "xmark" : "chevron.left",
                                  label: presentation == .sheet ? "Close" : "Back") {
                    if presentation == .sheet { dismiss() } else { onBack?() }
                }
                .padding(.leading, Theme.Space.md)
                .padding(.top, Theme.Space.xs)
                .zIndex(1)   // keep Close/Back above the ScrollView below, or the scroll layer eats its taps
            }

            // Scrolls so the whole column stays reachable with the keyboard up on small screens.
            ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // The app icon as a raised glass tile — the same hero grammar as the
                    // permission beats, so this page reads as the flow's last step.
                    // The icon alone (owner call 2026-08-27: no tile/border around it) — just the
                    // glass runner with a soft lavender glow underneath.
                    BrandMark(size: isBeat ? 76 : 84)
                        .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
                        .shadow(color: Theme.iridescent[0].opacity(0.6), radius: 26, y: 10)
                        .padding(.top, isBeat ? Theme.Space.sm : Theme.Space.xxl + Theme.Space.md)

                    OnboardingHeading(title: title, subtitle: subtitle)
                        .contentTransition(.opacity)
                        .padding(.top, Theme.Space.lg)

                    // The classic boxes: email + password, with sign-in ↔ create-account toggle.
                    VStack(spacing: Theme.Space.sm) {
                        field(focused: focusedField == .email, tap: { focusedField = .email }) {
                            TextField("Email", text: $email)
                                .keyboardType(.emailAddress)
                                .textContentType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .email)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
                        }
                        field(focused: focusedField == .password, tap: { focusedField = .password }) {
                            HStack(spacing: Theme.Space.sm) {
                                Group {
                                    if Self.uiTestPlainPassword || revealPassword {
                                        // UI tests: a plain field so iOS's password AutoFill (the
                                        // "Use Strong Password?" takeover and the post-signup "Save
                                        // Password?" panel, both untappable from XCUITest) never
                                        // engages. Real athletes get the SecureField unless they
                                        // deliberately asked to see what they typed.
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

                                // Reveal. A typo in an invisible box is the commonest reason a
                                // correct password "fails", and every serious sign-in form offers
                                // this. Swapping Secure↔plain drops first responder, so focus is
                                // put straight back — without that the keyboard closes on the tap.
                                if !Self.uiTestPlainPassword, !password.isEmpty {
                                    Button {
                                        revealPassword.toggle()
                                        focusedField = .password
                                    } label: {
                                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(Theme.inkTertiary)
                                            .frame(width: 32, height: 32)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(revealPassword ? "Hide password" : "Show password")
                                    .transition(.opacity)
                                }
                            }
                        }
                        // Say the rule BEFORE it can be broken. It used to surface only as an
                        // error after a rejected submit, which is the same information delivered
                        // as a failure.
                        if isCreatingAccount, authMessage == nil {
                            Text("At least 8 characters.")
                                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                                .foregroundStyle(Theme.inkTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.opacity)
                        }
                        if let authMessage {
                            AuthMessageRow(text: authMessage, kind: messageKind)
                        }
                        AuthPrimaryButton(title: isCreatingAccount ? "Create account" : "Sign in",
                                          enabled: canSubmit,
                                          inFlight: emailInFlight,
                                          action: submitEmailAuth)
                            // Set apart from the two inputs above it. At the group's own 8pt
                            // spacing the CTA became a third identical box in a stack of three —
                            // an ACTION has to sit outside the group it acts on, or it reads as
                            // another field.
                            .padding(.top, Theme.Space.sm)

                        HStack {
                            Button {
                                Haptics.light()
                                withAnimation(.easeOut(duration: 0.15)) {
                                    isCreatingAccount.toggle()
                                    // Both, not just the email one: a stale "Google sign-in didn't
                                    // complete" sat under the OAuth buttons across the switch and
                                    // read as a fresh failure of whatever the athlete did next.
                                    authMessage = nil
                                    oauthMessage = nil
                                    // Re-hide the password. Revealing it was consent to show THIS
                                    // secret; switching modes means a different one is about to be
                                    // typed, and it should not arrive already on screen.
                                    revealPassword = false
                                }
                            } label: {
                                Text(isCreatingAccount ? "Have an account? Sign in" : "New here? Create an account")
                                    .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                                    // Lavender = "tappable", the app-wide rule. These read as two
                                    // more labels in ink; as links they have to look like links.
                                    .foregroundStyle(Theme.purple)
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
                                            .foregroundStyle(Theme.purple)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(resetInFlight)
                            }
                        }
                        .padding(.top, 2)
                    }
                    .padding(.top, Theme.Space.xl)
                    .id("form")

                    HStack(spacing: Theme.Space.sm) {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        Text("or")
                            .font(.rounded(Theme.FontSize.label, weight: .semibold))
                            .foregroundStyle(Theme.inkTertiary)
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                    .padding(.vertical, Theme.Space.md)

                    VStack(spacing: Theme.Space.sm) {
                        // `.signUp` reads "Sign up with Apple" — matching the mode the athlete is
                        // actually in. The identifier tests assert ("Sign in with Apple") is the
                        // sign-in wording, which is what the default (and every test path) uses.
                        SignInWithAppleButton(isCreatingAccount ? .signUp : .signIn) { request in
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
                        // Apple's own guidance: never a black button on a dark surface. On the
                        // warm charcoal the black style all but vanished — only its white lettering
                        // showed, so the most trusted control on the page read as a hole.
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 56)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.18), radius: 14, y: 7)
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
                            .frame(maxWidth: .infinity).frame(height: 56)
                            .raised(Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(RaisedPressStyle())
                        .disabled(googleInFlight)
                        .accessibilityLabel("Continue with Google")

                        if let oauthMessage { AuthMessageRow(text: oauthMessage, kind: .error) }
                    }

                    footer
                }
                .padding(.horizontal, isBeat ? 0 : Theme.Space.lg)
                // NO entrance animation here, deliberately. Every route onto this screen already
                // animates it in — the gate slides from the trailing edge, the sheet presents, the
                // onboarding beat crossfades. A second fade layered on top of that reads as the
                // content arriving late, which is the exact "the page glitches" feel.
            }
            .scrollDismissesKeyboard(.interactively)
            // Keyboard up on a small screen hid the submit button under it, with no way to know
            // it was there. Bring the active field — and everything under it — into view.
            .onChange(of: focusedField) { _, field in
                guard field != nil else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("form", anchor: .center) }
            }
            }
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

    /// Whether the form can be submitted at all. Trimmed, because the raw `email.isEmpty` check
    /// let a field holding only spaces enable the button — and `submitEmailAuth` then trimmed it,
    /// found it empty, and returned silently. A live button that does nothing is worse than a
    /// disabled one.
    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    /// The boxed text-field chrome — see `AuthFormControls`.
    private func field<Content: View>(focused: Bool,
                                      tap: @escaping () -> Void,
                                      @ViewBuilder content: () -> Content) -> some View {
        content().authFieldBox(focused: focused, tap: tap)
    }

    private func submitEmailAuth() {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !emailInFlight, !address.isEmpty, !password.isEmpty else { return }
        guard address.contains("@"), address.contains(".") else {
            authMessage = "That doesn't look like an email address."
            messageKind = .error
            return
        }
        if isCreatingAccount && password.count < 8 {
            authMessage = "Passwords need at least 8 characters."
            messageKind = .error
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
            withAnimation(.easeOut(duration: 0.15)) {
                switch outcome {
                case .failure(let message):
                    authMessage = message; messageKind = .error
                case .pending(let message):
                    // Signed up fine; the session arrives when they tap the emailed link. Said as
                    // the good news it is, and the fields are cleared so the screen isn't still
                    // offering a submit that would now just fail as "already registered".
                    authMessage = message; messageKind = .info
                    password = ""
                case .success:
                    // Routes through auth.userID (the onChange above) — nothing to do here.
                    authMessage = nil
                }
            }
        }
    }

    private func sendReset() {
        guard !resetInFlight else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@") else {
            authMessage = "Enter your email above first, then tap Forgot password."
            messageKind = .error
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
                messageKind = sent ? .info : .error
            }
        }
    }
}

#Preview {
    SignInView()
        .environment(AuthController(userID: nil))
        .environment(Services.live())
}
