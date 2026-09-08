import SwiftUI

/// A photographic welcome. Only the artwork moves; reading and touch targets stay stationary.
/// The real entry gate owns authentication, draft recovery and presentation of the interview.
///
/// Refinement pass (2026-09-05): every photograph rides ONE S-shaped path, evenly spaced, so
/// the column reads as a single procession — never two circles crowding or clipping. The path
/// swings furthest right level with the message, so the nearest photograph sits just off the
/// end of the copy (the reference the owner chose). The wordmark and the actions are carved out
/// of the gallery's own mask with soft holes instead of blurred white rectangles painted over
/// the photos, which used to leave pale smudges. The lens no longer deforms silhouettes.
struct WelcomeGalleryView: View {
    var primaryTitle = "Build my plan"
    let onStart: () -> Void
    let onSignIn: () -> Void
    var isActive = true

    /// More photographs than orbits: each orbit shows the next photograph every time it wraps
    /// off the bottom, so the whole set comes round without crowding the screen.
    private let galleryImages = ["WelcomeGallery10", "WelcomeGallery6", "WelcomeGallery12",
                                 "WelcomeGallery7", "WelcomeRunCrew", "WelcomeGallery8",
                                 "WelcomeGallery13", "WelcomeGallery9", "WelcomeGallery11",
                                 "WelcomeRecovery", "WelcomeGallery14", "WelcomeRunnersHigh",
                                 "WelcomeGallery15"]
    /// Eight photographs ride ONE path, evenly spaced along it (a period apart divided by eight),
    /// so two can never crowd or overlap: the vertical gap between neighbours is always larger
    /// than the biggest circle. Diameters vary gently, as a share of the screen width.
    /// Each orbit owns a DISJOINT slice of the photographs (every seventh, starting at its own
    /// index) and steps through that slice one lap at a time — so two orbits can never show the
    /// same photograph at once, whatever the count.
    private static let orbitCount = 7
    private static let diameters: [CGFloat] = [0.26, 0.20, 0.24, 0.18, 0.25, 0.21, 0.23]
    /// The orbit's climb rate in wrap-periods per second — one screen crossing in about 25 s.
    private static let driftPerSecond = 0.04

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @ReducedMotionPreference private var reduceMotion
    @State private var appeared = false
    @State private var departing = false
    @State private var animationClock = WelcomeAnimationClock()
    @State private var interaction = WelcomeGalleryMotion()
    @State private var touchPoint = CGPoint(x: -300, y: -300)
    /// Frames of the reading and touch surfaces, in the gallery's coordinate space; the gallery
    /// mask carves a soft hole around each so no photograph ever sits under the words.
    @State private var cutouts: [CGRect] = []
    /// Gallery-clock time at which "Build my plan" was pressed; drives the exit choreography.
    @State private var departAt: Double?
    /// The exit has played out; the clock may stop (the flow now owns the screen above us).
    @State private var departed = false
    /// The actions are gone from the hierarchy — not merely faded — once the flow is raised, so
    /// nothing can find "Build my plan" beneath the first question.
    @State private var actionsRemoved = false
    @State private var handoffSent = false
    @State private var landingHapticSent = false

    /// The exit: every circle gathers to the centre and stacks into one disc, the glass runner
    /// rises out of it onto a pearl glow and HOLDS there. Paced, not rushed: gather over 0.6 s,
    /// then the landed icon rests — this screen never bursts. The burst, and the first question
    /// dissolving in beneath it, belong to the onboarding cover (`Handoff`), so whatever frame
    /// the cover arrives on — a loaded device can be late — the frame beneath it is still the
    /// same resting icon, and the take-over is invisible.
    private static let gatherS = 0.60
    private static let holdS = 0.34   // the icon holds the centre for a breath before the burst
    private static let warpS = 0.50
    /// The exit is spent — the gallery clock may stop on the resting frame.
    private static let spentS = gatherS + holdS + 0.5

    /// The hand-off to the flow, in one place.
    ///
    /// A third of the way into the HOLD this screen signs in (`onStart`), and the root inserts the
    /// flow INLINE on that very frame — a sibling above this screen, never a `fullScreenCover`:
    /// a cover slides up from the bottom whatever the transaction says and lands whenever UIKit
    /// gets to it, and one presented with any custom backdrop breaks hit-testing for life
    /// (transparent: touches pass through wherever content is transparent — the plan reveal's
    /// scroll went dead in the gap between two stat tiles; opaque white: taps on opacity-0
    /// content swallowed — all bisected 2026-09-05, `OnboardingNoRatingUITests`). The flow's
    /// first frame reproduces the resting icon exactly (`WelcomeHandoffBurst`), holds it for the
    /// rest of the hold, then bursts while the first question surfaces beneath.
    enum Handoff {
        /// Seconds after the tap at which this screen signs in and the root inserts the flow
        /// (mid-hold, a static frame — so a late frame is invisible).
        static let coverRaiseS = gatherS + holdS * 0.3
        /// The flow holds the landed icon this long before its burst — the rest of the hold.
        static let coverHoldS = holdS * 0.7
        static let warpS = WelcomeGalleryView.warpS
        /// Seconds after the flow appears at which the first question begins to surface: a
        /// third of the way into the burst.
        static let revealDelayS = coverHoldS + warpS * 0.35
        /// The burst is over: the flow's landing layer can go.
        static let spentS = coverHoldS + warpS + 0.25
    }

    private var shouldRun: Bool { isActive && scenePhase == .active && !reduceMotion && !departed }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white.ignoresSafeArea()
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !shouldRun)) { _ in
                    let time = reduceMotion ? 0 : elapsed()
                    ZStack {
                        // Once the photographs have fully dissolved into the icon there is nothing
                        // left to draw here — and a full-screen lens re-rendered at 60 fps for an
                        // invisible layer is exactly the main-thread load that would delay the
                        // flow's reveal timer. Drop it.
                        if landFade(gatherProgress(at: time)) < 1 {
                            gallery(size: geometry.size, time: time)
                        }
                        // The icon is drawn OUTSIDE the gallery's lens, so it lands crisp.
                        brandLanding(size: geometry.size, time: time)
                    }
                    .onChange(of: departureStage(at: time)) { _, _ in advanceDeparture(at: time) }
                }
                .contentShape(Rectangle())
                .gesture(galleryGesture(size: geometry.size))
                .allowsHitTesting(isActive && !departing && !typeSize.isAccessibilitySize)
                .accessibilityHidden(true)
                .opacity(appeared || reduceMotion ? 1 : 0)
                .opacity(departing && reduceMotion ? 0 : 1)

                if typeSize.isAccessibilitySize {
                    ScrollView {
                        content(minHeight: geometry.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    content(minHeight: geometry.size.height)
                }
            }
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(WelcomeCutoutKey.self) { cutouts = $0 }
            .clipped()
        }
        .background(Color.white.ignoresSafeArea())
        .environment(\.colorScheme, .light)
        // Once the exit begins this screen is spent: it stays mounted beneath the arriving flow
        // only so the burst can finish, and must vanish from the accessibility tree at once so
        // nothing (VoiceOver, UI tests) can find "Build my plan" under the first question.
        .accessibilityHidden(departing)
        .onAppear {
            if !handoffSent {
                departing = false
                departAt = nil
                departed = false
                actionsRemoved = false
                landingHapticSent = false
            }
            updateClock()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.8)) { appeared = true }
        }
        .task {
            #if DEBUG
            // `--welcome-depart`: fire the exit choreography on its own one second in, so it can
            // be photographed at wall-clock offsets (screen recording slows the simulator and
            // stretches every timing it captures).
            if ProcessInfo.processInfo.arguments.contains("--welcome-depart") {
                do { try await Task.sleep(for: .seconds(2.6)) }
                catch { return }
                startDeparture()
            }
            #endif
        }
        .onChange(of: shouldRun) { updateClock() }
        .onChange(of: reduceMotion) { if reduceMotion { finishReducedDeparture() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { finishReducedDeparture() }
        }
        .onDisappear { pauseClock() }
    }

    private static let space = "welcome.gallery"

    private func content(minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("momentum")
                .font(.display(19, weight: .semibold)).tracking(-0.8)
                .accessibilityLabel("Momentum")
                .reportCutout()
                .opacity(departing ? 0 : 1)
                .allowsHitTesting(false)
            Spacer(minLength: 70)
            // The same heading object every question uses, so the welcome and the interview
            // speak in one voice (owner call 2026-09-05).
            OnboardingHeading(title: "Keep moving.", subtitle: "A running plan that\nmoves with you.")
                .padding(.vertical, 16)
            .onboardingEntrance(0.05, lift: 10)
            .opacity(departing ? 0 : 1)
            .allowsHitTesting(false)
            Spacer(minLength: 90)
            if !actionsRemoved {
            VStack(spacing: 6) {
                Button {
                    startDeparture()
                } label: {
                    HStack(spacing: 14) {
                        Text(primaryTitle).font(.rounded(17, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 25).padding(.vertical, 16)
                    .frame(minHeight: 52)
                    .foregroundStyle(.white).background(.black, in: Capsule())
                }
                .buttonStyle(RaisedPressStyle())
                .accessibilityIdentifier("welcome.gallery.start")
                Button("I already have an account", action: onSignIn)
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .reportCutout()
            .onboardingEntrance(0.1, lift: 12)
            .opacity(departing ? 0 : 1)
            .disabled(departing)
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 28)
        .padding(.top, 14).padding(.bottom, 8)
        .frame(minHeight: minHeight, alignment: .topLeading)
    }

    /// 0…1 across the gather, eased; 0 while resting.
    private func gatherProgress(at time: Double) -> Double {
        guard let departAt else { return 0 }
        let t = min(1, max(0, (time - departAt) / Self.gatherS))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2   // ease in-out cubic
    }
    /// Always 0: the burst plays on the onboarding cover (`Handoff`), never here — the icon
    /// beneath the arriving cover must be at rest whenever the cover lands. The parameter stays
    /// so the lens and the landing keep one signature with the cover's `WelcomeLandingMark`.
    private func warpProgress(at time: Double) -> Double { 0 }

    /// The photographs become the app icon. As the last circles land, the glass runner rises
    /// out of the stack on a soft pearl glow, holds the centre for a breath, then rides the
    /// burst out with everything else.
    @ViewBuilder
    private func brandLanding(size: CGSize, time: Double) -> some View {
        if departAt != nil {
            let gather = gatherProgress(at: time)
            let warp = warpProgress(at: time)
            let riseT = min(1, max(0, (gather - 0.55) / 0.45))
            let rise = riseT * riseT * (3 - 2 * riseT)
            WelcomeLandingMark(rise: rise, warp: warp)
                .position(x: size.width / 2, y: size.height / 2)
        }
    }

    /// 0…1 over the last quarter of the gather: the circles fade beneath the rising icon.
    private func landFade(_ gather: Double) -> Double {
        let t = min(1, max(0, (gather - 0.72) / 0.28))
        return t * t * (3 - 2 * t)
    }

    private func gallery(size: CGSize, time: Double) -> some View {
        // Gather from the tapped frame. An orbit wrapping mid-gather would teleport a photograph
        // that is now being pulled onto the screen, even though its ordinary wrap is offscreen.
        let orbitTime = departAt ?? time
        let pose = reduceMotion ? WelcomeGalleryMotion.Pose(phase: 0, horizontal: 0, contact: 0)
            : interaction.pose(at: orbitTime)
        let gather = gatherProgress(at: time)
        let warp = warpProgress(at: time)
        return ZStack {
            Color.white
            ForEach(0..<Self.orbitCount, id: \.self) { index in
                let seed = Double(index)
                // Wrapping happens beyond both screen edges, so an orbit never visibly resets.
                let raw = seed / Double(Self.orbitCount) * 1.64 + orbitTime * Self.driftPerSecond + pose.phase
                let travel = WelcomeGalleryMotion.wrappedTravel(raw)
                // Which lap this orbit is on; every lap advances it by one photograph. The swap
                // happens off-screen (at the wrap), so nothing ever changes in front of the eye.
                let lap = WelcomeGalleryMotion.photoLap(raw)
                let mine = Array(stride(from: index, to: galleryImages.count, by: Self.orbitCount))
                let photo = mine[((lap % mine.count) + mine.count) % mine.count]
                let depth = 0.5 + 0.5 * cos(travel * 4.6 + seed * 0.4)
                let scale = 0.92 + 0.08 * depth
                let diameter = min(120, size.width * Self.diameters[index % Self.diameters.count])
                // THE path. One S-curve for every circle: it enters at the top left beside the
                // wordmark, swings right, and reaches its furthest point level with the message
                // so the nearest photograph sits just off the end of the copy, then returns to
                // the left to leave beside the actions. Outside the screen the curve holds its
                // edge value, so the entry and exit are straight.
                let along = min(1, max(0, travel))
                // Enters just right of the wordmark (0.44), bulges to 0.78 level with the message, into the glass,
                // so the nearest circle's edge sits a thumb's width off the end of the copy, and
                // drifts left as it descends to leave at 0.18, beside the actions.
                let x = 0.44 + 0.47 * sin(.pi * along) - 0.28 * along
                // Resting offset, then the gather pulls every circle (on-screen or not) to the
                // centre and shrinks it toward one shared disc. Later orbits arrive a beat after
                // earlier ones so the stack reads as gathering, not snapping.
                let restX = size.width * (x - 0.5) + pose.horizontal * (0.45 + depth * 0.55)
                let restY = size.height * (travel - 0.5)
                let g = min(1, max(0, gather * 1.25 - Double(index) * 0.04))
                let gx = restX * (1 - g), gy = restY * (1 - g)
                let gs = scale * (1 - 0.45 * g)
                Image(galleryImages[photo])
                    .resizable().scaledToFill()
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.6)
                    }
                    .scaleEffect(gs)
                    .offset(x: gx, y: gy)
            }
        }
        .frame(width: size.width, height: size.height)
        .drawingGroup(opaque: true, colorMode: .linear)
        // During the warp the lens flares from the centre: the touch light is planted at the
        // stack and held at full contact, so the disc appears to burst through the pane.
        .layerEffect(ShaderLibrary.welcomeRefraction(.float2(size.width, size.height),
                     .float2(warp > 0 ? size.width / 2 : touchPoint.x, warp > 0 ? size.height / 2 : touchPoint.y),
                     .float(max(pose.contact, warp > 0 ? 1 : 0)), .float(time)),
                     maxSampleOffset: CGSize(width: 26, height: 10))
        .mask { galleryMask(size: size, open: departAt != nil) }
        // The photographs are spent once the icon has risen out of them: they dissolve under
        // it during the landing, so the burst that follows is the icon's light, not a photo.
        .opacity((1 - landFade(gather)) * (typeSize.isAccessibilitySize ? 0.24 : 1))
    }

    /// The vertical fade at both ends plus a soft hole around every reading surface. Carving
    /// the gallery is what keeps the words crisp; nothing is ever painted over a photograph.
    private func galleryMask(size: CGSize, open: Bool = false) -> some View {
        ZStack {
            // The top fade ends just above the wordmark's line, so an orbit is gone before it
            // could sit beside the brand; the bottom fade covers the actions' home row.
            LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.10),
                .init(color: .black, location: 0.92), .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom)
            // Wide, soft holes: a photograph dissolves as it nears the words, like light falling
            // off, rather than being erased along a visible rectangle.
            // The holes close during the exit: the words are already stepping aside, and the
            // circles must be free to cross the centre.
            ForEach(Array((open ? [] : cutouts).enumerated()), id: \.offset) { _, rect in
                RoundedRectangle(cornerRadius: min(40, rect.height / 2), style: .continuous)
                    .fill(.black)
                    .frame(width: rect.width + 24, height: rect.height + 12)
                    .position(x: rect.midX, y: rect.midY)
                    .blur(radius: 26)
                    .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
        .frame(width: size.width, height: size.height)
    }

    /// "Build my plan": the words step aside, the circles gather into one disc, the disc warps
    /// through the glass to white, and only then is the flow raised beneath it.
    private func startDeparture() {
        guard !departing, isActive, scenePhase == .active else { return }
        Haptics.light()
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.12)) { departing = true } completion: {
                finishReducedDeparture()
            }
            return
        }
        departAt = elapsed()
        withAnimation(.easeOut(duration: 0.45)) { departing = true }
    }

    private func departureStage(at time: Double) -> Int {
        guard let departAt else { return 0 }
        let t = time - departAt
        if t >= Self.spentS { return 4 }
        if t >= Self.Handoff.coverRaiseS { return 3 }
        if t >= Self.gatherS { return 2 }
        return t >= 0.45 ? 1 : 0
    }

    /// Use the rendered clock, not independent sleeping tasks. On a missed frame all due beats
    /// execute in order, exactly once; backgrounding pauses the choreography and its callbacks.
    private func advanceDeparture(at time: Double) {
        guard shouldRun, departing else { return }
        let stage = departureStage(at: time)
        if stage >= 1 { actionsRemoved = true }
        if stage >= 2, !landingHapticSent {
            landingHapticSent = true
            Haptics.medium()
        }
        if stage >= 3 { sendHandoff() }
        if stage >= 4 { departed = true }
    }

    private func sendHandoff() {
        guard !handoffSent else { return }
        handoffSent = true
        onStart()
    }

    private func finishReducedDeparture() {
        guard (reduceMotion || departAt == nil), departing, isActive, scenePhase == .active else { return }
        actionsRemoved = true
        departed = true
        sendHandoff()
    }

    private func updateClock() {
        if shouldRun {
            animationClock.setRunning(true)
            advanceDeparture(at: elapsed())
        } else {
            // An interrupted drag must release, but its current pose must not snap sideways.
            interaction.release(predictedDeltaY: 0, height: 1, at: elapsed())
            pauseClock()
        }
    }

    private func elapsed() -> Double { animationClock.elapsed() }

    private func galleryGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard shouldRun, !departing else { return }
                touchPoint = value.location
                interaction.drag(x: value.translation.width, y: value.translation.height,
                                 height: size.height, at: elapsed())
            }
            .onEnded { value in
                guard shouldRun, !departing else { return }
                interaction.release(predictedDeltaY: value.predictedEndTranslation.height - value.translation.height,
                                    height: size.height, at: elapsed())
            }
    }

    private func pauseClock() {
        animationClock.setRunning(false)
    }
}

// MARK: - Cutouts

/// Frames the gallery must stay out of, gathered from the wordmark, the message and the actions.
private struct WelcomeCutoutKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

private extension View {
    /// Report this view's frame (in the gallery's space) so the photographs are carved away from it.
    func reportCutout() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: WelcomeCutoutKey.self,
                                       value: [proxy.frame(in: .named("welcome.gallery"))])
            }
        }
    }
}

// MARK: - The landing, shared with the cover

/// The glass runner rising out of the stacked photographs onto a soft pearl glow, then riding
/// the burst out. The welcome's landed frame and the onboarding cover's burst are this SAME view
/// (`WelcomeGalleryView.Handoff`), so the frame the cover takes over on is the frame the welcome
/// left — nothing to align, nothing to drift.
struct WelcomeLandingMark: View {
    /// 0…1: the icon rising out of the stack (the welcome's last quarter of the gather).
    var rise: Double
    /// 0…1: the burst.
    var warp: Double

    var body: some View {
        // A small settle past 1.0 and back, so the icon lands rather than fades in.
        let settle = 1 + 0.06 * sin(rise * .pi)
        let iconScale = (0.55 + 0.45 * rise) * settle * (1 + 0.45 * warp)
        let iconFade = 1 - min(1, warp * 1.25)
        // The burst is light: the landing glow swells past the screen edges and whitens
        // everything beneath the arriving question, while the icon lifts and dissolves.
        let glowScale = 1 + 5.5 * warp
        let glowFade = rise * (1 - warp * warp)
        ZStack {
            Circle()
                .fill(RadialGradient(stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white.opacity(0.95), location: 0.35),
                    .init(color: Theme.pearl[2].opacity(0.18), location: 0.7),
                    .init(color: .clear, location: 1),
                ], center: .center, startRadius: 0, endRadius: 150))
                .frame(width: 300, height: 300)
                .scaleEffect(glowScale)
                .opacity(glowFade)
            BrandMark(size: 96)
                .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
                .shadow(color: Theme.iridescent[0].opacity(0.6), radius: 26, y: 10)
                .scaleEffect(iconScale)
                .opacity(rise * iconFade)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The tail of the welcome's exit, played by the onboarding flow: the landed icon holds for the
/// rest of the welcome's hold (`Handoff.coverHoldS`), then bursts — the same smoothstep over the
/// same `warpS` the welcome once drew. Foreground-clock driven like the welcome, so both halves pace
/// alike; the icon is drawn nowhere else on the flow. Reduce Motion never sees it: that path
/// raises the flow at once, fully present, and the welcome simply fades.
///
/// The two beats that follow the burst are called FROM its frames, not from timers of their own:
/// on a busy main thread a sleeping `Task` resumes late while this timeline's clock does not,
/// and the first question then surfaced after the glow had already whitened the screen — half a
/// second of blank white, captured frame by frame 2026-09-05. Driven from the frame that renders
/// each threshold, the reveal and the burst degrade together and the crossfade holds.
struct WelcomeHandoffBurst: View {
    /// A third of the way into the burst: the first question should begin to surface.
    var onReveal: () -> Void
    /// The burst is over; nothing is drawn any more and this layer can go.
    var onSpent: () -> Void
    @ReducedMotionPreference private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var animationClock = WelcomeAnimationClock()
    @State private var revealed = false
    @State private var spent = false

    private var shouldRun: Bool { scenePhase == .active && !reduceMotion && !spent }

    var body: some View {
        ZStack {
            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !shouldRun)) { _ in
                    let t = animationClock.elapsed()
                    let linear = min(1, max(0, (t - WelcomeGalleryView.Handoff.coverHoldS)
                                                / WelcomeGalleryView.Handoff.warpS))
                    WelcomeLandingMark(rise: 1, warp: linear * linear * (3 - 2 * linear))
                        .onChange(of: t >= WelcomeGalleryView.Handoff.spentS ? 2 : (linear >= 0.35 ? 1 : 0),
                                  initial: true) { _, stage in
                            if shouldRun { advance(stage: stage) }
                        }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { updateClock() }
        .onChange(of: shouldRun) { updateClock() }
        .onChange(of: reduceMotion, initial: true) { _, reduced in
            if reduced { advance(stage: 2) }
        }
        .onDisappear { animationClock.setRunning(false) }
    }

    private func advance(stage: Int) {
        if stage >= 1, !revealed { revealed = true; onReveal() }
        if stage >= 2, !spent { spent = true; onSpent() }
    }

    private func updateClock() {
        animationClock.setRunning(shouldRun)
        guard shouldRun else { return }
        let t = animationClock.elapsed()
        advance(stage: t >= WelcomeGalleryView.Handoff.spentS ? 2
                : (t >= WelcomeGalleryView.Handoff.revealDelayS ? 1 : 0))
    }
}
