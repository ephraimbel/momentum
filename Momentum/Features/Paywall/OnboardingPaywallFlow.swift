import SwiftUI

/// The onboarding paywall (redesign 2026-08-05, after the Cal AI reference; settled the same day
/// at two pages): a two-page sequence. Page one is the tour — "Welcome to momentum." over a
/// large device mock paging through real screens; it asks for nothing (onboarding already asked
/// for notifications — the trial reminder is still scheduled at purchase). Page two is THE
/// paywall — the exact `PaywallView` the rest of the app shows, with its feature checklist
/// and the yearly-first plan pair. One paywall page everywhere; this flow only adds the tour in
/// front of it.
///
/// HARD for onboarding since 2026-09-01: there is no close button and interactive dismissal is
/// disabled. Purchase (or Restore) is the normal path through; a force-quit re-raises the gate at
/// checkout because `onboardingGatePending` is persisted. The one safety escape remains deliberately
/// narrow: after two genuine App Store failures, `PaywallCheckout` lets the athlete defer until the
/// next launch so an outage can never brick the app. Contextual paywalls elsewhere stay dismissible.
struct OnboardingPaywallFlow: View {
    /// Relaunch gate: skip straight to the checkout page (the story was told last launch).
    var startAtCheckout = false
    /// The promise the athlete just saw on their plan reveal. Nil for relaunches/contextless hosts.
    var personalizedOutcome: String?
    /// Called INSTEAD of dismissing when the athlete becomes entitled — see PaywallCheckout.
    var onEntitled: (() -> Void)?
    @Environment(PaywallController.self) private var paywall
    @Environment(Services.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: Int
    /// Direction of the last navigation, so the page transition slides the right way.
    @State private var goingBack = false
    /// Restore lives in the top chrome on every page (App Review 3.1.1: a hard wall must always
    /// offer a way to reclaim a past purchase) — it needs its own tiny state here because the
    /// tour page has no `PaywallCheckout` to host it.
    @State private var restoring = false
    @State private var nothingToRestore = false
    @State private var revealed = false

    private var offering: PaywallOffering { paywall.offering }

    init(startAtCheckout: Bool = false, personalizedOutcome: String? = nil,
         onEntitled: (() -> Void)? = nil) {
        self.startAtCheckout = startAtCheckout
        self.personalizedOutcome = personalizedOutcome
        self.onEntitled = onEntitled
        _step = State(initialValue: startAtCheckout ? 1 : 0)
    }

    var body: some View {
        GeometryReader { geo in
            let s = min(1, max(0.8, geo.size.height / 820))   // same size-adaptive scale as PaywallView
            ZStack {
                switch step {
                case 0: pageShowcase(s).transition(pageTransition)
                default: pagePaywall.transition(pageTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .top) { chrome }
        // The paywall page brings its OWN animated background inside `PaywallView` — rendering a
        // second one behind it doubled the costliest layer on screen (perf, 2026-08-05). The tour
        // gets the bloom; the paywall page gets flat charcoal behind its self-contained canvas.
        .background {
            if step == 0 { PaywallBackground() } else { Theme.background.ignoresSafeArea() }
        }
        // Warm-charcoal dark moment, same non-leaking mechanism as PaywallView (never
        // `.preferredColorScheme` — it flows up to the hosting window and sticks after dismiss).
        .environment(\.colorScheme, .light)   // bright wall (owner call 2026-08-27), matching the light setup before it
        .interactiveDismissDisabled(true)
        .alert("Nothing to restore", isPresented: $nothingToRestore) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("We couldn't find a past purchase on this Apple ID.")
        }
        // Analytics for the paywall itself are logged by `PaywallView` when its page shows —
        // logging here too would double-count the funnel.
        .onAppear {
            if step == 0 { services.analytics.log(.onboardingShowcase(action: "viewed")) }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { revealed = true }
        }
        .onChange(of: step) { old, new in
            if old == 0, new == 1 { services.analytics.log(.onboardingShowcase(action: "continued")) }
            if new == 0 { services.analytics.log(.onboardingShowcase(action: "viewed")) }
        }
    }

    // MARK: Navigation

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: goingBack ? .leading : .trailing).combined(with: .opacity),
            removal: .move(edge: goingBack ? .trailing : .leading).combined(with: .opacity))
    }

    // `Motion.travel` (the onboarding step spring, damping 0.86), not `Motion.lively`: lively's
    // overshoot is right for a selection pop and wrong for a whole page, which visibly bounced
    // off its rest position before settling. Same hand as every other step in the funnel.
    private func advance() {
        goingBack = false
        withAnimation(reduceMotion ? nil : Motion.travel) { step += 1 }
    }

    private func back() {
        goingBack = true
        withAnimation(reduceMotion ? nil : Motion.travel) { step -= 1 }
    }

    /// Back to the showcase from checkout; Restore alone on the showcase. Checkout already carries
    /// Restore in its fine print, so duplicating it in the chrome would be noise. There is no close:
    /// this view is the onboarding-only hard gate, while ordinary in-app paywalls own their X.
    private var chrome: some View {
        HStack(spacing: Theme.Space.md) {
            if step > 0 {
                Button { back() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                        .frame(width: 34, height: 34).momentumGlass(in: Circle())
                }
                .accessibilityLabel("Back")
            }
            Spacer()
            if step == 0 {
                Button("Restore") { restore() }
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .disabled(restoring)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .animation(reduceMotion ? nil : Motion.travel, value: step)
    }

    private func restore() {
        Task {
            restoring = true
            _ = await paywall.restore()
            restoring = false
            // Entitled → the gate's `isPro` binding (or the host's onEntitled) takes it from here.
            if paywall.isPro { onEntitled?() } else { nothingToRestore = true }
        }
    }

    // MARK: Page one — the app itself, on a device

    /// The opener (owner call 2026-08-05: the 3-page flow's try-free feature page was cut — the
    /// checklist lives on the in-app paywall). One serif line, then the device carries the page;
    /// the footer already whispers the price and the trial.
    private func pageShowcase(_ s: CGFloat) -> some View {
        // The deck bleeds edge to edge (its fanned neighbors peek at the screen sides), so the
        // horizontal padding lives on the copy and the footer, not the whole page.
        VStack(spacing: 0) {
            Spacer(minLength: Theme.Space.lg)
            // The display sans, not the serif: the tour is the first page of the same flow as
            // onboarding and the paywall, and both set their headlines in Space Grotesk. One
            // heavy black line, tight tracking, and the deck below does the talking.
            Text("Welcome to momentum.")
                .font(.display(30 * s, weight: .bold)).tracking(-0.9 * s)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .lineLimit(1).minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.xl)
                .reveal(revealed, delay: 0.05, reduceMotion: reduceMotion)
            Spacer(minLength: Theme.Space.lg)
            PaywallShowcase(height: 500 * s)
                .reveal(revealed, delay: 0.15, reduceMotion: reduceMotion)
            Spacer(minLength: Theme.Space.lg)
            footer(cta: showcaseCTA, s: s) { advance() }
                .padding(.horizontal, Theme.Space.xl)
                .reveal(revealed, delay: 0.25, reduceMotion: reduceMotion)
        }
    }

    // MARK: Page two — checkout

    /// THE paywall — the same `PaywallView` the rest of the app shows (owner call 2026-08-05:
    /// one paywall page everywhere; the bespoke trial-timeline page is gone). It brings its own
    /// background, checkout, analytics and entitlement handling; the flow just hosts it and adds
    /// the back chevron to the showcase. `hard: true` suppresses its contextual close affordance
    /// and activates the two-failure App Store escape.
    private var pagePaywall: some View {
        PaywallView(feature: .fullPlan, hard: true,
                    personalizedOutcome: personalizedOutcome, onEntitled: onEntitled)
    }

    /// "Try now" is only honest when a trial is actually behind it, and whether one IS behind it is
    /// a STORE fact, not an app one: the live path reads `introductoryDiscount` off the product
    /// (`PaywallController.trialDays(of:)`), so a trial can be switched on or off in App Store
    /// Connect with no build. Hardcoded, this button promised a trial the store may not be
    /// offering — it read "Try now" over a plain $59.99 charge after the trial was retired
    /// (2026-08-20), which is both a conversion mismatch with the checkout page and the kind of
    /// subscription-presentation ambiguity App Review 3.1.2 exists for.
    ///
    /// Same guard as the trust line in `footer` and as `PaywallCheckout`'s own CTA: with
    /// placeholder pricing we do not yet know what the store offers, so we do not promise.
    /// Flip the offer in ASC and this reverts to "Try now" on its own.
    private var showcaseCTA: String {
        offering.annual.trialDays > 0 && paywall.pricingIsLive ? "Try now" : "Continue"
    }

    // MARK: The tour page's footer

    /// Trust line + black CTA + the price in plain words. These pages sell without transacting,
    /// so their fine print is one honest sentence rather than the checkout's full renewal terms.
    private func footer(cta: String, s: CGFloat, action: @escaping () -> Void) -> some View {
        VStack(spacing: Theme.Space.sm + 2) {
            if offering.annual.trialDays > 0, paywall.pricingIsLive {
                Label("No payment due now", systemImage: "checkmark")
                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
            }
            Button {
                Haptics.light()
                action()
            } label: {
                // A full-width ink capsule (the radius law: pills are capsules), 56pt so it
                // reads as THE action on the page, medium weight so the label sits quiet in it.
                Text(cta)
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .foregroundStyle(Theme.background)
                    .background(Capsule().fill(Theme.ink))
            }
            .buttonStyle(.plain)
            Group {
                if paywall.pricingIsLive {
                    let perWeek = offering.annual.perWeekText ?? ""
                    // Middot, not parentheses — every other price line in the paywall separates
                    // clauses with "·", and this footer shouldn't be the odd one out.
                    Text("Just \(perWeek) · \(offering.annual.priceText) billed yearly")
                } else {
                    Text("Pricing unavailable · cancel anytime")
                }
            }
            .font(.rounded(10, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
        .padding(.bottom, Theme.Space.xs)
    }
}

#Preview {
    OnboardingPaywallFlow()
        .environment(PaywallController(isPro: false))
}
