import SwiftUI

/// One award medallion — the 3D coin treatment (machined silver face, iridescent rim, recessed
/// dish, embossed glyph + struck value, glass specular), pure gradients, fully static so grids
/// stay 60fps. Three states:
/// - **earned**: the full medallion; the rim carries the earned iridescent accent.
/// - **crown earned**: the collection summit — the dish itself anodizes iridescent.
/// - **locked**: a quiet ghost on the canvas (no metal, no iridescence — not earned yet), with an
///   optional thin ink progress arc showing how close it is.
struct AwardMedallion: View {
    let award: Award
    var earned: Bool = true
    var size: CGFloat = 92
    /// Locked only: 0…1 progress toward the threshold, drawn as a thin arc. nil hides the arc.
    var progress: Double? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if earned { coin } else { ghost }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)   // decorative — the label lives on the cell
    }

    // MARK: Earned coin

    private var coin: some View {
        ZStack {
            // Base coin. The medal is FIXED pixels in both appearances — only the light around it
            // adapts: a daylight drop shadow on the white page, a soft ambient glow on the dark one.
            Circle()
                .fill(Self.face)
                .shadow(color: colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.16),
                        radius: size * 0.09, y: colorScheme == .dark ? 0 : size * 0.055)

            // Earned iridescent rim, machined: bright edge line outside, dark seat inside.
            Circle()
                .strokeBorder(Self.rim, lineWidth: size * 0.062)
                .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 0.75))
                .overlay(
                    Circle().inset(by: size * 0.062)
                        .strokeBorder(.black.opacity(0.25), lineWidth: 1)
                )

            // Inner dish: recessed via inset shadows so the face reads concave against the rim.
            // Crowns anodize: the whole dish takes the iridescent wash — the collection summit is
            // the one coin whose face itself carries the earned accent.
            Circle()
                .inset(by: size * 0.062)
                .fill(Self.dish
                    .shadow(.inner(color: .black.opacity(0.28), radius: size * 0.07, y: size * 0.045))
                    .shadow(.inner(color: .white.opacity(1.0), radius: size * 0.025, y: -size * 0.025)))
                .overlay {
                    if award.isCrown {
                        Circle()
                            .inset(by: size * 0.062)
                            .fill(LinearGradient(colors: Theme.iridescent,
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .opacity(0.38)
                    }
                }

            // Strike: glyph above, the award's value below — light catches the top edge of both.
            // FIXED ink, not Theme.ink: a physical medal's engraving doesn't re-anodize in dark mode.
            VStack(spacing: size * 0.045) {
                Image(systemName: award.glyph)
                    .font(.system(size: size * 0.28, weight: .bold))
                Text(award.engraving)
                    .font(.display(size * 0.125, weight: .heavy))
                    .tracking(size * 0.012)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: size * 0.62)
            }
            .foregroundStyle(
                LinearGradient(colors: [Color(hex: "1C1C22").opacity(0.92),
                                        Color(hex: "1C1C22").opacity(0.62)],
                               startPoint: .top, endPoint: .bottom))
            .shadow(color: .white.opacity(0.9), radius: 0.5, y: 0.8)
            .shadow(color: .black.opacity(0.22), radius: 1, y: -0.6)
            .offset(y: -size * 0.005)

            // Specular sweep: one soft glass highlight across the upper face — the "3D" tell.
            Circle()
                .inset(by: size * 0.09)
                .fill(LinearGradient(stops: [
                    .init(color: .white.opacity(0.55), location: 0),
                    .init(color: .white.opacity(0.06), location: 0.42),
                    .init(color: .clear, location: 0.55),
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                .allowsHitTesting(false)
        }
    }

    // MARK: Locked ghost

    private var ghost: some View {
        ZStack {
            Circle().fill(Theme.surface)
            Circle().strokeBorder(Theme.hairline, lineWidth: 1)

            VStack(spacing: size * 0.045) {
                Image(systemName: award.glyph)
                    .font(.system(size: size * 0.28, weight: .bold))
                Text(award.engraving)
                    .font(.display(size * 0.125, weight: .heavy))
                    .tracking(size * 0.012)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: size * 0.62)
            }
            .foregroundStyle(Theme.inkTertiary.opacity(0.55))

            // The chase: a thin ink arc around the rim showing how close this one is. Ink, never
            // iridescent — the accent is earned, and this coin isn't yet.
            if let progress, progress > 0 {
                Circle()
                    .inset(by: 1.5)
                    .trim(from: 0, to: min(1, progress))
                    .stroke(Theme.ink.opacity(0.75),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }

    // MARK: Materials (shared with the profile's medallion language)

    /// Brushed-silver coin face.
    private static let face = LinearGradient(stops: [
        .init(color: Color(red: 0.99, green: 0.99, blue: 1.00), location: 0),
        .init(color: Color(red: 0.84, green: 0.84, blue: 0.88), location: 0.5),
        .init(color: Color(red: 0.92, green: 0.92, blue: 0.95), location: 0.72),
        .init(color: Color(red: 0.72, green: 0.72, blue: 0.78), location: 1),
    ], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// The dish carries the metal: light crown, shaded base — the inset shadows land on this.
    private static let dish = LinearGradient(stops: [
        .init(color: Color(red: 0.98, green: 0.98, blue: 1.00), location: 0),
        .init(color: Color(red: 0.90, green: 0.90, blue: 0.94), location: 0.55),
        .init(color: Color(red: 0.83, green: 0.83, blue: 0.88), location: 1),
    ], startPoint: .top, endPoint: .bottom)

    /// The earned accent: an iridescent metal band, angle-swept like real anodization.
    private static let rim = AngularGradient(
        colors: Theme.iridescent + [Theme.iridescent.first ?? .purple],
        center: .center, angle: .degrees(-50))
}

#Preview("States") {
    let century = AwardsCatalog.award("distance.100")!
    let crown = AwardsCatalog.award("distance.5000")!
    return HStack(spacing: 24) {
        AwardMedallion(award: century)
        AwardMedallion(award: crown)
        AwardMedallion(award: century, earned: false, progress: 0.62)
    }
    .padding(32)
    .background(Theme.background)
}
