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
struct AthletePanel: View {
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

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("ATHLETE PANEL").font(.rounded(Theme.FontSize.label, weight: .bold))
                    .tracking(1.4).foregroundStyle(Theme.inkTertiary)
                Spacer()
                Text(windowLabel).font(.rounded(10, weight: .bold))
                    .tracking(1.2).foregroundStyle(Theme.inkTertiary.opacity(0.7))
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: windowLabel)
            }
            stage.frame(height: 400)
        }
        // Deliberately no card: the panel is built into the canvas — the figure stands in the
        // app itself, not in a box. The platform below grounds it instead.
        .padding(.vertical, Theme.Space.sm)
    }

    private var stage: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // The figure owns the center column; the data columns own the gutters.
            let fig = CGRect(x: w * 0.5 - w * 0.20, y: 6, width: w * 0.40, height: h - 26)
            let body = fittedBodyRect(in: fig)
            ZStack {
                backdrop(body: body, h: h)
                figure(fig: fig)
                HStack(alignment: .top, spacing: 0) {
                    // Left: the anchor stat — one big number, staggered down for composition.
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        heroView(hero)
                        if let sub { railRow(sub) }
                    }
                    .padding(.top, h * 0.16)
                    .frame(width: w * 0.30, alignment: .topLeading)
                    Spacer(minLength: 0)
                    // Right: the rail — compact readings separated by hairlines. Free tier sees the
                    // labels but the values are locked: the physiology your body carries is Pro.
                    ZStack {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            ForEach(Array(rail.enumerated()), id: \.element.id) { i, c in
                                if i > 0 {
                                    Rectangle().fill(Theme.ink.opacity(0.10)).frame(height: 0.5)
                                }
                                railRow(c)
                            }
                        }
                        .blur(radius: pro ? 0 : 6)
                        .allowsHitTesting(pro)
                        if !pro { railLock }
                    }
                    .padding(.top, h * 0.05)
                    .frame(width: w * 0.30, alignment: .topLeading)
                }
            }
        }
    }

    /// Where the anatomy actually renders inside `fig` (aspect-fit, centered) — used to place
    /// the light the figure stands in.
    private func fittedBodyRect(in fig: CGRect) -> CGRect {
        let aspect = BodyAnatomy.viewBoxWidth / BodyAnatomy.viewBoxHeight
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
        // The figure stands in the brand's light: a soft iridescent aura, the same family as the
        // fuel/readiness rings' glow (user call 2026-07-16). STATIC by design — a live `.shadow`
        // on the 30fps-animating mesh cost a full offscreen pass per tick and stuttered the tab
        // (see `figure()`), so the glow lives here, rendered once and cached.
        AngularGradient(colors: Theme.iridescent + [Theme.iridescent.first ?? .clear], center: .center)
            .frame(width: body.width * 1.15, height: body.width * 1.15)
            .clipShape(Circle())
            .blur(radius: 42)
            .opacity(isDark ? 0.34 : 0.22)
            .position(x: body.midX, y: body.minY + body.height * 0.32)
            .allowsHitTesting(false)
        platform(body: body)
    }

    /// No platform — just a subtle grounding shadow at the feet so the figure doesn't float.
    /// (A light pool and rims were tried and cut: too much furniture under the body.)
    private func platform(body: CGRect) -> some View {
        Ellipse()
            .fill(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10))
            .frame(width: body.width * 0.8, height: 10)
            .blur(radius: 7)
            .position(x: body.midX, y: body.maxY + 4)
    }

    private func figure(fig: CGRect) -> some View {
        // No `.shadow` here: blurring a 30fps-animating mesh re-renders the whole figure
        // offscreen every tick. The static aura in `backdrop` supplies the dark-mode glow.
        MuscleMapView(activation: activation, sides: [.front], sex: sex, forceStatic: reduceMotion)
            .frame(width: fig.width, height: fig.height)
            .position(x: fig.midX, y: fig.midY)
            .accessibilityHidden(true)   // the columns carry the data; the figure is scenery
    }

    /// The lock resting over the blurred rail — a small tappable badge that opens the paywall.
    private var railLock: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold))
            Text("PRO").font(.rounded(10, weight: .heavy)).tracking(1.2)
        }
        .foregroundStyle(Color(hex: "0E0E12"))     // fixed dark: the route badge is always light
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Capsule().fill(Theme.route))
        .contentShape(Rectangle())
        .onTapGesture { Haptics.light(); onLockedTap() }
        .accessibilityElement()
        .accessibilityLabel("Physiology readings")
        .accessibilityHint("Unlock with Pro")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: data columns

    private func heroView(_ c: AthleteCallout) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(c.label).font(.rounded(9, weight: .bold)).tracking(1.1)
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(c.value).font(.display(34, weight: .black)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.55)
                    .foregroundStyle(Theme.ink)
                if let unit = c.unit {
                    Text(unit).font(.rounded(11, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                }
            }
            Text(c.context).font(.rounded(10, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .onTapGesture { Haptics.light(); onSelect(c.target) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(c.label): \(c.value)\(c.unit.map { " \($0)" } ?? ""), \(c.context)")
        .accessibilityHint("Shows the detail card")
        .accessibilityAddTraits(.isButton)
    }

    private func railRow(_ c: AthleteCallout) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(c.label).font(.rounded(8.5, weight: .bold)).tracking(1.0)
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(c.value).font(.display(17, weight: .black)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.55)
                    .foregroundStyle(Theme.ink)
                if let unit = c.unit {
                    Text(unit).font(.rounded(10, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                }
            }
            Text(c.context).font(.rounded(9.5, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(1).minimumScaleFactor(0.75)
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
