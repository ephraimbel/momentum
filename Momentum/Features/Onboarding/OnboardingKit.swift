import SwiftUI

/// Permission and review artwork may exceed a compact phone's height or grow with Dynamic Type.
/// Keep the actions in the safe area and let the explanatory content scroll independently.
struct OnboardingHeroPage<Content: View, Actions: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) { content }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
            actions
        }
    }
}

// The onboarding's visual kit (glass pass, 2026-08-27 — owner direction: the minimal, bright,
// glass-and-glow grammar of enterprise health onboardings, in OUR theme and OUR words). One canvas,
// one floating glass back button, one centered heading, one floating choice card, one glowing glyph
// hero for the permission beats, one titanium device frame, one capsule CTA. Every step in
// `OnboardingFlow` is assembled from these, so the flow can never drift into two looks.
//
// Palette refinement: monochrome first, iridescent progress and a faint shared aurora accent.
// Keep the original materials, icons, layout and transforms-only motion;
// Reduce Motion = static.

enum OnboardingStyle {
    /// A restrained shared radius for interview cards and optional detail panels.
    static let cardRadius = 16.0
    static let pageTransition: Animation = .timingCurve(0.22, 0.0, 0.18, 1.0, duration: 0.36)
    static let entrance: Animation = .spring(response: 0.46, dampingFraction: 0.9)
    static let selection: Animation = .spring(response: 0.3, dampingFraction: 0.78)
    static let progress: Animation = .spring(response: 0.5, dampingFraction: 0.88)
    /// White ground to meet the welcome; the original beveled materials remain unchanged.
    /// Preserve the app charcoal in dark appearance.
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Theme.background : .white
    }
}

/// Onboarding has its own arrival rhythm. Everyday screens use the faster `.reveal`; these
/// questions get a little more travel and a soft landing, without delaying input or changing layout.
private struct OnboardingEntrance: ViewModifier {
    let delay: Double
    let lift: CGFloat
    @State private var shown = false
    @ReducedMotionPreference private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : lift)
            .onAppear {
                guard !shown else { return }
                guard !reduceMotion else { shown = true; return }
                withAnimation(OnboardingStyle.entrance.delay(delay)) { shown = true }
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { shown = true }
            }
    }
}

extension View {
    func onboardingEntrance(_ delay: Double = 0, lift: CGFloat = 18) -> some View {
        modifier(OnboardingEntrance(delay: delay, lift: lift))
    }
}

/// Optional precision lives in a focused panel, leaving the interview's main choices in view.
struct OnboardingDetailSheet<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content
    @Environment(\.dismiss) private var dismiss

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    OnboardingHeading(title: title, subtitle: subtitle, size: 27, alignment: .center)
                    VStack(spacing: 12) { content }
                }
                .padding(24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(OnboardingCanvas())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(.rounded(15, weight: .semibold))
                }
            }
        }
        .environment(\.colorScheme, .light)
    }
}

// MARK: - Canvas

/// The page ground: the app canvas with a soft aurora pool breathing in from the top corners —
/// the "glow" of the language, kept faint enough that copy and cards stay on pure ground.
struct OnboardingCanvas: View {
    /// Plain white by default — the welcome is pure white and every question after it is the
    /// same room (owner call 2026-09-05). Only the reveal asks for the icon's pearl sheen.
    var crown = false
    @Environment(\.colorScheme) private var scheme
    @ReducedMotionPreference private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            OnboardingStyle.canvas(scheme)
            if crown {
            // The icon's light, not a stripe. A mesh of the icon's pearl tones laid across the
            // top of the page like refraction on glass — soft patches that drift into one another
            // with no band or edge — dissolving into the canvas before the first control. The
            // lavender aurora that sat here read as a coloured header (owner call 2026-09-05).
            MeshGradient(width: 4, height: 3, points: [
                [0.00, 0.00], [0.33, 0.00], [0.66, 0.00], [1.00, 0.00],
                [0.00, 0.50], [0.30, 0.42], [0.70, 0.58], [1.00, 0.50],
                [0.00, 1.00], [0.33, 1.00], [0.66, 1.00], [1.00, 1.00],
            ], colors: [
                Theme.pearl[3], Theme.pearl[5], Theme.pearl[0], Theme.pearl[1],
                Theme.pearl[2], .white,         Theme.pearl[4], Theme.pearl[3],
                .white,         .white,         .white,         .white,
            ])
            .frame(height: 520)
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0), .init(color: .black, location: 0.35),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom))
            .opacity(scheme == .dark ? 0.22 : 1)
            .transition(reduceMotion ? .opacity : .opacity.animation(.easeOut(duration: 0.6)))
            }
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
    var size: CGFloat = 26
    /// Questions read left-aligned, the welcome's voice (palette pass 2026-09-05); the permission
    /// heroes and the account screen keep their centered glyph and stay centered.
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            Text(title)
                .font(.display(size, weight: .semibold)).tracking(-0.4)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.rounded(15, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineSpacing(2)
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }
}

// MARK: - Floating card surface

/// The floating panel: white with a soft drop on the light canvas; the surface tone with a quiet
/// hairline on the charcoal (a drop shadow does nothing on dark ground).
struct OnboardingCardSurface: ViewModifier {
    var selected = false
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous)
        content
            .background(shape.fill(scheme == .dark ? Theme.surface : .white))
            .overlay(shape.strokeBorder(Theme.ink.opacity(0.055), lineWidth: 0.5))
            .overlay {
                shape.strokeBorder(Theme.ink.opacity(0.75), lineWidth: 1)
                    .opacity(selected ? 1 : 0)
                    .animation(Motion.crossfade, value: selected)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.025), radius: 8, y: 3)
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
    @ReducedMotionPreference private var reduceMotion

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 12) {
                // A small lift in scale acknowledges the choice; no looping or full-card bounce.
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 28, height: 28)
                        .animation(reduceMotion ? nil : OnboardingStyle.selection) { icon in
                            icon.scaleEffect(isSelected && !reduceMotion ? 1.12 : 1)
                        }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.rounded(16, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(.rounded(13, weight: .regular))
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Space.sm)
                indicator
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 54)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(OnboardingCardSurface(selected: isSelected && !iridescent))
            .overlay {
                if iridescent {
                    RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous)
                        .strokeBorder(IridescentMaterial(), lineWidth: 2)
                }
            }
            // The same soft glow `SelectionCard` gives the Podium ring in Plan Settings, so the
            // tier looks identical in setup and in the app.
            .shadow(color: iridescent ? Theme.iridescent[0].opacity(0.4) : .clear, radius: 6)
            .contentShape(RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous))
        }
        .buttonStyle(RaisedPressStyle(scale: 0.98))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Radio: an empty ring, or an ink disc with a small light dot. Check: an ink disc with a tick.
    private var indicator: some View {
        ZStack {
            Circle().strokeBorder(Theme.ink.opacity(scheme == .dark ? 0.3 : 0.16), lineWidth: 1.5)
                .opacity(isSelected ? 0 : 1)
            // Purple means "chosen, right now" — the only accent on the card (owner direction
            // 2026-09-05: subtle purple accents, ink everywhere else).
            Circle().fill(Theme.purple)
                .scaleEffect(isSelected || reduceMotion ? 1 : 0.4)
                .opacity(isSelected ? 1 : 0)
            if multi {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .scaleEffect(isSelected || reduceMotion ? 1 : 0.65)
                    .opacity(isSelected ? 1 : 0)
            } else {
                Circle().fill(.white).frame(width: 9, height: 9)
                    .scaleEffect(isSelected || reduceMotion ? 1 : 0.65)
                    .opacity(isSelected ? 1 : 0)
            }
        }
        .frame(width: 21, height: 21)
        .animation(reduceMotion ? Motion.crossfade : OnboardingStyle.selection, value: isSelected)
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
        // Drawn to Apple's proportions rather than shipping their artwork, and measured off the
        // real icon rather than guessed: the heart is 47% of the tile wide and sits ABOVE and
        // RIGHT of centre (+11% / −13% of the side), not centred. The gradient is VERTICAL,
        // magenta at the top through to red at the foot — a diagonal ramp reads noticeably
        // wrong. Everything scales off `side`, so the ratios hold at any tile size.
        shape.fill(.white)
            .overlay {
                Image(systemName: "heart.fill")
                    // 0.49, not the 0.47 the bbox implies: `heart.fill`'s glyph box is wider
                    // than the shape it draws, so the point size has to be tuned until the
                    // RENDERED heart measures 47% of the tile, which is what this does.
                    .font(.system(size: side * 0.49, weight: .regular))
                    .foregroundStyle(LinearGradient(
                        colors: [Color(hex: "FE61A6"), Color(hex: "FF4563"), Color(hex: "FF302A")],
                        startPoint: .top, endPoint: .bottom))
                    .offset(x: side * 0.109, y: -side * 0.129)
            }
            .frame(width: side, height: side)
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
    /// Draw the Dynamic Island + camera over the screen. Off when the screen content is a real
    /// capture that already carries its own island (the paywall tour), so the two never double up.
    var island: Bool = true
    @ViewBuilder var screen: () -> Screen

    var body: some View {
        let h = width * (640.0 / 300.0)
        // Every fixed-pixel detail below was drawn at width 300; `k` scales them so the same
        // hardware reads right at the paywall deck's smaller size (identical at 300).
        let k = width / 300
        let outer = RoundedRectangle(cornerRadius: h * (64.0 / 640.0), style: .continuous)
        let inner = RoundedRectangle(cornerRadius: h * (52.0 / 640.0), style: .continuous)
        ZStack {
            sideButtons(h: h, k: k)
            // Rail: graphite, with a hairline catch of light — reads as the phone, not a mock.
            outer.fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.13)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            outer.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.08)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
            // Bezel.
            RoundedRectangle(cornerRadius: h * (58.0 / 640.0), style: .continuous)
                .fill(.black)
                .padding(4 * k)
            // Screen.
            screen()
                .frame(width: width - 20 * k, height: h - 20 * k, alignment: .top)
                .clipShape(inner)
                .padding(10 * k)
            // Dynamic Island + camera.
            if island {
                VStack {
                    Capsule().fill(.black)
                        .frame(width: width * 0.31, height: 31 * k)
                        .overlay(alignment: .trailing) {
                            Circle().fill(Color(white: 0.09)).frame(width: 13 * k, height: 13 * k)
                                .overlay(Circle().fill(Color(red: 0.10, green: 0.12, blue: 0.24)).frame(width: 6 * k, height: 6 * k))
                                .padding(.trailing, 8 * k)
                        }
                        .padding(.top, 21 * k)
                    Spacer()
                }
            }
        }
        .frame(width: width, height: h)
        // One Metal composite: the rail gradients, bezel, screen and island flatten into a single
        // layer, so the step's travel animation and the bottom fade never re-rasterize the mock.
        .drawingGroup()
        .accessibilityHidden(true)
    }

    private func sideButtons(h: CGFloat, k: CGFloat) -> some View {
        let metal = Color(white: 0.16)
        return ZStack {
            VStack(spacing: 0) {
                Color.clear.frame(height: h * 0.16)
                button(metal, height: 22 * k, k: k)
                Color.clear.frame(height: 20 * k)
                button(metal, height: 48 * k, k: k)
                Color.clear.frame(height: 12 * k)
                button(metal, height: 48 * k, k: k)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(x: -2 * k)
            VStack(spacing: 0) {
                Color.clear.frame(height: h * 0.22)
                button(metal, height: 78 * k, k: k)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .offset(x: 2 * k)
        }
    }

    private func button(_ fill: Color, height: CGFloat, k: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5 * k, style: .continuous).fill(fill).frame(width: 4 * k, height: height)
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
    /// The beat is waiting on something the athlete can't see — a permission round-trip, a
    /// HealthKit read. Shows a spinner in place of the label and refuses further taps, so the
    /// button never sits there looking dead while work is genuinely in flight (owner ask
    /// 2026-08-28: onboarding must never feel stuck). Same treatment the auth CTA uses.
    var inFlight = false
    let action: () -> Void
    @ReducedMotionPreference private var reduceMotion

    var body: some View {
        Button {
            Haptics.medium()   // the primary step has weight; picks are selection ticks, back is light
            action()
        } label: {
            ZStack {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.rounded(17, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                        .offset(x: isEnabled || reduceMotion ? 0 : -4)
                        .accessibilityHidden(true)
                }
                .opacity(inFlight ? 0 : 1)
                if inFlight { ProgressView().tint(Theme.background) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 58)
            .foregroundStyle(isEnabled ? Theme.background : Theme.inkTertiary)
            // Waiting for a choice, the pill rests as a quiet white surface with grey text —
            // the same object the secondary buttons are — instead of a dimmed black slab
            // (palette pass 2026-09-05). It turns ink the moment it can be pressed.
            .raised(Capsule(), tone: isEnabled ? .ink : .white)
            .contentShape(Capsule())
        }
        .buttonStyle(RaisedPressStyle())
        .disabled(!isEnabled || inFlight)
        .animation(.easeOut(duration: 0.15), value: inFlight)
        .animation(reduceMotion ? Motion.crossfade : OnboardingStyle.selection, value: isEnabled)
        .accessibilityLabel(title)
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
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 44)
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

/// Goals are destinations: a compact two-column gallery, not another long questionnaire list.
struct OnboardingGoalTile: View {
    let goal: Goal
    let selected: Bool
    let action: () -> Void
    @ReducedMotionPreference private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: goal.planSystemImage)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(selected ? Theme.purple : Theme.ink)
                        .scaleEffect(selected && !reduceMotion ? 1.08 : 1)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(selected ? Theme.purple : Theme.ink.opacity(0.15))
                        .contentTransition(.opacity)
                }
                Text(goal.planLabel).font(.rounded(14, weight: .semibold))
                    .foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 116 : 102, alignment: .topLeading)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(selected ? Theme.purple : Theme.hairline, lineWidth: selected ? 1.5 : 1) }
            .shadow(color: Theme.ink.opacity(selected ? 0.05 : 0.02), radius: 8, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(RaisedPressStyle(scale: 0.98))
        .animation(reduceMotion ? nil : OnboardingStyle.selection, value: selected)
        .accessibilityLabel(goal.planLabel)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The answer owns the illustration: selecting a starting point acknowledges that row in place.
/// The button's frame never changes, including under Reduce Motion or repeated taps.
struct OnboardingBackgroundChoice: View {
    let symbol: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void
    @ReducedMotionPreference private var reduceMotion

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(isSelected ? Theme.purple : Theme.inkSecondary)
                    .frame(width: 46, height: 50)
                    .background(isSelected ? Theme.purple.opacity(0.08) : Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    .scaleEffect(isSelected && !reduceMotion ? 1.06 : 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.rounded(16, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(subtitle).font(.rounded(13, weight: .regular)).foregroundStyle(Theme.inkSecondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).foregroundStyle(isSelected ? Theme.purple : Theme.ink.opacity(0.15))
                    .contentTransition(.opacity)
            }
            .padding(16).frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(isSelected ? Theme.purple : Theme.hairline, lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(RaisedPressStyle(scale: 0.99))
        .animation(reduceMotion ? nil : OnboardingStyle.selection, value: isSelected)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A calendar that is the actual preference control, not a second decorative copy of its answers.
struct OnboardingWeekPicker: View {
    @Binding var selectedDays: Set<Int>
    var onSelection: () -> Void
    @ReducedMotionPreference private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(Array(1...7))
            VStack(spacing: 8) { row(Array(1...4)); row(Array(5...7)) }
        }.frame(maxWidth: .infinity)
    }

    private func row(_ days: [Int]) -> some View {
        HStack(spacing: 2) {
            ForEach(days, id: \.self) { day in
                let selected = selectedDays.contains(day)
                Button {
                    Haptics.selection()
                    if selected { selectedDays.remove(day) } else { selectedDays.insert(day) }
                    onSelection()
                } label: {
                    VStack(spacing: 12) {
                        Text(Calendar.current.veryShortWeekdaySymbols[day - 1])
                            .font(.rounded(14, weight: .semibold))
                            .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                        Image(systemName: selected ? "checkmark" : "minus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected ? Theme.purple : Theme.ink.opacity(0.18))
                            .contentTransition(.opacity)
                            .scaleEffect(selected && !reduceMotion ? 1.1 : 1)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 72)
                    .background(selected ? Theme.purple.opacity(0.07) : Theme.background, in: RoundedRectangle(cornerRadius: 14))
                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Theme.purple : Theme.hairline) }
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(RaisedPressStyle(scale: 0.96))
                .animation(reduceMotion ? nil : OnboardingStyle.selection, value: selected)
                .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
}

/// A truthful preview of the coaching loop. No fake processing, locked weeks, or extra step.
struct OnboardingCoachingLoop: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A starting point. Then a plan that learns.")
                .font(.rounded(15, weight: .semibold)).foregroundStyle(Theme.ink)
            HStack(alignment: .top, spacing: 10) {
                beat("calendar", title: "Your first week", index: 0)
                arrow
                beat("checkmark.bubble", title: "Your feedback", index: 1)
                arrow
                beat("arrow.trianglehead.2.clockwise.rotate.90", title: "Next week reviewed", index: 2)
            }
        }.padding(.horizontal, 6).padding(.vertical, 8)
    }
    private var arrow: some View {
        Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.inkTertiary).padding(.top, 12).accessibilityHidden(true)
    }
    private func beat(_ icon: String, title: String, index: Int) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 19, weight: .light))
                .foregroundStyle(index == 0 ? Theme.purple : Theme.inkSecondary)
                .frame(height: 36).accessibilityHidden(true)
            Text(title).font(.rounded(11, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity)
    }
}
