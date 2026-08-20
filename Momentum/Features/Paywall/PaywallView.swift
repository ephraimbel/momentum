import SwiftUI
import AVFoundation

/// The Pro paywall (PRD §10) — "The Film" (owner pick 2026-08-20, from the paywall study): the
/// brand film plays as a muted loop behind one serif statement, an honest plan
/// timeline, and the checkout. Trial-less since 2026-08-20 (owner call: the soft paywall IS the
/// trial; the yearly sells on savings) — but every trial branch stays data-driven off the
/// store's intro offer, so a future offer simply lights the old copy back up. No feature grid on the wall — the film sells the feeling, a quiet
/// "Everything in Pro" sheet answers the detail question, and the loop is trimmed to end BEFORE
/// the film's closing title card so its wordmark never fights the headline. **Trust stays a
/// feature:** both plans one tap apart, plain renewal terms before purchase, one-tap restore.
/// Onboarding's (soft) gate uses the two-page `OnboardingPaywallFlow`; both are assembled from
/// the same `PaywallComponents`.
struct PaywallView: View {
    /// The locked feature that brought the user here — logged, and frames nothing visually: the
    /// film is the same story for every door.
    var feature: Feature = .aiCoach
    /// Hard placement: no close affordance, no swipe-away — the only ways forward are
    /// subscribing or restoring. Contextual gates elsewhere stay dismissible; trust
    /// copy (plain renewal terms, one-tap restore) is identical in both modes.
    var hard: Bool = false
    /// Called INSTEAD of dismissing when the athlete becomes entitled — see PaywallCheckout.
    var onEntitled: (() -> Void)?

    @Environment(PaywallController.self) private var paywall
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selected: PaywallProduct.Period = .annual
    @State private var revealed = false
    @State private var showFeatures = false
    /// Set the instant a dismissal begins: the film unmounts FIRST, so the cover's slide-down
    /// animates a plain charcoal page instead of a live AVPlayerLayer — the player compositing
    /// under the transition was the end-of-exit stutter, and safe-area-ignoring video re-laying
    /// out mid-flight was the strip of film left at the bottom (owner report 2026-08-20).
    @State private var dismissing = false
    @Namespace private var planThumb

    /// The page's ground — one hex, shared by the ground fill and the film's dissolve ramp.
    private let charcoal = Color(hex: "141210")

    private var offering: PaywallOffering { paywall.offering }
    private var product: PaywallProduct { selected == .annual ? offering.annual : offering.monthly }

    var body: some View {
        GeometryReader { geo in
            let s = min(1, max(0.85, geo.size.height / 820))
            content(s)
        }
    }

    private func content(_ s: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: Theme.Space.sm * s) {
                Text("Run smarter.\nRace faster.")
                    .font(.serif(38 * s, weight: .semibold)).foregroundStyle(.white)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .reveal(revealed, delay: 0.03, reduceMotion: reduceMotion)
                // Two plain sentences, no dash — the owner's voice rule (2026-07-30).
                Text("Plans built by runners, for runners.\nAround your body, your goal, your life.")
                    .font(.serif((Theme.FontSize.caption + 3) * s, weight: .medium))
                    .foregroundStyle(.white.opacity(0.74))
                    .fixedSize(horizontal: false, vertical: true)
                    .reveal(revealed, delay: 0.07, reduceMotion: reduceMotion)

                timeline(s)
                    .padding(.top, (Theme.Space.md - 2) * s)
                    .reveal(revealed, delay: 0.12, reduceMotion: reduceMotion)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: selected)

                // The tag overhangs the track's top edge by ~9pt, so the visual gap under the
                // timeline is this padding minus the overhang — lg keeps real air there
                // (owner note 2026-08-20: the rows felt cramped against the buttons).
                planRow(s)
                    .padding(.top, (Theme.Space.lg - 2) * s)
                    .reveal(revealed, delay: 0.17, reduceMotion: reduceMotion)

                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86)) {
                        showFeatures = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Everything in Pro")
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                            .opacity(0.7)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.vertical, 8).padding(.horizontal, 14)
                    .background(Capsule().fill(.white.opacity(0.1)))
                    .overlay(Capsule().stroke(.white.opacity(0.18)))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableScaleStyle(scale: 0.96))
                .frame(maxWidth: .infinity)
                .padding(.top, 4 * s)
                .reveal(revealed, delay: 0.21, reduceMotion: reduceMotion)
                .accessibilityHint("Shows the full list of Pro features")
            }
            .padding(.horizontal, Theme.Space.xl)
        }
        .safeAreaInset(edge: .bottom) {
            PaywallCheckout(product: product, hard: hard,
                            onEntitled: onEntitled ?? { exitPaywall() })
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.md)
                .reveal(revealed, delay: 0.25, reduceMotion: reduceMotion)
        }
        .background {
            // Half-and-half (owner call 2026-08-20): the film owns the TOP of the page and
            // dissolves into a solid warm-charcoal ground where the content lives — type on
            // solid ground, film as the crown. The seam is the app's own eased scrim curve, so
            // no visible line; one faint lavender pool breathes under the checkout.
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    Color(hex: "141210")
                    // The film dissolves under a plain OVERLAY gradient, not an alpha mask: a
                    // SwiftUI mask over an AVPlayerLayer forces an offscreen compositing pass on
                    // every video frame (the "glitchy" hitch, owner report 2026-08-20). The ramp
                    // reaches FULL charcoal a comfortable margin BEFORE the film's bottom edge,
                    // so solid meets solid there and no seam can exist — same look, zero cost.
                    if !dismissing {
                        PaywallFilmBackground()
                            .frame(height: geo.size.height * 0.62)
                            .transition(.opacity)
                    }
                    // The dissolve is its own layer, NOT an overlay measured against the film's
                    // frame: ramp from 24% to 58% of the page, then GUARANTEED solid charcoal to
                    // the bottom — the solid section overlaps the film's last visible band with
                    // margin, so no frame math can ever reopen a seam (owner report: a hard band
                    // mid-fade). 24 smootherstep samples keep the ramp itself kink-free.
                    VStack(spacing: 0) {
                        Color.clear.frame(height: geo.size.height * 0.16)
                        // A LONG ramp (44% of the page) so no section changes fast enough to read
                        // as an edge over bright footage; smoothstep with a 0.85 gamma opens the
                        // shadow end, spreading the darkening the eye is most sensitive to.
                        LinearGradient(stops: (0...29).map { i in
                            let t = Double(i) / 29
                            let r = min(1, t / 0.92)
                            let e = pow(r * r * (3 - 2 * r), 0.85)
                            return .init(color: charcoal.opacity(e), location: t)
                        }, startPoint: .top, endPoint: .bottom)
                        .frame(height: geo.size.height * 0.44)
                        charcoal
                    }
                    .allowsHitTesting(false)
                    LinearGradient(colors: [.black.opacity(0.28), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 130)
                    RadialGradient(colors: [Theme.purple.opacity(0.3), .clear],
                                   center: .bottom, startRadius: 20, endRadius: 470)
                }
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) { if !hard { closeButton } }
        // The paywall is a dark moment regardless of appearance. `.environment(\.colorScheme)`,
        // NOT `.preferredColorScheme` — the latter leaks the forced scheme to the presenter.
        .environment(\.colorScheme, .dark)
        .overlay { if showFeatures { featurePopup } }
        .onAppear {
            services.analytics.log(.paywallView(placement: feature.placement))
            SKANConversion.record(.paywallSeen)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { revealed = true }
            #if DEBUG
            // --paywall-features: open the popup deterministically for screenshots.
            if ProcessInfo.processInfo.arguments.contains("--paywall-features") { showFeatures = true }
            #endif
        }
    }

    // MARK: The plan timeline — the honest three beats (Opal's confidence pattern)

    @ViewBuilder
    private func timeline(_ s: CGFloat) -> some View {
        if paywall.pricingIsLive {
            // BOTH plan states render inside one fixed-footprint ZStack and only crossfade
            // (owner call 2026-08-20: switching plans must never move the buttons below —
            // content that changes animates in place, the geometry holds still). The ZStack
            // sizes to the taller three-row annual timeline, so the monthly line simply fades
            // in over reserved space.
            ZStack(alignment: .topLeading) {
                annualTimeline(s)
                    .opacity(selected == .annual ? 1 : 0)
                    .accessibilityHidden(selected != .annual)
                // "No trial" is a contrast line — it only earns its place while the yearly
                // actually carries one.
                timelineRow(offering.annual.trialDays > 0
                            ? "Billed monthly at \(offering.monthly.priceText). No trial, cancel anytime"
                            : "Billed monthly at \(offering.monthly.priceText). Cancel anytime",
                            live: true, s: s)
                    .opacity(selected == .monthly ? 1 : 0)
                    .accessibilityHidden(selected != .monthly)
            }
        } else {
            // Store prices not yet loaded — promise nothing numeric (pricing honesty rule).
            timelineRow("Every feature unlocks today", live: true, s: s)
        }
    }

    /// The three honest beats with the hairline rail. The rail lives in the VStack's BACKGROUND
    /// so it adopts the rows' height — as a ZStack sibling its unconstrained height blew the
    /// whole stack open to fill the screen. Trial-less (owner call 2026-08-20), the beats tell
    /// the one-payment story instead; a store-side trial returning brings its beats back.
    private func annualTimeline(_ s: CGFloat) -> some View {
        let annual = offering.annual
        return VStack(alignment: .leading, spacing: 8 * s) {
            if annual.trialDays > 0 {
                timelineRow("Today, every feature unlocks", live: true, s: s)
                timelineRow("Days 1 to \(annual.trialDays), train free. Cancel anytime", live: false, s: s)
                timelineRow("Day \(annual.trialDays), \(annual.priceText)/year begins. Under $5 a month",
                            live: false, s: s)
            } else {
                timelineRow("Today, every feature unlocks", live: true, s: s)
                timelineRow("One payment, \(annual.priceText) for the whole year. Under $5 a month",
                            live: false, s: s)
                timelineRow("Renews yearly. Cancel anytime in Settings", live: false, s: s)
            }
        }
        .background(alignment: .topLeading) {
            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(width: 1.5)
                .offset(x: 2.75)
                .padding(.vertical, 9 * s)
        }
        .accessibilityElement(children: .combine)
    }

    private func timelineRow(_ text: String, live: Bool, s: CGFloat) -> some View {
        HStack(spacing: 9 * s) {
            Circle()
                .fill(live ? Theme.purple : .white.opacity(0.38))
                .frame(width: 7, height: 7)
                .background(Circle().fill(Color(hex: "141210")).frame(width: 11, height: 11))
                .shadow(color: live ? Theme.purple.opacity(0.8) : .clear, radius: 5)
            Text(text)
                .font(.rounded((Theme.FontSize.caption - 0.5) * s, weight: .medium))
                .foregroundStyle(.white.opacity(live ? 0.9 : 0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The plan pair — two quiet capsules, yearly staged to win

    private func planRow(_ s: CGFloat) -> some View {
        // ONE glass track, one gliding thumb (the app's SegmentedCapsule grammar, tuned for the
        // film): the white thumb springs between the two plans instead of two pills trading
        // fills — motion carries the selection, nothing blinks.
        HStack(spacing: 0) {
            planSegment(offering.annual, s: s)
            planSegment(offering.monthly, s: s)
        }
        .padding(4)
        .background(Capsule().fill(Color.black.opacity(0.28)))
        .overlay(Capsule().stroke(.white.opacity(0.22)))
        .overlay(alignment: .topLeading) {
            // The yearly's tag rides the track's edge — a detail, not a shout. With the trial
            // retired (owner call 2026-08-20) it carries the savings instead; if a store-side
            // trial ever returns, the store's number wins again.
            if paywall.pricingIsLive {
                Text(offering.annual.trialDays > 0
                     ? "\(offering.annual.trialDays) DAYS FREE"
                     : "SAVE \(offering.annualSavingsPercent)%")
                    .font(.rounded(8, weight: .heavy)).tracking(0.8)
                    .foregroundStyle(Theme.inkOnFixedLight)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.proLavender))
                    .offset(x: 14, y: -9)
            }
        }
    }

    private func planSegment(_ p: PaywallProduct, s: CGFloat) -> some View {
        let isSelected = p.period == selected
        return Button {
            guard !isSelected else { return }
            selected = p.period
            Haptics.selection()
        } label: {
            VStack(spacing: 1) {
                Text(p.isAnnual ? "Yearly" : "Monthly")
                    .font(.rounded(Theme.FontSize.caption * s, weight: .bold))
                if paywall.pricingIsLive {
                    Text(p.isAnnual ? "\(p.priceText)/yr" : "\(p.priceText)/mo")
                        .font(.rounded((Theme.FontSize.label + 1) * s, weight: .medium))
                        .opacity(isSelected ? 0.66 : 0.55)
                }
            }
            .foregroundStyle(isSelected ? Theme.inkOnFixedLight : .white.opacity(0.9))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9 * s)
            .background {
                if isSelected {
                    Capsule().fill(.white)
                        .matchedGeometryEffect(id: "planThumb", in: planThumb)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86),
                   value: selected)
        .accessibilityLabel(
            p.isAnnual ? "Yearly plan, \(p.priceText) per year"
                       : "Monthly plan, \(p.priceText) per month")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: The feature popup — a floating card that springs up over the film

    private func dismissFeatures() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.9)) {
            showFeatures = false
        }
    }

    private var featurePopup: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { dismissFeatures() }
                .transition(.opacity)
                .accessibilityLabel("Dismiss")
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                // Title CENTERED on the card (owner call); the close chip overlays the trailing
                // edge so the title's centering is true, not pushed off-axis by the X.
                Text("Everything in Pro")
                    .font(.serif(22, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) {
                        Button { dismissFeatures() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(.white.opacity(0.1)))
                        }
                        .buttonStyle(PressableScaleStyle(scale: 0.92))
                        .accessibilityLabel("Close")
                    }
                    .padding(.bottom, 2)
                PaywallFeatureList(pop: true)
            }
            .padding(Theme.Space.lg)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(hex: "232120")))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.14)))
            .shadow(color: Theme.purple.opacity(0.22), radius: 30, y: 14)
            .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            .padding(.horizontal, Theme.Space.lg)
            .transition(.scale(scale: 0.94, anchor: .bottom)
                .combined(with: .opacity)
                .combined(with: .offset(y: 28)))
        }
    }

    /// Drop the film, then dismiss on the next runloop tick — by the time the cover starts
    /// moving, the page is solid charcoal and the slide-down is cheap and clean.
    private func exitPaywall() {
        withAnimation(.easeOut(duration: 0.1)) { dismissing = true }
        DispatchQueue.main.async { dismiss() }
    }

    private var closeButton: some View {
        Button { exitPaywall() } label: {
            Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(PressableScaleStyle(scale: 0.92))
        .padding(.trailing, Theme.Space.md)
        .accessibilityLabel("Close")
    }
}

// MARK: - The film, looping

/// The paywall's own film (`PaywallVideo.mp4`, owner-delivered 2026-08-20): muted, at its natural pace,
/// looping only its first 11.8 seconds — the closing title card fades in ~12.2s and never enters
/// the cycle, so the film's wordmark never collides with the paywall's own headline. Reduce
/// Motion: a single golden-hour still (11.5s), no playback. The welcome's film view plays once
/// WITH sound; this one is atmosphere, so it must never touch the audio session.
private struct PaywallFilmBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // The film's own opening frame holds until the player attaches (or forever, if the
            // asset is missing) — the paywall never flashes black.
            Image("PaywallPoster")
                .resizable().scaledToFill()
            FilmLoopView(reduceMotion: reduceMotion)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

private struct FilmLoopView: UIViewRepresentable {
    let reduceMotion: Bool

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var looper: AVPlayerLooper?
        var resumeObserver: NSObjectProtocol?
        deinit { if let resumeObserver { NotificationCenter.default.removeObserver(resumeObserver) } }
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        guard let url = Bundle.main.url(forResource: "PaywallVideo", withExtension: "mp4") else { return view }
        view.playerLayer.videoGravity = .resizeAspectFill
        let reduceMotion = reduceMotion
        // Deferred one runloop turn, same as the welcome: AVFoundation setup must not sit on the
        // presenting animation's first frame.
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            view.playerLayer.player = player
            if reduceMotion {
                player.insert(item, after: nil)
                player.seek(to: CMTime(seconds: 11.5, preferredTimescale: 600))
            } else {
                // Loop 0–11.8s: the closing card fades in ~12.2s and never enters the cycle.
                let range = CMTimeRange(start: .zero,
                                        duration: CMTime(seconds: 11.8, preferredTimescale: 600))
                view.looper = AVPlayerLooper(player: player, templateItem: item, timeRange: range)
                player.play()
                // A backgrounded AVPlayerLayer pauses; without this the film returns frozen.
                view.resumeObserver = NotificationCenter.default.addObserver(
                    forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
                ) { [weak player] _ in
                    player?.play()
                }
            }
        }
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {}
}

/// Staggered entrance for the paywall's sections — opacity + a small rise, never layout. Inert
/// under Reduce Motion (content simply appears).
struct PaywallReveal: ViewModifier {
    let shown: Bool
    let delay: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.9).delay(delay),
                       value: shown)
    }
}

extension View {
    func reveal(_ shown: Bool, delay: Double, reduceMotion: Bool) -> some View {
        modifier(PaywallReveal(shown: shown, delay: delay, reduceMotion: reduceMotion))
    }
}

#Preview {
    PaywallView(feature: .aiRead)
        .environment(PaywallController(isPro: false))
}
