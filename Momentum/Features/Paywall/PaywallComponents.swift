import SwiftUI
import UserNotifications

// Shared building blocks for every paywall surface (2026-08-05 redesign): the contextual
// `PaywallView` and the three-page `OnboardingPaywallFlow` are different stagings of the same
// pieces — one background, one screenshot showcase, one plan picker, one checkout. Keeping them
// here means the two surfaces can never drift apart on pricing, trust copy, or store handling.

// MARK: - Background — warm charcoal with a quiet iridescent bloom

/// The paywall canvas (owner calls 2026-08-05, evening pass): warm-charcoal dark with the brand's
/// iridescence returned as a GLOW, not a wash — one blurred bloom that haloes the lockup and
/// headline, melting to pure charcoal by the time any reading or pricing happens. A faint echo
/// rises from the very bottom so the canvas has depth behind the CTA. `IridescentView` freezes
/// itself under Reduce Motion; the bloom is otherwise motion-free (opacity-static, no wander).
struct PaywallBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            // NO gaussian blur here (perf, 2026-08-05): a 3×3 MeshGradient interpolates smoothly
            // on its own (IridescentView already softens edge artifacts internally), and a
            // full-screen 70pt blur re-rendered at 30fps was the most expensive layer in the app —
            // it made returning to a presented paywall from the background visibly hitch. The
            // oversize + low opacity + mask deliver the same soft bloom for a fraction of a frame.
            IridescentView(intensity: 0.5, amplitude: 1.6, loop: 16)
                .scaleEffect(1.6)
                .opacity(0.34)
                .mask(
                    ZStack {
                        RadialGradient(colors: [.white, .clear],
                                       center: UnitPoint(x: 0.5, y: 0.10),
                                       startRadius: 10, endRadius: 420)
                        LinearGradient(stops: [.init(color: .clear, location: 0.82),
                                               .init(color: .white.opacity(0.35), location: 1.0)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                )
                // Flatten the animating mesh + two-gradient mask into one Metal composite — as
                // plain layers, every 30fps tick re-ran the full-screen mask on the CPU
                // compositor (perf audit 2026-08-13).
                .drawingGroup()
        }
        .ignoresSafeArea()
    }
}

// MARK: - Feature list — built into the page, one honest line each

/// Everything Pro unlocks, organized to eight one-liners (related capabilities share a row), in
/// two stagings (owner calls 2026-08-05): the flow's opener sets purple glyphs and ink lines
/// straight on the canvas (`boxed: false` — no card, no checkmarks; Apple-feature-moment
/// restraint), while the MAIN paywall wears the classic boxed checklist (`boxed: true` — surface
/// card, hairline rows, route checkmarks; the structure the owner asked back).
// Held to EIGHT rows so every paywall layout keeps fitting an SE without truncating or
// scrolling. Merge, don't append.
struct PaywallFeatureList: View {
    var scale: CGFloat = 1
    /// The main paywall's card staging; default is the flow's on-canvas staging.
    var boxed = false

    private static let features: [(String, String)] = [
        ("figure.run", "Your full adaptive training plan"),
        ("brain.head.profile", "Coach chat & post-run reads"),
        ("fork.knife", "Fueling & calorie tracking"),
        ("gauge.with.needle", "Pace insights & session reviews"),
        ("waveform.path.ecg", "Recovery & injury-aware training"),
        ("flag.checkered", "Race predictions, 5K to marathon"),
        ("chart.xyaxis.line", "Analytics, history & records"),
        ("applewatch", "Watch, voice coach & share styles"),
    ]

    var body: some View {
        if boxed { boxedList } else { openList }
    }

    /// On-canvas staging: purple glyph + one line of ink, generous air, nothing else.
    private var openList: some View {
        VStack(alignment: .leading, spacing: (Theme.Space.md + 1) * scale) {
            ForEach(Array(Self.features.enumerated()), id: \.offset) { _, item in
                HStack(spacing: Theme.Space.md) {
                    Image(systemName: item.0)
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.route)
                        .frame(width: 26)
                    rowText(item.1, size: 15)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Card staging: the classic checklist — surface panel, hairline rows, route checkmarks.
    private var boxedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.features.enumerated()), id: \.offset) { i, item in
                if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                HStack(spacing: Theme.Space.sm + 2) {
                    Image(systemName: item.0)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                        .frame(width: 22)
                    rowText(item.1, size: 14)
                    Spacer(minLength: Theme.Space.xs)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .black)).foregroundStyle(Theme.route)
                }
                .padding(.vertical, (Theme.Space.sm + 1) * scale)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.surface.opacity(0.75))   // a touch translucent, so the bloom breathes through
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.hairline)
        }
    }

    private func rowText(_ s: String, size: CGFloat) -> some View {
        Text(s)
            .font(.rounded(size, weight: .semibold)).foregroundStyle(Theme.ink)
            // Scale floor 0.9, NOT 0.7: with the deeper floor SwiftUI spuriously engaged it on
            // two rows that fit fine — they rendered at ~75% while their neighbors sat at 100%
            // (seen 2026-08-05, custom-font ideal-width rounding). 0.9 still absorbs the SE's
            // narrower column, and a spurious engage at 0.9 is imperceptible.
            .lineLimit(1).minimumScaleFactor(0.9)
            .layoutPriority(1)
    }
}

// MARK: - Showcase — a fanned deck of iPhones, swiped through by hand

/// The auto-play dwell's identity: which card is centered, and whether the deck is currently the
/// athlete's to move. Either changing restarts the dwell, so a touch cancels the pending advance
/// and releasing it starts the count again from zero.
private struct AutoPlayTick: Equatable {
    var slide: Int
    var idle: Bool
}

/// The app shown, not described: a DECK of device mocks — the onboarding notification mock's
/// titanium-rail hardware — fanned like a hand of cards, each glass carrying one real DARK
/// screenshot (owner-captured, real status chrome and Dynamic Island in every frame). The
/// centered device rides full-size; its neighbors tilt outward, sink, and fade at the screen
/// edges. Every transform is driven CONTINUOUSLY by scroll position (`visualEffect`), so the
/// deck answers the thumb mid-swipe rather than snapping after it (owner ask 2026-08-11,
/// replacing the single still-device crossfade of 2026-08-05). Auto-advance ping-pongs the deck
/// slowly; a manual swipe restarts the dwell. Reduce Motion: no auto-play, swiping still works.
///
/// The 2026-08-05 "never page the whole phone" lesson was about TabView clipping the drop
/// shadow to a seam — this deck pages in a ScrollView with `scrollClipDisabled()`, so shadows
/// and fanned corners render unclipped into the charcoal.
// Assets live in Assets.xcassets/PaywallShots — 1080px-wide dark captures supplied by the owner
// (2026-08-05): Today's 3D map, the plan board, readiness, coach zones, fuel, the globe.
struct PaywallShowcase: View {
    /// Device height in points; everything else scales off it.
    var height: CGFloat = 440
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The centered card, fed by `scrollPosition` — nil only before first layout.
    @State private var slide: Int? = 0
    /// Auto-advance direction; flips at the deck's ends so the show never does a 9-card flyback.
    @State private var forward = true
    /// Live scroll phase. Auto-advance must never write `slide` while the thumb (or the
    /// deceleration it handed off to) owns the deck: a programmatic scroll target landing
    /// mid-gesture is what made a swipe jump to a seemingly random card (owner report
    /// 2026-08-15). Idle is the only phase in which the show may take a turn.
    @State private var scrollPhase: ScrollPhase = .idle

    private static let slides = [
        "PaywallShotToday", "PaywallShotPlan", "PaywallShotProgress",
        "PaywallShotVitals", "PaywallShotSleep", "PaywallShotCoach",
        "PaywallShotLog", "PaywallShotFuel", "PaywallShotGlobe",
    ]

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            deck
                // Auto-play. `.task` dies with the view (nothing to clean up); the id restarts
                // the dwell on every advance — including the athlete's own swipes. Keying on the
                // phase too means the moment a finger lands the pending advance is cancelled, and
                // a fresh dwell only begins once the deck is idle again in the athlete's hands.
                .task(id: AutoPlayTick(slide: slide ?? 0, idle: scrollPhase == .idle)) {
                    guard !reduceMotion, scrollPhase == .idle else { return }
                    try? await Task.sleep(for: .seconds(3.0))
                    // BOTH halves of this guard are load-bearing; neither is a formality.
                    // `try?` swallows the CancellationError, so a superseded task keeps running
                    // right past the sleep and would still write `slide` — two dwells racing to
                    // move the deck was itself a source of the "jumps to a random card" report.
                    // And the thumb can take over mid-dwell without moving a whole card, so
                    // `slide` never changes, the id never flips, and nothing cancels us at all.
                    guard !Task.isCancelled, scrollPhase == .idle else { return }
                    let i = slide ?? 0
                    var direction = forward
                    if i >= Self.slides.count - 1 { direction = false }
                    if i <= 0 { direction = true }
                    forward = direction
                    withAnimation(.easeInOut(duration: 0.55)) { slide = i + (direction ? 1 : -1) }
                }
            pageDots
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A tour of the app's screens")
        .accessibilityAdjustableAction { direction in
            let n = Self.slides.count
            let i = slide ?? 0
            slide = direction == .increment ? min(i + 1, n - 1) : max(i - 1, 0)
        }
    }

    /// The deck itself: view-aligned paging with the neighbors peeking either side. Each card's
    /// tilt/scale/fade is a pure function of its distance from the viewport's center, evaluated
    /// per frame by `visualEffect` — no state, no animation curves to fall out of sync with the
    /// finger. `contentMargins` centers the first and last cards so the deck never parks a card
    /// half-off the edge.
    private var deck: some View {
        let h = height
        let w = h * (300.0 / 640.0)
        // One card-to-card distance. The fan math normalizes by THIS, not the screen width, so a
        // card one slot out lands at exactly t = ±1 on every phone — the deck reads identically
        // on an SE and a Pro Max instead of the small screen getting a softer fan.
        let slot = w + Theme.Space.md
        // The sink rides the deck's own scale (≈18pt at the 6.1" reference height) so condensed
        // decks on short phones don't drop their neighbors disproportionately far.
        let sink = h * 0.036
        return GeometryReader { geo in
            ScrollView(.horizontal) {
                // Lazy, deliberately: a plain HStack realized all nine device cards at once — nine
                // full-screen PNG decodes and nine shadow passes on the page's FIRST frame, which
                // was most of the onboarding paywall's arrival jank (perf audit 2026-08-13). Lazy
                // keeps only the on-screen fan alive; the fade floor below never hides a card
                // fully, but cards beyond the viewport are simply not realized.
                LazyHStack(spacing: Theme.Space.md) {
                    ForEach(Array(Self.slides.enumerated()), id: \.offset) { i, name in
                        deviceCard(name, w: w, h: h)
                            .visualEffect { content, proxy in
                                let container = proxy.bounds(of: .scrollView(axis: .horizontal))?.width
                                    ?? proxy.size.width
                                let mid = proxy.frame(in: .scrollView(axis: .horizontal)).midX
                                // 0 at dead center, ±1 by the time a card sits one slot out.
                                let t = max(-1, min(1, (mid - container / 2) / slot))
                                return content
                                    // The fan: neighbors pivot around a point just below the
                                    // deck (like cards held in a hand), sink a touch, shrink,
                                    // and fade — the centered card alone stands full and bright.
                                    .rotationEffect(.degrees(8 * t), anchor: .init(x: 0.5, y: 1.3))
                                    .offset(y: sink * abs(t))
                                    .scaleEffect(1 - 0.13 * abs(t), anchor: .bottom)
                                    .opacity(1 - 0.45 * abs(t))
                            }
                            .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            // `limitBehavior: .always` — one card per gesture. Plain `.viewAligned` carries the
            // fling's momentum, so a normal-speed flick crossed three or four devices at once and
            // the deck felt impossible to aim (owner report 2026-08-15). Capping the travel makes
            // every swipe land exactly one card over, in both directions.
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollPosition(id: $slide)
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, phase in scrollPhase = phase }
            // Shadows, tilted corners, and the sunk neighbors all draw outside the row's bounds —
            // clipping any of them re-creates the TabView seam this design exists to avoid.
            .scrollClipDisabled()
            .contentMargins(.horizontal, max(0, (geo.size.width - w) / 2), for: .scrollContent)
        }
        .frame(height: h)
    }

    /// One device of the deck — the shared titanium-rail hardware with a single capture in the
    /// glass. Radii scale from the onboarding mock (300×640, 60/52) so all our hardware reads
    /// the same.
    private func deviceCard(_ name: String, w: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: h * (60.0 / 640.0), style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.38), Color(white: 0.16)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))   // titanium rail
            .overlay {
                // `.medium` interpolation: the shots ship pre-downsampled to ~the glass's own pixel
                // size (720 wide, 2026-08-13), so the near-1:1 draw gains nothing from Lanczos —
                // `.high` was pure GPU cost across every card of the fan.
                Image(name)
                    .resizable().interpolation(.medium).scaledToFill()
                    // Top-aligned: the tiny aspect difference between capture and glass crops off
                    // the BOTTOM edge (under the home indicator), never the status bar — the
                    // island always reads complete.
                    .frame(width: w - 7, height: h - 7, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: h * (52.0 / 640.0), style: .continuous))
                    .padding(3.5)   // bezel thickness
            }
            .frame(width: w, height: h)
            // A soft drop into the charcoal so each device sits IN the page; a card's fade dims
            // its shadow with it, so the fanned edges never puddle darkness on their neighbors.
            .shadow(color: .black.opacity(0.5), radius: 22, y: 12)
    }

    /// Nine dots, the current one stretched — quiet, monochrome.
    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<Self.slides.count, id: \.self) { i in
                Capsule()
                    .fill(i == (slide ?? 0) ? Theme.ink : Theme.ink.opacity(0.22))
                    .frame(width: i == (slide ?? 0) ? 16 : 5, height: 5)
            }
        }
        .animation(reduceMotion ? nil : Motion.lively, value: slide)
    }
}

// MARK: - Plan pair — Monthly beside Yearly, and Yearly wins

/// The two plans side by side, staged so the annual is the obvious choice (owner call 2026-08-05,
/// after the Cal AI reference): the trial badge rides the yearly card's top edge, its sub-line
/// spells out the per-month equivalence and the savings, and the monthly card's own sub-line
/// plainly says what it lacks. Trust rules unchanged: placeholder pricing is never shown as a
/// price, and the badge is suppressed until the store's trial length is real.
struct PlanPairPicker: View {
    let offering: PaywallOffering
    let pricingIsLive: Bool
    @Binding var selected: PaywallProduct.Period
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            card(offering.monthly, period: .monthly)
            card(offering.annual, period: .annual)
        }
        // Breathing room for the badge that overhangs the yearly card's top edge.
        .padding(.top, 9)
    }

    private func card(_ p: PaywallProduct, period: PaywallProduct.Period) -> some View {
        let isSelected = selected == period
        return Button {
            guard selected != period else { return }
            Haptics.light()
            withAnimation(reduceMotion ? nil : Motion.lively) { selected = period }
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.xs * scale) {
                HStack {
                    Text(p.isAnnual ? "Yearly" : "Monthly")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).tracking(0.4)
                        .foregroundStyle(Theme.inkSecondary)
                    Spacer()
                    selector(on: isSelected)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    // Never present a placeholder as the price. Until the store's offering lands,
                    // `p.priceText` is a US-dollar constant that would be wrong for any other
                    // storefront and would survive a price change — so show a dash instead.
                    Text(pricingIsLive ? p.priceText : "—")
                        .font(.display(22 * scale, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                    Text(p.isAnnual ? "/ yr" : "/ mo")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                }
                // The sell, in one quiet line each: yearly leads with what a month costs on it and
                // the discount; monthly admits it carries no trial. A savings percentage computed
                // from placeholder numbers is just as wrong as the numbers themselves — suppressed
                // with the price.
                Text(subline(p))
                    .font(.rounded(Theme.FontSize.label, weight: .semibold))
                    .foregroundStyle(p.isAnnual ? Theme.ink : Theme.inkTertiary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, (Theme.Space.sm + 3) * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                shape.fill(Theme.surface)
                shape.strokeBorder(isSelected ? Theme.ink : Theme.hairline,
                                   lineWidth: isSelected ? 1.5 : 1)
            }
            // The trial badge overhangs the yearly card's top edge, Cal AI-style — data-driven,
            // never promised off placeholder pricing.
            .overlay(alignment: .top) {
                if p.isAnnual, p.trialDays > 0, pricingIsLive {
                    Text("\(p.trialDays) DAYS FREE")
                        .font(.rounded(9, weight: .black)).tracking(1.2).foregroundStyle(Color(hex: "0E0E12"))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.route))
                        .offset(y: -9)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(isSelected ? "" : "Selects the \(p.isAnnual ? "yearly" : "monthly") plan")
    }

    private func subline(_ p: PaywallProduct) -> String {
        guard pricingIsLive else { return "Pricing unavailable" }
        if p.isAnnual {
            let perMonth = p.perMonthText ?? PaywallOffering.standard.annual.perMonthText ?? ""
            return "\(perMonth) · save \(offering.annualSavingsPercent)%"
        }
        return "No trial"
    }

    private func selector(on: Bool) -> some View {
        ZStack {
            // Unselected ring at inkTertiary, not hairline: on the charcoal card a hairline ring
            // all but vanished, so Monthly read as a dead panel instead of a choice (2026-08-11).
            Circle().stroke(on ? Theme.ink : Theme.inkTertiary, lineWidth: 1.5)
            if on {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .black)).foregroundStyle(Theme.background)
                    .frame(width: 22, height: 22).background(Circle().fill(Theme.ink))
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            }
        }
        .frame(width: 22, height: 22)
    }
}

// MARK: - Checkout — the CTA, the trust copy, and every store outcome

/// The bottom of every paywall: the "no payment due now" reassurance, the primary CTA, the
/// store-unreachable escape (hard gates only), and the one-line honest fine print. Owns the whole
/// purchase state machine — pricing retry, cancellation silence, failure alerts with Restore,
/// entitlement hand-off — so no paywall surface ever reimplements store handling.
struct PaywallCheckout: View {
    let product: PaywallProduct
    /// Hard placement (onboarding + relaunch gate): no dismissal path exists, so after two genuine
    /// store failures the deferral escape appears. Contextual placements never show it.
    var hard: Bool = false
    /// Called INSTEAD of dismissing when the athlete becomes entitled — see PaywallView's note on
    /// cover-swapping hosts. Nil means "dismiss whatever is presenting us".
    var onEntitled: (() -> Void)?

    @Environment(PaywallController.self) private var paywall
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var working = false
    /// Set when a restore finds nothing to restore — the user gets a plain confirmation rather
    /// than a button that silently does nothing.
    @State private var nothingToRestore = false
    /// Set when a purchase genuinely fails (not when the athlete cancels) — a tap that does
    /// nothing and says nothing is how you lose someone who was trying to pay.
    @State private var purchaseError: String?
    /// Store-side failures this session: a pricing fetch that came back empty, or a purchase the
    /// store rejected. A CANCELLED purchase is not a failure and never counts, so the escape below
    /// can't be conjured up by opening the StoreKit sheet and backing out of it twice.
    @State private var storeFailures = 0
    /// Two store failures is enough to call it: on a HARD gate, offer a way past it. Not a bypass —
    /// `onboardingGatePending` is untouched, so the wall returns on the next launch.
    private var storeUnreachable: Bool { hard && storeFailures >= 2 }

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            // The Cal AI-style trust line: when the selected plan starts with a free trial, say
            // out loud that today costs nothing. Suppressed with placeholder pricing (the trial
            // length is a promise too) and for the trial-less monthly.
            if product.trialDays > 0, paywall.pricingIsLive {
                Label("No payment due now", systemImage: "checkmark")
                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
            }
            cta
            if storeUnreachable { storeUnreachableEscape }
            fineprint
        }
        .alert("Nothing to restore", isPresented: $nothingToRestore) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("We couldn't find a past purchase on this Apple ID.")
        }
        // Cancellation stays silent — this only fires on a real failure, and always offers
        // Restore, since "charged but not entitled" is the case where saying nothing is worst.
        .alert("Purchase didn't go through",
               isPresented: Binding(get: { purchaseError != nil },
                                    set: { if !$0 { purchaseError = nil } })) {
            Button("Try again") { purchaseError = nil }
            Button("Restore") { purchaseError = nil; restore() }
            Button("Not now", role: .cancel) { purchaseError = nil }
        } message: {
            Text(purchaseError ?? "")
        }
        .interactiveDismissDisabled(working || hard)
    }

    /// Compact primary action — 48pt, quieter than the 56pt OversizedButton so the content above
    /// keeps the visual weight.
    private var cta: some View {
        Button {
            Haptics.light()
            Task {
                working = true
                // Pricing not live means the offering is still placeholders — there is no real
                // package to buy, so retry the fetch instead of firing a purchase that can only
                // fail. Succeeds → the athlete taps again and buys at the store's real price.
                guard paywall.pricingIsLive else {
                    await paywall.reloadPricing()
                    working = false
                    if !paywall.pricingIsLive {
                        storeFailures += 1
                        purchaseError = "We couldn't load pricing from the App Store. Check your connection and try again."
                    }
                    return
                }
                let outcome = await paywall.purchase(product)
                working = false
                switch outcome {
                case .purchased:
                    services.analytics.log(.paywallConvert(product: product.isAnnual ? "annual" : "monthly"))
                    // The reminder page 2 of the onboarding flow promises. Scheduled only when a
                    // trial actually started, and harmless without notification permission (iOS
                    // simply won't deliver it).
                    if product.trialDays > 0 {
                        NotificationService.scheduleTrialReminder(
                            trialDays: product.trialDays,
                            renewText: "\(product.priceText)/\(product.isAnnual ? "year" : "month")")
                    }
                case .cancelled:
                    break                                   // they changed their mind — say nothing
                case .failed(let message):
                    storeFailures += 1
                    purchaseError = message
                }
                if paywall.isPro { finishEntitled() }
            }
        } label: {
            Text(ctaTitle)
                .font(.rounded(Theme.FontSize.body, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 48)
                .foregroundStyle(Theme.background)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.ink))
        }
        .buttonStyle(.plain)
        .opacity(working ? 0.4 : 1)
        .disabled(working)
    }

    private var ctaTitle: String {
        if working { return "One moment…" }
        // Don't quote a price we haven't confirmed with the store, and don't promise a trial
        // length that came from a placeholder either.
        guard paywall.pricingIsLive else { return "Retry" }
        return product.trialDays > 0
            ? "Start my \(product.trialDays)-day free trial"
            : "Continue · \(product.priceText)\(product.isAnnual ? "/year" : "/month")"
    }

    /// One tiny line: honest renewal terms + the required links, nothing taller.
    private var fineprint: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(renewalTerms)
            Text("·")
            Button("Restore") { restore() }
            Text("·")
            Button("Terms") { open("https://momentumco.app/terms") }
            Text("·")
            Button("Privacy") { open("https://momentumco.app/privacy") }
        }
        .font(.rounded(10, weight: .medium))
        .foregroundStyle(Theme.inkTertiary)
        .lineLimit(1).minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity)
    }

    /// Plain-language renewal terms (the §10 honesty bar), one short line per plan.
    private var renewalTerms: String {
        // The fine print is the one place a wrong number is actually a claim about what we'll
        // charge — never build it from placeholder pricing.
        guard paywall.pricingIsLive else { return "Pricing unavailable · cancel anytime" }
        let per = product.isAnnual ? "yr" : "mo"
        if product.trialDays > 0 {
            return "\(product.trialDays) days free, then \(product.priceText)/\(per) · cancel anytime"
        }
        return "\(product.priceText)/\(per) · cancel anytime"
    }

    private func restore() {
        Task {
            working = true; _ = await paywall.restore(); working = false
            if paywall.isPro { finishEntitled() } else { nothingToRestore = true }
        }
    }

    /// Entitlement landed. A host that keeps its cover on screen for a following beat handles it
    /// via `onEntitled`; otherwise the presenting cover is dismissed, which is what every
    /// contextual gate wants.
    private func finishEntitled() {
        if let onEntitled { onEntitled() } else { dismiss() }
    }

    /// The only way past a hard gate that isn't a purchase — and it appears only once the store
    /// has actually failed twice. The wording is the whole point: this is a deferral, not a free
    /// pass, and saying so is cheaper than an athlete discovering it themselves next launch.
    private var storeUnreachableEscape: some View {
        Button {
            paywall.storeUnreachableDeferral = true
            dismiss()
        } label: {
            Text("Continue. We'll ask again next time")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func open(_ s: String) { if let url = URL(string: s) { openURL(url) } }
}
