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
    let hero: AthleteCallout
    var sub: AthleteCallout?
    let rail: [AthleteCallout]
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
                    // Right: the rail — compact readings separated by hairlines.
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        ForEach(Array(rail.enumerated()), id: \.element.id) { i, c in
                            if i > 0 {
                                Rectangle().fill(Theme.ink.opacity(0.10)).frame(height: 0.5)
                            }
                            railRow(c)
                        }
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
        if isDark {
            // Luminous variant: a faint aura behind the chest so the figure reads lit, not pasted.
            RadialGradient(colors: [.white.opacity(0.07), .clear], center: .center,
                           startRadius: 0, endRadius: h * 0.5)
                .position(x: body.midX, y: body.minY + body.height * 0.30)
        }
        platform(body: body)
    }

    /// The pedestal — pure light, no hardware: a soft pool of glow under the figure and a tight
    /// contact shadow at the feet. Monochrome in both modes (the stage isn't earned progress).
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
            .accessibilityHidden(true)   // the columns carry the data; the figure is scenery
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
