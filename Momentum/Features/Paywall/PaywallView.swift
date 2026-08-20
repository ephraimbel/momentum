import SwiftUI
import AVFoundation

/// The Pro paywall (PRD §10) — "The Film" (owner pick 2026-08-20, from the paywall study): the
/// brand film plays as a muted loop behind one serif statement, an honest trial
/// timeline, and the checkout. No feature grid on the wall — the film sells the feeling, a quiet
/// "Everything in Pro" sheet answers the detail question, and the loop is trimmed to end BEFORE
/// the film's closing title card so its wordmark never fights the headline. **Trust stays a
/// feature:** both plans one tap apart, plain renewal terms before purchase, one-tap restore.
/// Onboarding's (soft) gate uses the two-page `OnboardingPaywallFlow`; both are assembled from
/// the same `PaywallComponents`.
struct PaywallView: View {
    /// The locked feature that brought the user here — logged, and frames nothing visually: the
    /// film is the same story for every door.
    var feature: Feature = .aiCoach
    /// Hard placement: no close affordance, no swipe-away — the only ways forward are starting
    /// the trial, subscribing, or restoring. Contextual gates elsewhere stay dismissible; trust
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
                    .reveal(revealed, delay: 0.05, reduceMotion: reduceMotion)
                // Two plain sentences, no dash — the owner's voice rule (2026-07-30).
                Text("Plans built by runners, for runners.\nAround your body, your goal, your life.")
                    .font(.serif((Theme.FontSize.caption + 3) * s, weight: .medium))
                    .foregroundStyle(.white.opacity(0.74))
                    .fixedSize(horizontal: false, vertical: true)
                    .reveal(revealed, delay: 0.12, reduceMotion: reduceMotion)

                timeline(s)
                    .padding(.top, Theme.Space.sm * s)
                    .reveal(revealed, delay: 0.2, reduceMotion: reduceMotion)

                planRow(s)
                    .padding(.top, Theme.Space.sm * s)
                    .reveal(revealed, delay: 0.28, reduceMotion: reduceMotion)

                Button { showFeatures = true } label: {
                    Text("Everything in Pro")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .underline()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
                .reveal(revealed, delay: 0.32, reduceMotion: reduceMotion)
                .accessibilityHint("Shows the full list of Pro features")
            }
            .padding(.horizontal, Theme.Space.xl)
        }
        .safeAreaInset(edge: .bottom) {
            PaywallCheckout(product: product, hard: hard, onEntitled: onEntitled)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.md)
                .reveal(revealed, delay: 0.36, reduceMotion: reduceMotion)
        }
        .background {
            // Half-and-half (owner call 2026-08-20): the film owns the TOP of the page and
            // dissolves into a solid warm-charcoal ground where the content lives — type on
            // solid ground, film as the crown. The seam is the app's own eased scrim curve, so
            // no visible line; one faint lavender pool breathes under the checkout.
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    Color(hex: "141210")
                    // The film dissolves via its own alpha MASK, not an overlay painted on top:
                    // a covering scrim leaves a visible edge where the film's frame ends, a
                    // continuous mask cannot. The stops mirror SoftScrim's easing — silent
                    // shoulder, swift middle, flat landing.
                    PaywallFilmBackground()
                        .frame(height: geo.size.height * 0.62)
                        .mask {
                            LinearGradient(stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.52),
                                .init(color: .black.opacity(0.95), location: 0.62),
                                .init(color: .black.opacity(0.82), location: 0.70),
                                .init(color: .black.opacity(0.6), location: 0.78),
                                .init(color: .black.opacity(0.36), location: 0.85),
                                .init(color: .black.opacity(0.16), location: 0.92),
                                .init(color: .black.opacity(0.04), location: 0.97),
                                .init(color: .clear, location: 1),
                            ], startPoint: .top, endPoint: .bottom)
                        }
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
        .sheet(isPresented: $showFeatures) { featureSheet }
        .onAppear {
            services.analytics.log(.paywallView(placement: feature.placement))
            SKANConversion.record(.paywallSeen)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { revealed = true }
        }
    }

    // MARK: The trial timeline — the honest three beats (Opal's confidence pattern)

    @ViewBuilder
    private func timeline(_ s: CGFloat) -> some View {
        if paywall.pricingIsLive, selected == .annual, product.trialDays > 0 {
            // A REAL timeline (the Opal confidence pattern, drawn properly): a hairline rail
            // joins the three beats, and only the live one glows lavender. The rail lives in the
            // VStack's BACKGROUND so it adopts the rows' height — as a ZStack sibling its
            // unconstrained height blew the whole stack open to fill the screen.
            VStack(alignment: .leading, spacing: 8 * s) {
                timelineRow("Today, every feature unlocks", live: true, s: s)
                timelineRow("Days 1 to \(product.trialDays), train free. Cancel anytime", live: false, s: s)
                timelineRow("Day \(product.trialDays), \(product.priceText)/year begins. Under $5 a month",
                            live: false, s: s)
            }
            .background(alignment: .topLeading) {
                Rectangle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 1.5)
                    .offset(x: 2.75)
                    .padding(.vertical, 9 * s)
            }
            .accessibilityElement(children: .combine)
        } else if paywall.pricingIsLive, selected == .monthly {
            timelineRow("Billed monthly at \(product.priceText). No trial, cancel anytime", live: true, s: s)
        } else {
            // Store prices not yet loaded — promise nothing numeric (pricing honesty rule).
            timelineRow("Every feature unlocks today", live: true, s: s)
        }
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
        HStack(spacing: Theme.Space.sm) {
            planPill(offering.annual, s: s)
            planPill(offering.monthly, s: s)
        }
    }

    private func planPill(_ p: PaywallProduct, s: CGFloat) -> some View {
        let isSelected = p.period == selected
        return Button {
            selected = p.period
            Haptics.selection()
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 5) {
                    Text(p.isAnnual ? "Yearly" : "Monthly")
                        .font(.rounded(Theme.FontSize.caption * s, weight: .bold))
                    if p.isAnnual, p.trialDays > 0, paywall.pricingIsLive {
                        Text("\(p.trialDays) DAYS FREE")
                            .font(.rounded(8, weight: .heavy)).tracking(0.6)
                            .foregroundStyle(Theme.inkOnFixedLight)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.proLavender))
                    }
                }
                if paywall.pricingIsLive {
                    Text(p.isAnnual ? "\(p.priceText)/yr" : "\(p.priceText)/mo")
                        .font(.rounded((Theme.FontSize.label + 1) * s, weight: .medium))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(isSelected ? Theme.inkOnFixedLight : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10 * s)
            .background(Capsule().fill(isSelected ? Color.white : Color.black.opacity(0.28)))
            .overlay(Capsule().stroke(.white.opacity(isSelected ? 0 : 0.28)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            p.isAnnual ? "Yearly plan, \(p.priceText) per year"
                       : "Monthly plan, \(p.priceText) per month")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: The detail sheet — the full feature list, off the wall

    private var featureSheet: some View {
        VStack(spacing: Theme.Space.md) {
            Text("Everything in Pro")
                .font(.serif(24, weight: .semibold)).foregroundStyle(Theme.ink)
                .padding(.top, Theme.Space.xl)
            PaywallFeatureList(scale: 1, boxed: true)
                .padding(.horizontal, Theme.Space.xl)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
        }
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
            .offset(y: shown || reduceMotion ? 0 : 14)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.55).delay(delay), value: shown)
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
