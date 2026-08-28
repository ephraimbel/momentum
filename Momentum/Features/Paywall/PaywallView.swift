import SwiftUI

/// The Pro paywall (PRD §10) — "The Marquee" (owner call 2026-08-27, from the Bevel wall): a
/// BRIGHT, light page. One display headline, then an endless slow-scrolling list of what Pro
/// unlocks (glass icon tiles, a claim, one plain line each — it loops forever, fading at both
/// edges), two plan cards with the yearly staged to win, and the checkout. Every feature line is
/// ours and true. Trial-less since 2026-08-20; every trial branch stays data-driven off the
/// store's intro offer. **Trust stays a feature:** both plans one tap apart, plain renewal terms,
/// one-tap restore. Hosted as-is by `OnboardingPaywallFlow`; assembled from `PaywallComponents`.
struct PaywallView: View {
    /// The locked feature that brought the user here — logged, and frames nothing visually.
    var feature: Feature = .aiCoach
    /// Hard placement: no close affordance, no swipe-away.
    var hard: Bool = false
    /// Called INSTEAD of dismissing when the athlete becomes entitled — see PaywallCheckout.
    var onEntitled: (() -> Void)?

    @Environment(PaywallController.self) private var paywall
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selected: PaywallProduct.Period = .annual
    @State private var revealed = false

    private var offering: PaywallOffering { paywall.offering }
    private var product: PaywallProduct { selected == .annual ? offering.annual : offering.weekly }

    var body: some View {
        GeometryReader { geo in
            let s = min(1, max(0.82, geo.size.height / 852))
            content(s)
        }
    }

    private func content(_ s: CGFloat) -> some View {
        VStack(spacing: 0) {
            // The lockup stays CENTRED (owner call — left-set was tried on 2026-08-28 and
            // rejected). What made the centred version read as bland was never the words: it was
            // a bare stack of three same-weight elements. The eyebrow now sits in a raised glass
            // capsule — the app's own material, so it reads as a designed mark rather than
            // floating text — and the type block is set larger and tighter so the two beats lock
            // together instead of drifting apart.
            // No mark and no badge above the headline (owner call 2026-08-28 — a capsule read as
            // a sticker, and the app icon, while premium, simply cost rows). The reference wall
            // opens straight onto the headline and spends the saved height on FEATURES, which is
            // what a paywall is actually selling. Everything here is sized to give the marquee
            // its rows back.
            headline(s)
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, 30 * s)
                // The type sits IN light rather than on a flat field. The frame must be SQUARE and
                // wider than `endRadius` on every side, or the gradient is still coloured when it
                // meets the box and the "glow" renders as a hard-edged rectangle — which is
                // exactly what a background sized to the text's own bounds did.
                .background {
                    RadialGradient(colors: [Theme.purple.opacity(0.08), Theme.iridescent[1].opacity(0.05), .clear],
                                   center: .center, startRadius: 4, endRadius: 150)
                        .frame(width: 340, height: 340)
                        .allowsHitTesting(false)
                }
                .reveal(revealed, delay: 0.03, reduceMotion: reduceMotion)

            Text("A plan that adapts to you, every week.")
                .font(.rounded(15, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .padding(.top, 9)
                .reveal(revealed, delay: 0.06, reduceMotion: reduceMotion)

            // The marquee owns whatever height is left between the headline and the plan
            // cards; the cards hug the checkout below, so nothing floats mid-page.
            FeatureMarquee(reduceMotion: reduceMotion)
                .frame(maxHeight: .infinity)
                // Real air under the subtitle: at sm the half-faded top row crowded it and the
                // two blocks read as one run-on column.
                .padding(.top, 18)
                .reveal(revealed, delay: 0.08, reduceMotion: reduceMotion)

            planCards(s)
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, 14)   // room for the badge's overhang
                .reveal(revealed, delay: 0.14, reduceMotion: reduceMotion)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .bottom) {
            PaywallCheckout(product: product, hard: hard, onEntitled: onEntitled ?? { dismiss() })
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, Theme.Space.sm)
                .reveal(revealed, delay: 0.2, reduceMotion: reduceMotion)
        }
        .background {
            // The bright canvas with one soft aurora bloom behind the marquee — the Bevel wash,
            // in the lavender family. Static; never a wall of colour.
            PaywallBackground()
        }
        .overlay(alignment: .topLeading) { if !hard { closeButton } }
        // The paywall is a BRIGHT moment regardless of appearance (owner call 2026-08-27; it was
        // an unconditional dark film before). `.environment(\.colorScheme)`, NOT
        // `.preferredColorScheme` — the latter leaks the forced scheme to the presenter.
        .environment(\.colorScheme, .light)
        .onAppear {
            services.analytics.log(.paywallView(placement: feature.placement))
            SKANConversion.record(.paywallSeen)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { revealed = true }
        }
    }

    // MARK: The headline

    /// Two beats of display type, the second carrying the only colour in the type on this page.
    /// Every stop stays in the saturated mid band: an earlier ramp ended on a pale sky stop, so
    /// "faster." washed out against white exactly where the line should land hardest.
    private func headline(_ s: CGFloat) -> some View {
        // STATIC gradient (perf, 2026-08-28). The drifting ramp re-rastered the largest element
        // on the page 12 times a second for the paywall's whole life and was, measured alone,
        // ~8% of a core on the sim — for a 7s drift nobody noticed. The tiles are the show; the
        // headline stands still. (Reduce Motion needs no branch any more for the same reason.)
        headlineText(s, shift: 0)
            .multilineTextAlignment(.center)
            .lineSpacing(-4)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    /// Font and tracking are applied per RUN rather than to the composed view, so the result stays
    /// a `Text` — the gradient beat needs its own `foregroundStyle`, which only runs can carry.
    private func headlineText(_ s: CGFloat, shift: Double) -> Text {
        let f: Font = .display(34 * s, weight: .bold)
        let x: CGFloat = 0.28 * CGFloat(shift)
        let g = LinearGradient(
            colors: [Theme.purple, Color(hex: "9A7BF3"), Color(hex: "7C97EC"), Color(hex: "4E93D4")],
            startPoint: UnitPoint(x: -0.35 + x, y: 0), endPoint: UnitPoint(x: 1.15 + x, y: 0.9))
        return Text("Run smarter.\n").font(f).tracking(-1.2).foregroundStyle(Theme.ink)
            + Text("Race faster.").font(f).tracking(-1.2).foregroundStyle(g)
    }

    // MARK: Plan cards — the yearly staged to win

    private func planCards(_ s: CGFloat) -> some View {
        HStack(spacing: 12) {
            planCard(offering.annual, s: s)
            planCard(offering.weekly, s: s)
        }
    }

    private func planCard(_ p: PaywallProduct, s: CGFloat) -> some View {
        let isSelected = p.period == selected
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return Button {
            guard !isSelected else { return }
            Haptics.medium()   // a real press, not a tick
            if reduceMotion { selected = p.period }
            else { withAnimation(.spring(response: 0.36, dampingFraction: 0.72)) { selected = p.period } }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(p.isAnnual ? "Yearly" : "Weekly")
                        .font(.rounded(17, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 4)
                    ZStack {
                        Circle().strokeBorder(Theme.ink.opacity(0.18), lineWidth: 1.5).opacity(isSelected ? 0 : 1)
                        // The check springs in from small; the ring simply fades — a settle, not a pop.
                        Circle().fill(Theme.ink).scaleEffect(isSelected ? 1 : 0.5).opacity(isSelected ? 1 : 0)
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white).scaleEffect(isSelected ? 1 : 0.4).opacity(isSelected ? 1 : 0)
                    }
                    .frame(width: 24, height: 24)
                }
                if paywall.pricingIsLive {
                    // The yearly leads with its WEEKLY number (the two plans compare on one
                    // axis); the total it actually charges sits right under it — never only in
                    // the fine print (App Review 3.1.2: price and duration, together).
                    Text(p.isAnnual ? "\(perWeek(p))/wk" : "\(p.priceText)/wk")
                        .font(.rounded(19 * s, weight: .medium)).monospacedDigit().foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(p.isAnnual ? "\(p.priceText) billed yearly" : "Billed weekly")
                        .font(.rounded(12, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    Text("—").font(.rounded(19 * s, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    Text("Pricing loading").font(.rounded(12, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .raised(shape, selected: isSelected)
            // No scale between the two cards (polish pass 2026-08-28): the stroke alone says
            // "picked"; a shrunken sibling read as a lesser object rather than an equal option.
            .overlay(alignment: .top) {
                if p.isAnnual, paywall.pricingIsLive {
                    Text(offering.annual.trialDays > 0
                         ? "\(offering.annual.trialDays) DAYS FREE"
                         : "SAVE \(offering.annualSavingsPercent)%")
                        .font(.rounded(11, weight: .heavy)).tracking(0.5)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .raised(Capsule(), tone: .ink)
                        .offset(y: -13)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(RaisedPressStyle(scale: 0.97))
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.72), value: selected)
        .accessibilityLabel(p.isAnnual ? "Yearly plan, \(perWeek(p)) per week, \(p.priceText) billed yearly"
                                       : "Weekly plan, \(p.priceText) per week")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// "$3.60" from the store formatter's "$3.60 / wk" — never a number we haven't confirmed.
    private func perWeek(_ p: PaywallProduct) -> String {
        guard let text = p.perWeekText else { return "—" }
        return String(text.split(separator: "/").first ?? Substring(text)).trimmingCharacters(in: .whitespaces)
    }

    private var closeButton: some View {
        GlassCircleButton(systemName: "xmark", label: "Close") { dismiss() }
            .padding(.leading, Theme.Space.md)
            .padding(.top, Theme.Space.xs)
    }
}

// MARK: - The feature marquee

/// Everything Pro unlocks as an endless, slow vertical drift — and a real scroll: the athlete can
/// drag through it, and the drift resumes once the finger lifts. The list is drawn three times so
/// wrapping (jumping back by one list-height) never shows a seam. Each row enters with a
/// scroll-linked settle — it drifts in from the edge and brightens as it reaches the centre, no
/// scaling pops. Fades at both edges. Reduce Motion: no drift, plain rows, still scrollable.
struct FeatureMarquee: View {
    let reduceMotion: Bool
    /// Points per second — a slow, readable drift.
    var speed: Double = 24

    enum Art { case plan, coach, race, recovery, fuel, analytics, watch }
    struct Item { let art: Art; let tint: Color; let title: String; let line: String }
    static let items: [Item] = [
        .init(art: .plan, tint: Theme.purple, title: "Your adaptive plan",
              line: "Rebuilt around your recovery, every week."),
        .init(art: .coach, tint: Theme.Health.vitalsInk, title: "Coach chat & post-run reads",
              line: "Pace insights and honest verdicts."),
        .init(art: .race, tint: Theme.Health.temperatureInk, title: "Race predictions",
              line: "5K to marathon, from your real fitness."),
        .init(art: .recovery, tint: Theme.Health.recoveryInk, title: "Recovery & readiness",
              line: "Know when to push and when to rest."),
        .init(art: .fuel, tint: Theme.Health.strainInk, title: "Easy nutrition tracking",
              line: "Track food effortlessly with AI."),
        .init(art: .analytics, tint: Theme.Health.sleepInk, title: "Analytics, history & records",
              line: "Every run, every lift, every best."),
        .init(art: .watch, tint: Theme.purple, title: "Apple Watch & voice coach",
              line: "Guided workouts on your wrist, cues in your ear."),
    ]

    @State private var position = ScrollPosition(y: 0)
    @State private var offsetY: CGFloat = 0
    @State private var listHeight: CGFloat = 0
    @State private var phase: ScrollPhase = .idle
    @State private var lastTick: Date?
    // 30Hz, not 60: at 24pt/s a tick moves 0.8pt, invisible on a drift this slow, and every
    // tick invalidates the whole ScrollView — this one line was a third of the page's idle CPU.
    private let ticker = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        // Five stacked copies: two list-heights of runway either side of the middle band, so a
        // hard fling never reaches an end before the wrap below re-centres it. (Rows are cheap
        // when off-screen — see `MarqueeRow` — so the copies cost layout only, not animation.)
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                list.background(measure)
                ForEach(0..<4, id: \.self) { _ in list }
            }
        }
        .scrollPosition($position)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in offsetY = y }
        .onScrollPhaseChange { _, new in
            phase = new
            // The endless part (owner call): whenever the scroll comes to rest — after the
            // athlete's own swipe too — snap back by whole list-heights into the middle band.
            // Same pixels either side of the jump, so it reads as simply continuing.
            if new == .idle { recentre() }
        }
        .onReceive(ticker) { now in
            guard !reduceMotion, listHeight > 0 else { return }
            defer { lastTick = now }
            // Only drift while the athlete isn't touching or flinging it.
            guard phase == .idle, let last = lastTick else { return }
            let dt = min(0.05, now.timeIntervalSince(last))
            let y = wrapped(offsetY + CGFloat(speed * dt))
            position.scrollTo(y: y)
        }
        .onAppear {
            DispatchQueue.main.async { if listHeight > 0 { position.scrollTo(y: listHeight * 2) } }
        }
        .onChange(of: listHeight) { _, h in if h > 0 { position.scrollTo(y: h * 2) } }
        .mask(
            // Shallow at the top (0.22 hid most of a row), deeper at the bottom where rows slide
            // under the plan cards — the drift carries content upward, so that edge does the work.
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                   .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Everything in Pro")
        .accessibilityValue(Self.items.map { "\($0.title). \($0.line)" }.joined(separator: " "))
    }

    /// Fold any offset back into the middle band [2H, 3H) — the same rows, one copy over.
    private func wrapped(_ y: CGFloat) -> CGFloat {
        guard listHeight > 0 else { return y }
        var v = y
        while v >= listHeight * 3 { v -= listHeight }
        while v < listHeight * 2 { v += listHeight }
        return v
    }

    private func recentre() {
        guard listHeight > 0 else { return }
        let y = wrapped(offsetY)
        if y != offsetY { position.scrollTo(y: y) }
    }

    private var measure: some View {
        GeometryReader { g in Color.clear.onAppear { listHeight = g.size.height } }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(Self.items.enumerated()), id: \.offset) { _, item in
                MarqueeRow(item: item, reduceMotion: reduceMotion)
                    // Scroll-linked entrance: rows settle in from the edge and brighten as they
                    // reach the band's centre — opacity, a few points of x, a touch of brightness.
                    // Continuous and reversible, never a pop.
                    .visualEffect { content, proxy in
                        let h: CGFloat = proxy.bounds(of: .scrollView(axis: .vertical))?.height ?? 300
                        let half: CGFloat = h / 2
                        let mid: CGFloat = proxy.frame(in: .scrollView(axis: .vertical)).midY
                        let d: CGFloat = mid - half
                        let t: CGFloat = min(1, Swift.abs(d) / half)     // 0 centre … 1 edge
                        let fade: Double = 1 - 0.45 * Double(t * t)
                        let slide: CGFloat = reduceMotion ? 0 : 10 * t * t
                        let dim: Double = reduceMotion ? 0 : -0.04 * Double(t)
                        return content
                            .opacity(fade)
                            .offset(x: slide)
                            .brightness(dim)
                    }
            }
        }
    }

}

/// One marquee row. Its tile animates ONLY while the row is on screen (`onScrollVisibilityChange`
/// gate) — off-screen copies hold a static frame, so five stacked lists cost layout, not clocks.
private struct MarqueeRow: View {
    let item: FeatureMarquee.Item
    let reduceMotion: Bool
    @State private var onScreen = false

    private let side: CGFloat = 52

    var body: some View {
        HStack(spacing: 16) {
            // No pool of light under the tile and no tinted shadow (owner call 2026-08-28:
            // "the subtle glows behind the cards are doing more bad than good"). The object
            // carries its own presence; the ground stays clean.
            art.frame(width: side, height: side)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.rounded(17, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(item.line).font(.rounded(14.5, weight: .regular)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, 9)
        .onScrollVisibilityChange(threshold: 0.05) { onScreen = $0 }
    }

    /// Not every row wears a card. A ring inside a squircle is a box around a box, so recovery
    /// floats on its own light and simply runs bigger to hold the same weight in the column —
    /// which is what the reference wall does with its own recovery ring.
    @ViewBuilder
    private var art: some View {
        let tile = TileArt(art: item.art, tint: item.tint, animate: onScreen && !reduceMotion)
        if item.art.wearsCard {
            tile
                .scaleEffect(item.art.artScale)
                .frame(width: side, height: side)
                .background { card }
                .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
                .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
        } else {
            // Card-less arts are objects in their own right and draw at the row's full size —
            // the readiness puck is 50pt of real geometry, not a 30pt glyph scaled up.
            tile.frame(width: side, height: side)
        }
    }

    /// The card, tinted by its own row. A column of pure-white squircles reads as a spreadsheet;
    /// a faint wash of the domain colour low in the fill, a white rim up top and a tinted one
    /// below is what makes each tile feel like its own object.
    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return ZStack {
            shape.fill(LinearGradient(colors: [.white, Color(hex: "F6F7FB")],
                                      startPoint: .top, endPoint: .bottom))
            shape.fill(LinearGradient(colors: [.clear, item.tint.opacity(0.06)],
                                      startPoint: .center, endPoint: .bottom))
            // A quieter rim than the tiles used to wear: at lineWidth 1 and 0.20 tint the edge
            // read as drawn-on. The card should end in light, not in a line.
            shape.strokeBorder(LinearGradient(colors: [.white, .white.opacity(0.5), item.tint.opacity(0.05)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.6)
        }
    }
}

extension FeatureMarquee.Art {
    /// Recovery floats; everything else sits on a card.
    var wearsCard: Bool { self != .recovery }

    /// How proud the subject sits on its card. The fruit runs over the edge the way the reference
    /// wall's does — an object that breaks its frame reads as real, a contained one reads as an
    /// icon. UI fragments stay inside their card, because that IS the frame they live in.
    var artScale: CGFloat {
        switch self {
        case .fuel: 1.25
        case .race: 1.15
        default: 1.05
        }
    }
}

// MARK: - Tile art (small, slow, looping — each tile shows the thing, not an icon of the thing)

/// The marquee tiles' living glyphs. Every loop is driven by one `TimelineView` phase (0…1 over
/// its period) and built from opacity, trim, offset and scale on tiny shapes — no layout
/// changes. Reduce Motion: each art holds its finished frame.
private struct TileArt: View {
    let art: FeatureMarquee.Art
    let tint: Color
    /// False = hold the finished frame (off-screen row, or Reduce Motion) — no clock at all.
    let animate: Bool

    var body: some View {
        if !animate {
            frame(phase: 1)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                frame(phase: (t.truncatingRemainder(dividingBy: period)) / period)
                    // One Metal layer per tile: the arts are stacks of small shadowed shapes, and
                    // without this every shadow is its own offscreen pass on every frame.
                    // `drawingGroup` rasterises to the view's OWN bounds, and several arts draw
                    // past them (the plan's ↑ badge, the kcal pill, the inspect dot) — so the
                    // raster is padded out and pulled back in, which keeps layout identical and
                    // stops the edges being sliced off (owner caught this the first time).
                    .padding(16)
                    .drawingGroup()
                    .padding(-16)
            }
        }
    }

    private var period: Double {
        switch art {
        case .recovery: 4.2
        case .analytics: 4.0
        case .plan: 3.8
        case .coach: 3.6
        case .fuel: 3.4
        case .race: 3.2
        case .watch: 3.0
        }
    }

    private var glyphStyle: LinearGradient {
        LinearGradient(colors: [tint, tint.opacity(0.72)], startPoint: .top, endPoint: .bottom)
    }

    /// Ease in-out on a 0…1 ramp.
    private func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    // Each art gets its own function. Inlining them all in one `switch` is what pushed this file
    // into type-checker timeouts before; it also keeps every loop readable on its own.
    @ViewBuilder
    private func frame(phase: Double) -> some View {
        switch art {
        case .recovery:  recoveryArt(phase)
        case .plan:      planArt(phase)
        case .coach:     coachArt(phase)
        case .race:      raceArt(phase)
        case .fuel:      fuelArt(phase)
        case .analytics: analyticsArt(phase)
        case .watch:     watchArt(phase)
        }
    }

    /// Readiness, built as a PHYSICAL OBJECT: a white glass puck with the track set into it as
    /// a grey groove, a white margin between the ring and the puck's edge, and an arc that runs
    /// lime→deep green along its own length. That is what the reference does, and it is the
    /// opposite of every version before this one, which put the ring at the object's outer edge
    /// with an animated blur behind it (the owner's "glow behind the ring", now gone).
    ///
    /// Motion is one thing only: the arc sweeps in, holds, and releases. No bead, no breathing
    /// blur, no pulsing. A lit object that moves once reads as expensive; one that keeps moving
    /// reads as a loading spinner.
    private func recoveryArt(_ phase: Double) -> some View {
        // The sweep starts from a FLOOR, not from nothing: a readiness ring that opens each loop
        // on an empty track reading "0" is the worst frame it can show, and the loop guarantees
        // you'll see it. It climbs 40 → 80 with the arc already a third of the way round.
        let climb: Double = ease(min(1, phase / 0.36))
        let sweep: Double = 0.38 + climb * 0.38
        let fade: Double = phase > 0.92 ? max(0, 1 - (phase - 0.92) / 0.08) : 1
        let score: Int = Int((40 + climb * 40).rounded())
        let lime = Color(hex: "9BD44A")
        let leaf = Color(hex: "5DBB4E")
        let deep = tint
        return ZStack {
            // The puck: top-lit white, a hairline that is bright above and shaded below, and
            // two soft shadows — a tight contact and a wide tinted bloom. Exactly the raised
            // material the rest of the app wears, drawn round.
            Circle()
                .fill(LinearGradient(colors: [.white, Color(hex: "EEF0F3")], startPoint: .top, endPoint: .bottom))
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(colors: [.white, .white.opacity(0.4), .black.opacity(0.07)],
                                       startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.07), radius: 2, y: 1)
                .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
            // The groove the track sits in: a darker line under a lighter one, offset by less
            // than a point, is what reads as a recess rather than a ring drawn ON the surface.
            Circle().stroke(Color(hex: "D3D6DC"), lineWidth: 6.5).frame(width: 36, height: 36).offset(y: -0.4)
            Circle().stroke(Color(hex: "E6E8EC"), lineWidth: 6).frame(width: 36, height: 36).offset(y: 0.3)
            // The lit arc, with one tight static glow so it reads as light in the groove.
            Circle().trim(from: 0, to: max(0.003, sweep))
                .stroke(AngularGradient(stops: [.init(color: lime, location: 0),
                                                .init(color: leaf, location: 0.42),
                                                .init(color: deep, location: 0.76)],
                                        // Angle space is the SHAPE's, and the whole stroke is then
                                        // rotated −90 to start at 12 o'clock — so 0° here IS the
                                        // arc's start. A −90 start put lime at the tail instead.
                                        center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360)),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 36, height: 36)
                .shadow(color: leaf.opacity(0.3), radius: 2)
                .opacity(fade)
            // The inner face, a touch brighter than the puck, with a whisper of inner shadow
            // where it meets the groove.
            Circle()
                .fill(RadialGradient(colors: [.white, Color(hex: "F5F6F8")],
                                     center: UnitPoint(x: 0.45, y: 0.4), startRadius: 0, endRadius: 15))
                .overlay { Circle().strokeBorder(.black.opacity(0.035), lineWidth: 0.7) }
                .frame(width: 27, height: 27)
            Text("\(score)")
                .font(.display(13, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                .opacity(fade)
        }
        .frame(width: 50, height: 50)
    }

    /// The plan, REBUILDING. Each bar morphs between two week-shapes on its own staggered clock,
    /// and the bar currently mid-change carries the tint and a glow — so a wave of light walks the
    /// block and the heights are visibly different on every pass. That is the claim the row makes.
    /// (It used to slide sideways by one column, which read as scrolling, not as adapting.)
    ///
    /// Each bar's clock is periodic in `phase`, so the whole block loops seamlessly no matter
    /// where the shared marquee clock happens to be when the row scrolls in.
    private func planArt(_ phase: Double) -> some View {
        let a: [CGFloat] = [10, 18, 12, 22, 15]
        let b: [CGFloat] = [16, 11, 20, 14, 22]
        return VStack(spacing: 2.5) {
            HStack(alignment: .bottom, spacing: 3.2) {
                ForEach(0..<5, id: \.self) { i in
                    let u: Double = (phase - Double(i) * 0.1).truncatingRemainder(dividingBy: 1)
                    let uu: Double = u < 0 ? u + 1 : u
                    let tri: Double = uu < 0.5 ? uu * 2 : (1 - uu) * 2
                    let e: Double = ease(tri)
                    let h: CGFloat = a[i] + (b[i] - a[i]) * CGFloat(e)
                    let hot: Double = max(0, 1 - abs(e - 0.5) * 3.2)
                    RoundedRectangle(cornerRadius: 1.6, style: .continuous)
                        .fill(tint.opacity(0.28 + 0.72 * hot))
                        .frame(width: 4.2, height: h)
                        .shadow(color: tint.opacity(hot * 0.75), radius: 4)
                }
            }
            Capsule().fill(tint.opacity(0.25)).frame(width: 27, height: 1.2)
        }
        // A pool of light walks the block behind the bars — the engine working through the week.
        // It sits BEHIND rather than over: a white band over a light tile is invisible, and a
        // tinted one over the bars would flatten them.
        .background {
            RadialGradient(colors: [tint.opacity(0.4), tint.opacity(0.12), .clear],
                           center: .center, startRadius: 1, endRadius: 13)
                .frame(width: 26, height: 26)
                .offset(x: -17 + 34 * CGFloat(phase))
        }
        .frame(width: 30, height: 30)
        // The badge marks the moment the block adapts — the reference wall's icons all carry one
        // small marker like this, and it is what lifts a shape into an app icon.
        .overlay(alignment: .topTrailing) {
            let show: Double = max(0, sin(phase * .pi * 2))
            Image(systemName: "arrow.up")
                .font(.system(size: 6, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 11, height: 11)
                .background(Circle().fill(Theme.purple))
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.1))
                .shadow(color: Theme.purple.opacity(0.5), radius: 3)
                .opacity(show)
                .offset(x: 3, y: -3)
        }
    }

    /// Coach chat & post-run reads: the coach SPEAKING. A speech bubble with a live voice
    /// waveform, the way a voice message looks. It needs no decoding, which is what the two
    /// versions before it lacked — an "exchange" of blank pills read as nothing in particular, and
    /// resolving pace digits were an idea that needed explaining (owner: "doesn't make sense").
    /// Each bar rides its own phase offset so the wave rolls left to right, like real speech.
    private func coachArt(_ phase: Double) -> some View {
        let t: Double = phase * .pi * 2
        let heights: [CGFloat] = (0..<5).map { i in
            let a: Double = 0.5 + 0.5 * sin(t * 3 + Double(i) * 1.25)
            let b: Double = 0.5 + 0.5 * sin(t * 5 + Double(i) * 0.7 + 1.3)
            return 2.6 + 7.4 * CGFloat(0.55 * a + 0.45 * b)
        }
        // Bubble and tail are ONE path filled once. Two stacked shapes always betrayed the
        // seam: the glyph gradient is semi-transparent at the bottom, so a tail behind the
        // bubble showed through it, and a tail in front sat on it as a diamond.
        let bubble = Path { p in
            p.addRoundedRect(in: CGRect(x: 0, y: 0, width: 30, height: 20),
                             cornerSize: CGSize(width: 7, height: 7), style: .continuous)
            // Same winding as the rounded rect. Wound the other way, the overlap CANCELS under
            // the nonzero fill rule and a hairline hole opens along the seam.
            p.move(to: CGPoint(x: 4, y: 17))
            p.addLine(to: CGPoint(x: 11, y: 19))
            p.addLine(to: CGPoint(x: 2.5, y: 24))
            p.closeSubpath()
        }
        return ZStack {
            bubble.fill(glyphStyle).frame(width: 30, height: 24)
            HStack(spacing: 2.2) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule().fill(.white).frame(width: 2.4, height: heights[i])
                }
            }
            .offset(y: -2)
        }
        .frame(width: 30, height: 30)
    }

    /// Race predictions: the real checkered flag, fluttering. A y-axis 3D rotation with a little
    /// roll is what sells cloth catching wind on a flat glyph — the hand-drawn checker grid this
    /// replaces waved convincingly but never looked like an object. The predicted finish lands
    /// beside it, which is the actual feature.
    private func raceArt(_ phase: Double) -> some View {
        let land: Double = ease(min(1, max(0, (phase - 0.2) / 0.28)))
        // One quiet wave. The two-harmonic shear that was here deformed the whole flag and read
        // as tacky (owner call) — real cloth on a still day barely moves. A small y-axis turn
        // anchored at the pole, nothing else, on a slow period.
        let yaw: Double = 7 * sin(phase * .pi * 2)
        let lift: CGFloat = CGFloat(-0.4 * sin(phase * .pi * 2))
        return ZStack(alignment: .bottomTrailing) {
            Text("🏁")
                .font(.system(size: 25))
                .rotation3DEffect(.degrees(yaw), axis: (x: 0, y: 1, z: 0),
                                  anchor: .leading, perspective: 0.5)
                .offset(y: lift)
                .frame(width: 30, height: 30)
            Text("3:29").font(.rounded(7, weight: .heavy)).monospacedDigit().foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(Capsule().fill(Theme.ink))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .offset(x: 6, y: 8 - 5 * CGFloat(land))
                .opacity(land)
        }
        .frame(width: 30, height: 30)
    }

    /// Nutrition: the food gets READ. A thin scan line crosses the apple while sparks work, then
    /// a small ink pill lands with the number the model found. The pill is the whole point — a
    /// food object alone says "food"; the read that lands says "food TRACKING". (The rule that
    /// got us here: at 30pt, a real nameable object. Fork-and-knife said nothing; macro dots on a
    /// plate read as a FACE; a focus frame was motion with no subject.)
    private func fuelArt(_ phase: Double) -> some View {
        let bob: CGFloat = -0.8 * CGFloat(sin(phase * .pi * 2))
        let scan: Double = min(1, max(0, (phase - 0.08) / 0.4))
        let scanY: CGFloat = -12 + 24 * CGFloat(ease(scan))
        let beam: Double = min(1, max(0, (phase - 0.08) / 0.05)) * min(1, max(0, (0.5 - phase) / 0.05))
        let land: Double = ease(min(1, max(0, (phase - 0.52) / 0.2)))
        let sparkSize: [CGFloat] = [7.5, 5, 4.5]
        let sparkX: [CGFloat] = [-12, -13.5, -8]
        let sparkY: [CGFloat] = [-9, -2, -13]
        return ZStack {
            Text("🍎")
                .font(.system(size: 25))
                .offset(y: bob)
                .frame(width: 30, height: 30)
            ForEach(0..<3, id: \.self) { i in
                let p: Double = (phase * 1.6 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
                let tw: Double = max(0, sin(p * .pi)) * (beam > 0 ? 1 : 0.45)
                Image(systemName: "sparkle")
                    .font(.system(size: sparkSize[i], weight: .bold))
                    .foregroundStyle(Theme.purple)
                    .opacity(tw)
                    .offset(x: sparkX[i], y: sparkY[i])
            }
            // The scan: a hairline of light with a soft trail, clipped to the fruit's width.
            Capsule()
                .fill(LinearGradient(colors: [.clear, .white, Theme.purple.opacity(0.9), .white, .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 22, height: 1.4)
                .shadow(color: Theme.purple.opacity(0.7), radius: 2.5)
                .offset(y: scanY + bob)
                .opacity(beam)
            Text("95 kcal")
                .font(.rounded(6, weight: .heavy)).monospacedDigit().foregroundStyle(.white)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 3.5).padding(.vertical, 1.6)
                .background(Capsule().fill(Theme.ink))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .offset(x: 8, y: 14 - 4 * CGFloat(land))
                .opacity(land)
        }
        .frame(width: 30, height: 30)
    }

    private func analyticsArt(_ phase: Double) -> some View {
        // The trace is always fully drawn (rows join the marquee at any phase, so a self-drawing
        // line would show up empty). The life is our own tap-to-inspect: a scrub cursor walks
        // the series and the value dot rides the line under it. That is a feature, not a flourish.
        let pts: [CGPoint] = [.init(x: 0, y: 18), .init(x: 7, y: 12), .init(x: 14, y: 15),
                              .init(x: 21, y: 6), .init(x: 28, y: 9)]
        let t: Double = ease(min(1, max(0, (phase - 0.08) / 0.7)))
        let x: CGFloat = 28 * CGFloat(t)
        let seg: Int = min(3, Int(x / 7))
        let f: CGFloat = (x - CGFloat(seg) * 7) / 7
        let y: CGFloat = pts[seg].y + (pts[seg + 1].y - pts[seg].y) * f
        let show: Double = min(1, max(0, (phase - 0.05) / 0.06)) * min(1, max(0, (0.92 - phase) / 0.06))
        let trace = Path { p in p.move(to: pts[0]); for q in pts.dropFirst() { p.addLine(to: q) } }
        return ZStack {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 24))
                for q in pts { p.addLine(to: q) }
                p.addLine(to: CGPoint(x: 28, y: 24))
                p.closeSubpath()
            }
            .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0)],
                                 startPoint: .top, endPoint: .bottom))
            trace.stroke(glyphStyle, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            ForEach(0..<pts.count, id: \.self) { i in
                Circle().fill(tint).frame(width: 3.6, height: 3.6).position(pts[i])
            }
            // The cursor: a hairline down the plot and a lit dot on the line.
            // A drop line from the dot to the baseline, not a rule through the whole plot.
            Rectangle().fill(tint.opacity(0.35)).frame(width: 0.8, height: max(1, 24 - y))
                .position(x: x, y: y + (24 - y) / 2)
                .opacity(show)
            ZStack {
                Circle().fill(.white).frame(width: 6.5, height: 6.5)
                Circle().fill(tint).frame(width: 3.6, height: 3.6)
            }
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
            .position(x: x, y: y)
            .opacity(show)
        }
        .frame(width: 28, height: 24)
    }

    /// Watch & voice coach: an actual Apple Watch, drawn. The details that make it read as the
    /// real object at 30pt are the ones a symbol can't give you — a squircle case in graphite with
    /// a lit top rim, a BLACK screen inset (this is the tell; without it a case is just a blob),
    /// the digital crown and side button stacked on the right edge, and tapered bands. The workout
    /// ring closes on the display with a bead on its leading edge, and cue arcs bloom off the
    /// crown side and fade — the cue leaving the wrist for the ear.
    private func watchArt(_ phase: Double) -> some View {
        let ring: Double = ease(min(1, phase / 0.42)) * 0.78
        let bead: Double = -90 + ring * 360
        let caseFill = LinearGradient(colors: [Color(hex: "56565E"), Color(hex: "2A2A30")],
                                      startPoint: .top, endPoint: .bottom)
        let metal = LinearGradient(colors: [Color(hex: "6A6A73"), Color(hex: "3A3A41")],
                                   startPoint: .top, endPoint: .bottom)
        return ZStack {
            ForEach(0..<2, id: \.self) { i in
                let p: Double = (phase + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                let d: CGFloat = 24 + 10 * CGFloat(p)
                Circle().trim(from: 0, to: 0.11)
                    .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-19.8))
                    .frame(width: d, height: d)
                    .opacity((1 - p) * 0.75)
            }
            VStack(spacing: 0) {
                band(width: 9.5)
                Color.clear.frame(width: 17, height: 20.5)
                band(width: 9.5)
            }
            // Crown and side button ride the case's right edge, stacked the way they are on the
            // real thing — two marks, not one, or it reads as a stray nub.
            VStack(spacing: 2.5) {
                RoundedRectangle(cornerRadius: 1.1, style: .continuous)
                    .fill(metal).frame(width: 2.4, height: 5)
                RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                    .fill(metal).frame(width: 1.8, height: 4)
            }
            .offset(x: 9.4, y: -1)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(caseFill)
                    .frame(width: 17, height: 20.5)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .clear, .black.opacity(0.25)],
                                                         startPoint: .top, endPoint: .bottom),
                                          lineWidth: 0.7)
                    }
                RoundedRectangle(cornerRadius: 4.6, style: .continuous)
                    .fill(Color(hex: "07070A"))
                    .frame(width: 13.6, height: 17)
                    .overlay {
                        // The glass: a diagonal glint that sweeps the display once per loop.
                        // This is the detail that separates a black rectangle from a screen.
                        let g: CGFloat = -14 + 28 * CGFloat(ease(min(1, max(0, (phase - 0.55) / 0.3))))
                        RoundedRectangle(cornerRadius: 4.6, style: .continuous)
                            .fill(LinearGradient(colors: [.clear, .white.opacity(0.22), .clear],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 8, height: 17)
                            .offset(x: g)
                            .mask(RoundedRectangle(cornerRadius: 4.6, style: .continuous).frame(width: 13.6, height: 17))
                    }
                Circle().stroke(tint.opacity(0.22), lineWidth: 2)
                    .frame(width: 10, height: 10)
                Circle().trim(from: 0, to: max(0.003, ring))
                    .stroke(AngularGradient(colors: [tint.opacity(0.5), tint, tint], center: .center,
                                            startAngle: .degrees(-90), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 10, height: 10)
                ZStack { Circle().fill(.white).frame(width: 2.2, height: 2.2).offset(x: 5) }
                    .frame(width: 10, height: 10)
                    .rotationEffect(.degrees(bead))
                    .shadow(color: tint, radius: 2)
            }
            .shadow(color: .black.opacity(0.28), radius: 3, y: 2)
        }
        .frame(width: 30, height: 30)
    }

    /// One band. Slightly narrower than the case and a touch lighter, so the silhouette reads as
    /// watch-on-a-strap rather than one fused shape.
    private func band(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2.4, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.38)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: width, height: 6)
    }
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
