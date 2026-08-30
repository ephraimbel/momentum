import SwiftUI

/// One reading on the Athlete Panel — a labeled value; `target` is the scroll id of the detail
/// card the reading opens when tapped.
struct AthleteCallout: Identifiable {
    let label: String
    let value: String
    let unit: String?
    let context: String
    let target: String
    var id: String { label }
}

/// The Athlete Panel — the Progress hero. The user's own anatomy (the same figure that lights up
/// after strength work) standing on a pool of light, flanked by two data columns composed like a
/// spec sheet: one hero stat block on the left (VO₂max — the fitness index), a rail of compact
/// readings on the right. Deliberately asymmetric — one anchor number balanced against a list.
/// No leader lines: the columns carry the data; the body carries the training (worked muscles
/// glow). Adapts to both modes: light reads as a product render, dark as a luminous stage.
///
/// **Dynamic Type.** The brand faces come from `Font.custom(_:size:)`, which already scales
/// relative to body — but this panel used to cancel that out. Every reading lived in a fixed 30%
/// column inside a hard 400pt stage, so as the type grew, `minimumScaleFactor(0.55)` shrank it
/// straight back to fit and the rail's context line (`lineLimit(1)`, 0.75) simply truncated: the
/// athlete raised their text size and got the same numbers plus an ellipsis. Two changes fix it,
/// and NEITHER touches the default appearance — the stage is a `@ScaledMetric` (still exactly
/// 400pt at the default size) so growth has somewhere to go, and the shrink floors are raised to
/// a safety net instead of a defeat device. The composition, the type sizes, and the 30/40/30
/// split are the shipped design and stay as drawn.
struct AthletePanel: View {
    /// Weekly working-set-equivalents per muscle (the caller divides its window total by the
    /// window's weeks) — the figure grades ABSOLUTELY via `.weeklyVolume`, so an empty window is a
    /// blank chart, a light week a faint tint, and only consistent volume a full iridescent burn.
    let activation: [MuscleGroup: Double]
    var sex: BodySex = .neutral
    /// Eyebrow that names the window the figure + callouts summarize (re-windows with the range picker).
    var windowLabel: String = "LAST 7 DAYS"
    let hero: AthleteCallout
    var sub: AthleteCallout?
    let rail: [AthleteCallout]
    /// When false the physiological rail (readiness/load/resting-heart/focus) is a locked teaser:
    /// the body and the distance hero stay free, everything the rail reads off the body is Pro.
    var pro: Bool = true
    var onSelect: (String) -> Void = { _ in }
    /// Tapped when a locked reading is touched — routes to the paywall like the analytics block.
    var onLockedTap: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The figure's iridescent mesh animates at 30 fps for as long as it exists — including
    /// scrolled far off-screen under the Trends report (3 offscreen passes/tick for nothing,
    /// 2026-07-30 perf audit). Freeze it whenever the panel isn't visible.
    @State private var onScreen = true

    /// Which face of the athlete is showing. The figure is a real body and it TURNS (2026-08-29):
    /// front-only meant glutes, hamstrings and the whole back could never light up no matter how
    /// much the athlete trained them — the panel promised a training portrait and drew half of one.
    @State private var side: BodySide = .front
    /// Live rotation of the figure about its own vertical axis, in degrees. The swap happens at
    /// 90°, edge-on, where there is nothing to see — so only ONE figure is ever mounted. (Crossfading
    /// two would double the anatomy fills and run a second 30 fps mesh behind the first, on the
    /// panel this file has twice been optimized to keep light.)
    @State private var flipAngle: Double = 0
    #if DEBUG
    /// One-shot latch for `--athlete-panel-back` (see `body`).
    @State private var appliedDebugSide = false
    #endif

    /// The turn caption's reserved strip under the feet, and its gap from them. The figure's own
    /// rect is the column minus this, so the body, its contact shadow and the caption never collide.
    /// Scaled like `stageHeight` above it: the caption is brand type, so it grows with the athlete's
    /// text setting, and the strip it stands in has to grow with it or the feet land on the words.
    @ScaledMetric(relativeTo: .body) private var captionHeight: CGFloat = 16
    private let captionGap: CGFloat = 10

    /// The stage grows with the athlete's text setting — 400pt at the default size (exactly what
    /// it was hard-coded to), taller as the type grows. That headroom is the whole fix: the box
    /// being fixed was the reason every reading had to shrink back down to fit inside it.
    @ScaledMetric(relativeTo: .body) private var stageHeight: CGFloat = 360

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                EyebrowLabel(text: "Athlete panel")
                Spacer(minLength: Theme.Space.sm)
                Text(windowLabel).font(.rounded(10, weight: .bold))
                    .tracking(1.2).foregroundStyle(Theme.inkTertiary.opacity(0.7))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: windowLabel)
            }
            stage.frame(height: stageHeight)
        }
        // No card (owner call 2026-08-28): the panel is baked into the page. The figure and its
        // readings sit straight on the background, which is what makes the top of Trends read
        // as one surface instead of a box on a surface.
        .padding(.vertical, Theme.Space.sm)
        .onScrollVisibilityChange(threshold: 0.05) { onScreen = $0 }
        #if DEBUG
        // --athlete-panel-back: land with the figure already turned, so the back can be screenshot
        // without driving the tap. One-shot: `onAppear` fires again on every return to the tab, and
        // re-applying it would keep yanking the figure back around under the athlete's own taps.
        .onAppear {
            guard !appliedDebugSide else { return }
            appliedDebugSide = true
            if ProcessInfo.processInfo.arguments.contains("--athlete-panel-back") { side = .back }
        }
        #endif
    }

    private var stage: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // The figure owns the center column; the data columns own the gutters.
            let column = CGRect(x: w * 0.5 - w * 0.21, y: 4, width: w * 0.42, height: h - 22)
            let fig = figureRect(column)
            let body = fittedBodyRect(in: fig)
            ZStack {
                backdrop(body: body, h: h)
                figure(fig: fig)
                sideCaption
                    .position(x: column.midX, y: column.maxY - captionHeight / 2)
                HStack(alignment: .top, spacing: 0) {
                    // Left: the anchor stat — one big number, staggered down for composition.
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        reading(hero, hero: true)
                        if let sub { reading(sub, hero: false) }
                    }
                    .padding(.top, h * 0.16)
                    .frame(width: w * 0.30, alignment: .topLeading)
                    Spacer(minLength: 0)
                    // Right: the rail — compact readings separated by hairlines. Free tier sees
                    // the labels but the values are locked: the physiology is Pro.
                    lockedRail
                        .padding(.top, h * 0.05)
                        .frame(width: w * 0.30, alignment: .topLeading)
                }
            }
        }
    }

    /// The rail plus its Pro treatment.
    private var lockedRail: some View {
        ZStack {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                ForEach(Array(rail.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { Rectangle().fill(Theme.ink.opacity(0.08)).frame(height: 0.5) }
                    reading(c, hero: false)
                }
            }
            .blur(radius: pro ? 0 : 6)
            .allowsHitTesting(pro)
            if !pro { railLock }
        }
    }

    /// The figure's own rect: the centre column less the caption strip beneath the feet.
    private func figureRect(_ column: CGRect) -> CGRect {
        CGRect(x: column.minX, y: column.minY,
               width: column.width, height: max(0, column.height - captionHeight - captionGap))
    }

    /// Where the anatomy actually renders inside `fig` (aspect-fit, centered) — used to place
    /// the light the figure stands in. Reads the viewBox of the side ON SCREEN: the female back
    /// art is wider than her front, so a front-only box would drift the shadow off her feet.
    private func fittedBodyRect(in fig: CGRect) -> CGRect {
        let vb = BodyAnatomy.viewBox(side, sex)
        let aspect = vb.width / vb.height
        var size = CGSize(width: fig.width, height: fig.width / aspect)
        if size.height > fig.height {
            size = CGSize(width: fig.height * aspect, height: fig.height)
        }
        return CGRect(x: fig.midX - size.width / 2, y: fig.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    // MARK: stage dressing

    @ViewBuilder
    private func backdrop(body: CGRect, h: CGFloat) -> some View {
        // One soft pool of lavender light behind the torso (the Bevel wash, in our hue) — a
        // static radial, never a live blur on the animating mesh.
        // A faint COOL pool, not a lavender one — the figure's muscle lighting is the only
        // colour this panel gets to spend.
        RadialGradient(colors: [Theme.iridescent[1].opacity(isDark ? 0.16 : 0.20),
                                Theme.iridescent[1].opacity(isDark ? 0.05 : 0.06), .clear],
                       center: .center, startRadius: 10, endRadius: body.width * 0.95)
            .frame(width: body.width * 1.9, height: body.width * 1.9)
            .position(x: body.midX, y: body.minY + body.height * 0.36)
            .allowsHitTesting(false)
        platform(body: body)
    }

    /// A subtle grounding shadow at the feet so the figure doesn't float.
    private func platform(body: CGRect) -> some View {
        Ellipse()
            .fill(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10))
            .frame(width: body.width * 0.8, height: 10)
            .blur(radius: 7)
            .position(x: body.midX, y: body.maxY + 4)
    }

    private func figure(fig: CGRect) -> some View {
        // `.id(side)` swaps the anatomy outright: at the halfway point the figure is edge-on, so
        // there is nothing to crossfade and nothing to see. Under Reduce Motion there is no turn
        // at all, so the same swap becomes a plain opacity dissolve.
        MuscleMapView(activation: activation, sides: [side], grading: .weeklyVolume, sex: sex,
                      forceStatic: reduceMotion || !onScreen || flipAngle != 0)
            .id(side)
            .transition(reduceMotion ? .opacity : .identity)
            .animation(.easeOut(duration: 0.45), value: activation)
            .frame(width: fig.width, height: fig.height)
            .rotation3DEffect(.degrees(flipAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.24)
            // Gestures BEFORE `.position` on purpose: `.position` returns a view the size of its
            // parent, so a tap attached after it would arm the whole stage — including the empty
            // gutters over the readings.
            .contentShape(Rectangle())
            .onTapGesture { flipBody() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Athlete figure, \(side.displayName.lowercased())")
            .accessibilityHint("Turns the figure to show the \(side.flipped.displayName.lowercased())")
            .accessibilityAddTraits(.isButton)
            .position(x: fig.midX, y: fig.midY)
    }

    /// The turn affordance: the panel's own micro-label type, plus the glyph that says the body
    /// rotates. Deliberately a caption and not a control — the panel carries no furniture (owner
    /// call: no pedestals, no rims), and the whole figure above it is the real tap target.
    private var sideCaption: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 9, weight: .bold))
            Text(side.displayName.uppercased())
                .font(.rounded(10, weight: .bold)).tracking(1.2)
                .contentTransition(.opacity)
        }
        .foregroundStyle(Theme.inkTertiary.opacity(0.7))
        .lineLimit(1)
        // No height clamp: `captionHeight` reserves the strip, the caption sizes to its own type.
        // Pinning it would crop the glyph the moment the athlete raises their text size — the very
        // trap this panel's Dynamic Type pass was written to get out of.
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { flipBody() }
        .accessibilityHidden(true)   // the figure above is the labelled button
    }

    /// Turn the body around. One tap, one half-turn each way; taps during a turn are ignored so the
    /// figure can never be left facing sideways.
    private func flipBody() {
        guard flipAngle == 0 else { return }
        Haptics.light()
        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.28)) { side = side.flipped }
            return
        }
        withAnimation(.easeIn(duration: 0.17)) {
            flipAngle = 90
        } completion: {
            // Edge-on: swap the anatomy and jump to the far side of the turn, both unanimated
            // (no `.animation(value:)` watches `flipAngle`, so these land instantly), then carry
            // the second half through. The body never reads mirrored, because it is never drawn
            // past 90°.
            side = side.flipped
            flipAngle = -90
            withAnimation(.easeOut(duration: 0.21)) { flipAngle = 0 }
        }
    }

    /// The lock resting over the blurred rail — a small tappable badge that opens the paywall.
    private var railLock: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold))
            Text("PRO").font(.rounded(10, weight: .heavy)).tracking(1.2)
        }
        .foregroundStyle(Theme.background)
        .padding(.horizontal, 11).padding(.vertical, 7)
        .raised(Capsule(), tone: .ink)
        .contentShape(Rectangle())
        .onTapGesture { Haptics.light(); onLockedTap() }
        .accessibilityElement()
        .accessibilityLabel("Physiology readings")
        .accessibilityHint("Unlock with Pro")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: readings

    /// Each reading's domain colour, by what it measures.
    private func tint(for c: AthleteCallout) -> Color {
        let l = c.label.uppercased()
        if l.contains("VO") || l.contains("FITNESS") { return MetricColor.fitness }
        if l.contains("READINESS") { return MetricColor.fresh }
        if l.contains("LOAD") { return MetricColor.load }
        if l.contains("HEART") { return MetricColor.pace }
        return Theme.inkSecondary
    }

    /// One reading in a side column: tinted dot + label, ink value, one line of context. The
    /// hero wears the display size; rail rows stay compact. Wraps instead of truncating.
    private func reading(_ c: AthleteCallout, hero: Bool) -> some View {
        let tint = tint(for: c)
        return VStack(alignment: .leading, spacing: hero ? 3 : 2) {
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 5, height: 5)
                    .shadow(color: tint.opacity(0.6), radius: 2)
                Text(c.label).font(.rounded(hero ? 9 : 8.5, weight: .bold)).tracking(1.0)
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(c.value).font(.display(hero ? 34 : 17, weight: .bold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(hero ? 0.65 : 0.7)
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                if let unit = c.unit {
                    Text(unit).font(.rounded(hero ? 11 : 10, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                }
            }
            Text(c.context).font(.rounded(hero ? 10 : 9.5, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { Haptics.light(); onSelect(c.target) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(c.label): \(c.value)\(c.unit.map { " \($0)" } ?? ""), \(c.context)")
        .accessibilityHint("Shows the detail card")
        .accessibilityAddTraits(.isButton)
    }
}
