import SwiftUI

// The onboarding's visual kit (glass pass, 2026-08-27 — owner direction: the minimal, bright,
// glass-and-glow grammar of enterprise health onboardings, in OUR theme and OUR words). One canvas,
// one floating glass back button, one centered heading, one floating choice card, one glowing glyph
// hero for the permission beats, one titanium device frame, one capsule CTA. Every step in
// `OnboardingFlow` is assembled from these, so the flow can never drift into two looks.
//
// Rules carried through: monochrome first, lavender = tappable/selected only, iridescence only on
// the progress bar (a genuine progress surface) and never on a card; transforms-only motion;
// Reduce Motion = static.

enum OnboardingStyle {
    /// Cards float, so they take the sheet radius (the radius law: 22 for anything that reads as
    /// a panel); chips stay capsules.
    static let cardRadius = 20.0
    /// The page ground: a flat cool gray on light (white cards float on it with almost no shadow);
    /// the app charcoal on dark.
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Theme.background : Color(hex: "F5F5F7")
    }
}

// MARK: - Canvas

/// The page ground: the app canvas with a soft aurora pool breathing in from the top corners —
/// the "glow" of the language, kept faint enough that copy and cards stay on pure ground.
struct OnboardingCanvas: View {
    /// The crown: a soft aurora falling from the top edge of the screen, gone within ~half the
    /// page. Earned — it's ON only for the plan reveal (the page that marks an achievement); the
    /// questions stay on flat ground.
    var crown = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            OnboardingStyle.canvas(scheme)
            LinearGradient(stops: [
                .init(color: Theme.iridescent[0].opacity(scheme == .dark ? 0.35 : 0.6), location: 0),
                .init(color: Theme.iridescent[1].opacity(scheme == .dark ? 0.18 : 0.3), location: 0.45),
                .init(color: Theme.iridescent[2].opacity(0.1), location: 0.78),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: 460)
            .opacity(crown ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: crown)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Glass circle button (back)

/// A floating glass disc with one glyph — the back chevron's home. Liquid Glass on iOS 26, with a
/// soft drop so it reads as lifted off the canvas.
struct GlassCircleButton: View {
    let systemName: String
    let label: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 46, height: 46)
                .raised(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(RaisedPressStyle(scale: 0.92))
        .accessibilityLabel(label)
    }
}

// MARK: - Heading

/// Title + one line of context, centered — the display face for the question, the UI face for
/// the explanation.
struct OnboardingHeading: View {
    let title: String
    var subtitle: String? = nil
    var size: CGFloat = 30

    var body: some View {
        VStack(spacing: Theme.Space.sm + 2) {
            Text(title)
                .font(.rounded(size, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.rounded(18, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineSpacing(3)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Floating card surface

/// The floating panel: white with a soft drop on the light canvas; the surface tone with a quiet
/// hairline on the charcoal (a drop shadow does nothing on dark ground).
struct OnboardingCardSurface: ViewModifier {
    var selected = false
    func body(content: Content) -> some View {
        content.raised(RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous),
                       selected: selected)
    }
}

extension View {
    func onboardingCard(selected: Bool = false) -> some View {
        modifier(OnboardingCardSurface(selected: selected))
    }
}

// MARK: - Choice card

/// One option: a bold title, an optional plain line under it, an optional glyph, and a radio (or
/// a check for multi-select) on the trailing edge. Selected = ink stroke + filled indicator; the
/// card itself never fills with color, so a page of choices stays calm. Selection haptic on tap.
struct ChoiceCard: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var isSelected: Bool = false
    /// Multi-select pickers show a check instead of a radio.
    var multi: Bool = false
    /// The earned iridescent ring — reserved for the ONE option that IS the earned tier (Podium).
    var iridescent: Bool = false
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: Theme.Space.md) {
                // The glyph disc (owner call 2026-08-27: keep the icons): quiet gray at rest,
                // lavender-tint when picked — the one place color enters a card.
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.purpleDeep : Theme.ink)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(isSelected ? Theme.purpleTint : Theme.tintedField))
                        .symbolEffect(.bounce, value: isSelected)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.rounded(19, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(.rounded(16, weight: .regular))
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Space.sm)
                indicator
            }
            .padding(.horizontal, systemImage == nil ? 22 : 16)
            .padding(.vertical, subtitle == nil ? (systemImage == nil ? 22 : 14) : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(OnboardingCardSurface(selected: isSelected && !iridescent))
            .overlay {
                if iridescent {
                    RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous)
                        .strokeBorder(IridescentMaterial(), lineWidth: 2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous))
        }
        .buttonStyle(RaisedPressStyle(scale: 0.975))
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Radio: an empty ring, or an ink disc with a small light dot. Check: an ink disc with a tick.
    private var indicator: some View {
        ZStack {
            Circle().strokeBorder(Theme.ink.opacity(scheme == .dark ? 0.3 : 0.16), lineWidth: 1.5)
                .opacity(isSelected ? 0 : 1)
            Circle().fill(Theme.ink)
                .scaleEffect(isSelected ? 1 : 0.4)
                .opacity(isSelected ? 1 : 0)
            if multi {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.background)
                    .opacity(isSelected ? 1 : 0)
            } else {
                Circle().fill(.white).frame(width: 9, height: 9)
                    .opacity(isSelected ? 1 : 0)
            }
        }
        .frame(width: 26, height: 26)
    }
}

// MARK: - Glow glyph (permission heroes)

/// A glass glyph lit from beneath by one soft color — the hero of every permission beat. The glyph
/// is a light-to-silver gradient with a hairline drop so it reads as a physical piece of glass;
/// the tint is the only color on the page. Static (no pulse), so Reduce Motion needs nothing.
struct GlowGlyph: View {
    let systemName: String
    var tint: Color = Theme.iridescent[0]
    var size: CGFloat = 54

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(
                LinearGradient(colors: scheme == .dark
                               ? [Color.white, Color(white: 0.78)]
                               : [Color.white, Color(white: 0.80)],
                               startPoint: .top, endPoint: .bottom))
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.18), radius: 1, y: 1)
            .shadow(color: tint.opacity(scheme == .dark ? 0.7 : 0.75), radius: 14, y: 6)
            .shadow(color: tint.opacity(0.25), radius: 30, y: 10)
            .frame(height: size + 24)
            .accessibilityHidden(true)
    }
}

// MARK: - Health tile

/// The Health beat's hero: the Apple Health app icon itself, as the athlete knows it — a white
/// app-icon squircle with the heart running pink to red on a diagonal (owner call 2026-08-28:
/// "make sure it's the actual Apple Health icon"). It was a rose heart on a lit glass tile in our
/// own palette before, which read as *our* icon, not the one the system sheet is about to show.
/// App-icon curvature (22.4% of the edge), a neutral lift, no coloured glow.
struct HealthTile: View {
    var body: some View {
        let side: CGFloat = 84
        let shape = RoundedRectangle(cornerRadius: side * 0.224, style: .continuous)
        Image(systemName: "heart.fill")
            .font(.system(size: 44, weight: .regular))
            .foregroundStyle(LinearGradient(colors: [Color(hex: "FF7A9C"), Color(hex: "FF3B63"), Color(hex: "FF2A50")],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: side, height: side)
            .background { shape.fill(.white) }
            .overlay { shape.strokeBorder(.black.opacity(0.06), lineWidth: 0.6) }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            .shadow(color: .black.opacity(0.08), radius: 14, y: 8)
            .accessibilityHidden(true)
    }
}

// MARK: - Device frame

/// A real iPhone, not a rounded rectangle: titanium rail with a brushed highlight, the black
/// bezel, the Dynamic Island with its camera, and the side hardware (action, volume, power) as
/// small protrusions. Every mock in the flow wears this; the screen inside is whatever the beat
/// needs (a real capture, or a composed lock screen). Proportions follow a 6.1" body at 300pt.
struct DeviceFrame<Screen: View>: View {
    var width: CGFloat = 300
    @ViewBuilder var screen: () -> Screen

    var body: some View {
        let h = width * (640.0 / 300.0)
        let outer = RoundedRectangle(cornerRadius: h * (64.0 / 640.0), style: .continuous)
        let inner = RoundedRectangle(cornerRadius: h * (52.0 / 640.0), style: .continuous)
        ZStack {
            sideButtons(h: h)
            // Rail: graphite, with a hairline catch of light — reads as the phone, not a mock.
            outer.fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.13)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            outer.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.08)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
            // Bezel.
            RoundedRectangle(cornerRadius: h * (58.0 / 640.0), style: .continuous)
                .fill(.black)
                .padding(4)
            // Screen.
            screen()
                .frame(width: width - 20, height: h - 20, alignment: .top)
                .clipShape(inner)
                .padding(10)
            // Dynamic Island + camera.
            VStack {
                Capsule().fill(.black)
                    .frame(width: width * 0.31, height: 31)
                    .overlay(alignment: .trailing) {
                        Circle().fill(Color(white: 0.09)).frame(width: 13, height: 13)
                            .overlay(Circle().fill(Color(red: 0.10, green: 0.12, blue: 0.24)).frame(width: 6, height: 6))
                            .padding(.trailing, 8)
                    }
                    .padding(.top, 21)
                Spacer()
            }
        }
        .frame(width: width, height: h)
        // One Metal composite: the rail gradients, bezel, screen and island flatten into a single
        // layer, so the step's travel animation and the bottom fade never re-rasterize the mock.
        .drawingGroup()
        .accessibilityHidden(true)
    }

    private func sideButtons(h: CGFloat) -> some View {
        let metal = Color(white: 0.16)
        return ZStack {
            VStack(spacing: 0) {
                Color.clear.frame(height: h * 0.16)
                button(metal, height: 22)
                Color.clear.frame(height: 20)
                button(metal, height: 48)
                Color.clear.frame(height: 12)
                button(metal, height: 48)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(x: -2)
            VStack(spacing: 0) {
                Color.clear.frame(height: h * 0.22)
                button(metal, height: 78)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .offset(x: 2)
        }
    }

    private func button(_ fill: Color, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(fill).frame(width: 4, height: height)
    }
}

/// Dissolve a view's lower part into the canvas — the permission mocks end in air, not an edge.
struct BottomFade: ViewModifier {
    var from: CGFloat = 0.5
    func body(content: Content) -> some View {
        content.mask(
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: .black, location: from),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom))
    }
}

extension View {
    func bottomFade(from: CGFloat = 0.5) -> some View { modifier(BottomFade(from: from)) }
}

// MARK: - Health access mock

/// An abstract stand-in for the Health permission sheet that follows: the shape of what the athlete
/// is about to see (a list of signal rows with toggles), not the real thing — pastel dots from our
/// own aurora, no system text beyond the app's name.
struct HealthSheetMock: View {
    var body: some View {
        DeviceFrame {
            ZStack(alignment: .top) {
                Color(hex: "F2F2F7")
                VStack(spacing: 0) {
                    // Status bar.
                    HStack {
                        Text("9:41").font(.system(size: 14, weight: .semibold, design: .rounded))
                        Spacer()
                        HStack(spacing: 5) {
                            Image(systemName: "cellularbars"); Image(systemName: "wifi"); Image(systemName: "battery.100")
                        }.font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22).padding(.top, 18)
                    // Nav: Don't Allow · Health Access · Allow (the real sheet's chrome).
                    HStack {
                        Text("Don't Allow").foregroundStyle(Color(hex: "007AFF"))
                        Spacer()
                        Text("Health Access").fontWeight(.semibold).foregroundStyle(.black)
                        Spacer()
                        Text("Allow").fontWeight(.semibold).foregroundStyle(Color(hex: "007AFF"))
                    }
                    .font(.system(size: 15))
                    .padding(.horizontal, 16).padding(.top, 34)
                    HStack(spacing: 10) {
                        Image("BrandIcon").resizable().scaledToFit().frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\"momentum\" would like to access and update your Health data.")
                                .font(.system(size: 12)).foregroundStyle(.black)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 22)
                    // Turn On All.
                    HStack {
                        Text("Turn On All").font(.system(size: 15)).foregroundStyle(Color(hex: "007AFF"))
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
                    .padding(.horizontal, 16).padding(.top, 20)
                    Text("ALLOW \"MOMENTUM\" TO READ")
                        .font(.system(size: 11)).foregroundStyle(Color(hex: "6D6D72"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 6)
                    VStack(spacing: 0) {
                        ForEach(Array([("Sleep", Color(hex: "5AC8FA")), ("Heart Rate", Color(hex: "FF2D55")),
                                       ("Heart Rate Variability", Color(hex: "FF2D55")), ("Resting Heart Rate", Color(hex: "FF2D55")),
                                       ("Body Mass", Color(hex: "AF52DE"))].enumerated()), id: \.offset) { i, row in
                            if i > 0 { Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5).padding(.leading, 44) }
                            HStack(spacing: 12) {
                                Circle().fill(row.1).frame(width: 18, height: 18)
                                Text(row.0).font(.system(size: 15)).foregroundStyle(.black)
                                Spacer()
                                Capsule().fill(Color(hex: "E9E9EB")).frame(width: 46, height: 28)
                                    .overlay(alignment: .leading) {
                                        Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                                    }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
                    .padding(.horizontal, 16)
                }
            }
            .environment(\.colorScheme, .light)
        }
    }
}

// MARK: - CTA + secondary

/// The primary action: an ink capsule, tall, full width. Light haptic on tap. The label stays a
/// neutral word on permission beats (App Review 5.1.1(iv)).
struct OnboardingCTA: View {
    let title: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.medium()   // the primary step has weight; picks are selection ticks, back is light
            action()
        } label: {
            Text(title)
                .font(.rounded(19, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 62)
                .foregroundStyle(Theme.background)
                .raised(Capsule(), tone: .ink)
                .contentShape(Capsule())
        }
        .buttonStyle(RaisedPressStyle())
        .opacity(isEnabled ? 1 : 0.35)
        .disabled(!isEnabled)
    }
}

/// The quiet way past an optional beat.
struct OnboardingSecondary: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Text(title)
                .font(.rounded(Theme.FontSize.body, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .frame(maxWidth: .infinity).frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview("Choices") {
    ZStack {
        OnboardingCanvas()
        VStack(spacing: 12) {
            OnboardingHeading(title: "How many days a week?", subtitle: "We'll shape your week around this.")
            ChoiceCard(title: "3 days", subtitle: "A steady base", isSelected: true) {}
            ChoiceCard(title: "4 days", subtitle: "Consistent") {}
            ChoiceCard(title: "Run", systemImage: "figure.run", isSelected: true, multi: true) {}
            OnboardingCTA(title: "Continue") {}
        }.padding()
    }
}

#Preview("Glyph") {
    ZStack {
        OnboardingCanvas()
        VStack(spacing: 24) {
            GlowGlyph(systemName: "bell.fill", tint: Theme.iridescent[1])
            GlowGlyph(systemName: "location.north.fill", tint: Theme.iridescent[0])
            GlowGlyph(systemName: "heart.fill", tint: Theme.iridescent[2])
            HealthSheetMock().padding()
        }
    }
}
