import SwiftUI

/// One data callout on the Athlete Panel — a labeled reading wired by a leader line to a point on
/// the body (head → readiness, lungs → VO₂, heart → resting HR, core → load, legs → volume…).
/// `anchor` is in unit coordinates of the figure's frame; `target` is the scroll id of the detail
/// card the callout opens.
struct AthleteCallout: Identifiable {
    enum Edge { case leading, trailing }
    let label: String
    let value: String
    let unit: String?
    let context: String
    let anchor: CGPoint
    let edge: Edge
    let slot: CGFloat          // vertical position of the callout block, 0…1 of stage height
    let target: String
    var id: String { label }
}

/// The Athlete Panel — the Progress hero. The user's own anatomy (the same figure that lights up
/// after strength work) standing on a stage, with this week's physiology read off the body via
/// leader-line callouts. Adapts to both modes: in light it reads as a clean product-render (ink
/// figure, soft floor shadow); in dark the figure becomes luminous on the true-black stage. Same
/// geometry — only the lighting changes, like the medallions.
struct AthletePanel: View {
    let activation: [MuscleGroup: Double]
    var sex: BodySex = .neutral
    let callouts: [AthleteCallout]
    var onSelect: (String) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("ATHLETE PANEL").font(.rounded(Theme.FontSize.label, weight: .bold))
                    .tracking(1.4).foregroundStyle(Theme.inkTertiary)
                Spacer()
                Text("LAST 7 DAYS").font(.rounded(10, weight: .bold))
                    .tracking(1.2).foregroundStyle(Theme.inkTertiary.opacity(0.7))
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
            // The figure owns the center column; callouts live in the side gutters. The anatomy
            // aspect-fits (724×1448 viewBox) inside its frame, so anchors map onto the *fitted*
            // body rect — not the frame — or the leader lines miss the body.
            let fig = CGRect(x: w * 0.5 - w * 0.20, y: 6, width: w * 0.40, height: h - 26)
            let body = fittedBodyRect(in: fig)
            ZStack {
                backdrop(body: body, h: h)
                figure(fig: fig)
                leaderLines(body: body, w: w, h: h)
                // Fixed-height rows on an even grid — the two columns read as one spec sheet,
                // left and right of the figure, instead of scattered blocks.
                ForEach(callouts) { c in
                    calloutView(c)
                        .frame(width: w * 0.28, height: 72,
                               alignment: c.edge == .leading ? .trailing : .leading)
                        .position(x: c.edge == .leading ? w * 0.14 : w * 0.86, y: c.slot * h)
                }
            }
        }
    }

    /// Where the anatomy actually renders inside `fig` (aspect-fit, centered) — the space the
    /// callout anchors are defined in.
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
        if isDark {
            // Luminous variant: a faint aura behind the chest so the figure reads lit, not pasted.
            RadialGradient(colors: [.white.opacity(0.07), .clear], center: .center,
                           startRadius: 0, endRadius: h * 0.5)
                .position(x: body.midX, y: body.minY + body.height * 0.30)
        }
        platform(body: body)
    }

    /// The pedestal — pure light, no hardware: a soft pool of glow under the figure and a tight
    /// contact shadow at the feet. No stroked rims (they read as furniture, not light).
    /// Monochrome in both modes (the stage isn't earned progress).
    private func platform(body: CGRect) -> some View {
        let w = body.width * 1.3
        let h = w * 0.28
        return ZStack {
            Ellipse()
                .fill(RadialGradient(colors: isDark ? [.white.opacity(0.13), .clear]
                                                    : [.black.opacity(0.06), .clear],
                                     center: .center, startRadius: 0, endRadius: w * 0.5))
                .frame(width: w, height: h)
                .blur(radius: 2)
            // Contact shadow right under the feet so the figure doesn't float.
            Ellipse()
                .fill(isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.12))
                .frame(width: body.width * 0.5, height: 7)
                .blur(radius: 5)
        }
        .position(x: body.midX, y: body.maxY - 3)
    }

    private func figure(fig: CGRect) -> some View {
        MuscleMapView(activation: activation, sides: [.front], sex: sex, forceStatic: reduceMotion)
            .compositingGroup()
            .shadow(color: isDark ? .white.opacity(0.28) : .clear, radius: 16)
            .frame(width: fig.width, height: fig.height)
            .position(x: fig.midX, y: fig.midY)
            .accessibilityHidden(true)   // the callouts carry the data; the figure is scenery
    }

    // MARK: leader lines

    private func leaderLines(body: CGRect, w: CGFloat, h: CGFloat) -> some View {
        Canvas { ctx, _ in
            let line = Theme.ink.opacity(isDark ? 0.32 : 0.22)
            for c in callouts {
                let anchor = CGPoint(x: body.minX + c.anchor.x * body.width,
                                     y: body.minY + c.anchor.y * body.height)
                let startX = c.edge == .leading ? w * 0.28 : w * 0.72
                let start = CGPoint(x: startX, y: c.slot * h)
                var path = Path()
                path.move(to: start)
                path.addLine(to: anchor)
                ctx.stroke(path, with: .color(line), lineWidth: 1)
                // Tick at the callout end + a ringed dot on the body.
                ctx.fill(Path(ellipseIn: CGRect(x: start.x - 1.5, y: start.y - 1.5, width: 3, height: 3)),
                         with: .color(line))
                ctx.fill(Path(ellipseIn: CGRect(x: anchor.x - 2, y: anchor.y - 2, width: 4, height: 4)),
                         with: .color(Theme.ink.opacity(0.85)))
                ctx.stroke(Path(ellipseIn: CGRect(x: anchor.x - 5, y: anchor.y - 5, width: 10, height: 10)),
                           with: .color(line), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: callouts

    private func calloutView(_ c: AthleteCallout) -> some View {
        let leading = c.edge == .leading
        return VStack(alignment: leading ? .trailing : .leading, spacing: 3) {
            Text(c.label).font(.rounded(9, weight: .bold)).tracking(1.1)
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(c.value).font(.display(20, weight: .black)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.55)
                    .foregroundStyle(Theme.ink)
                if let unit = c.unit {
                    Text(unit).font(.rounded(10.5, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                }
            }
            Text(c.context).font(.rounded(10, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: leading ? .trailing : .leading)
        .contentShape(Rectangle())
        .onTapGesture { Haptics.light(); onSelect(c.target) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(c.label): \(c.value)\(c.unit.map { " \($0)" } ?? ""), \(c.context)")
        .accessibilityHint("Shows the detail card")
        .accessibilityAddTraits(.isButton)
    }
}
