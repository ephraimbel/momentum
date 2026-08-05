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

// MARK: - Showcase — a real iPhone, most of the screen, paging through the app

/// The app shown, not described: a large device mock — the onboarding notification mock's
/// titanium-rail hardware at near-full presence — paging through real DARK screenshots (owner-
/// captured, real status chrome and Dynamic Island in every frame, so the device reads as
/// genuinely on). No captions; the screens speak. Auto-advances; a swipe restarts the beat.
/// Reduce Motion: no auto-play, swiping still works.
// Assets live in Assets.xcassets/PaywallShots — 1080px-wide dark captures supplied by the owner
// (2026-08-05): Today's 3D map, the plan board, readiness, coach zones, fuel, the globe.
struct PaywallShowcase: View {
    /// Device height in points; everything else scales off it.
    var height: CGFloat = 440
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var slide = 0

    private static let slides = [
        "PaywallShotToday", "PaywallShotPlan", "PaywallShotProgress",
        "PaywallShotVitals", "PaywallShotSleep", "PaywallShotCoach",
        "PaywallShotLog", "PaywallShotFuel", "PaywallShotGlobe",
    ]

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            device
                .frame(maxWidth: .infinity)   // generous swipe target either side of the phone
                .contentShape(Rectangle())
                // Swipe to browse — the beat restarts via `.task(id:)`, so a manual swipe earns
                // the same full dwell before the show moves on.
                .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                    guard abs(v.translation.width) > 30 else { return }
                    let n = Self.slides.count
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
                        slide = v.translation.width < 0 ? (slide + 1) % n : (slide + n - 1) % n
                    }
                })
            // Auto-play. `.task` dies with the view (nothing to clean up); the id restarts the
            // clock on every advance.
            .task(id: slide) {
                guard !reduceMotion else { return }
                try? await Task.sleep(for: .seconds(3.0))
                withAnimation(.easeInOut(duration: 0.5)) { slide = (slide + 1) % Self.slides.count }
            }
            pageDots
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A tour of the app's screens")
        .accessibilityAdjustableAction { direction in
            let n = Self.slides.count
            slide = direction == .increment ? (slide + 1) % n : (slide + n - 1) % n
        }
    }

    /// ONE device, always still — only the glass changes. The screens crossfade inside the bezel
    /// with a whisper of scale (the incoming frame settles from 1.5% over, like a lens pulling
    /// focus) — transform-only, never layout, and no paging container anywhere, so the deep drop
    /// shadow renders unclipped into the charcoal (a TabView clipped it to a visible seam — owner
    /// report 2026-08-05). That stillness is what makes it read as a real phone, not a slideshow.
    /// Radii scale from the onboarding mock (300×640, 60/52) so all our hardware reads the same.
    private var device: some View {
        let h = height
        let w = h * (300.0 / 640.0)
        return RoundedRectangle(cornerRadius: h * (60.0 / 640.0), style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.38), Color(white: 0.16)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))   // titanium rail
            .overlay {
                ZStack {
                    ForEach(Array(Self.slides.enumerated()), id: \.offset) { i, name in
                        Image(name)
                            .resizable().interpolation(.high).scaledToFill()
                            // Top-aligned: the tiny aspect difference between capture and glass
                            // crops off the BOTTOM edge (under the home indicator), never the
                            // status bar — the island always reads complete.
                            .frame(width: w - 7, height: h - 7, alignment: .top)
                            .opacity(i == slide ? 1 : 0)
                            .scaleEffect(i == slide ? 1.0 : 1.015)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: slide)
                .clipShape(RoundedRectangle(cornerRadius: h * (52.0 / 640.0), style: .continuous))
                .padding(3.5)   // bezel thickness
            }
            .frame(width: w, height: h)
            // A deep, soft drop into the charcoal so the device sits IN the page, not on it.
            .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
    }

    /// Six dots, the current one stretched — quiet, monochrome.
    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<Self.slides.count, id: \.self) { i in
                Capsule()
                    .fill(i == slide ? Theme.ink : Theme.ink.opacity(0.22))
                    .frame(width: i == slide ? 16 : 5, height: 5)
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
            Circle().stroke(on ? Theme.ink : Theme.hairline, lineWidth: 1.5)
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
            : "Continue — \(product.priceText)\(product.isAnnual ? "/year" : "/month")"
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
            Text("Continue — we'll ask again next time")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func open(_ s: String) { if let url = URL(string: s) { openURL(url) } }
}
