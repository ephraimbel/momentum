import SwiftUI
import SwiftData

/// The unlock moment — a full-canvas celebration played once per newly-earned award (the same
/// family as `CompletionCelebration`: phased `withAnimation` beats, celebration haptic, Reduce
/// Motion snaps everything). The medallion springs in, an iridescent ring draws around it, one
/// holographic sheen sweeps the coin, then the words land. Multiple awards page on tap.
struct AwardUnlockView: View {
    let awards: [Award]
    var onDone: () -> Void

    @State private var index = 0
    @State private var coinIn = 0.0      // scale + opacity
    @State private var ring = 0.0        // trim sweep around the coin
    @State private var bloom = 0.0       // soft iridescent glow behind
    @State private var sheen = -1.2      // holographic band, in coin-widths
    @State private var textIn = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var award: Award { awards[min(index, awards.count - 1)] }
    private let coinSize: CGFloat = 156

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Text("AWARD EARNED")
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(2.4)
                    .foregroundStyle(Theme.inkTertiary)
                    .opacity(textIn)

                ZStack {
                    // Soft earned glow — the room's light catching the new metal.
                    Circle()
                        .fill(IridescentMaterial())
                        .frame(width: coinSize * 1.5, height: coinSize * 1.5)
                        .opacity(0.28 * bloom)
                        .blur(radius: 28)

                    // The ring draws once around the coin — the same earned sweep the save beat uses.
                    Circle()
                        .trim(from: 0, to: ring)
                        .stroke(AngularGradient(colors: Theme.iridescent + [Theme.iridescent[0]],
                                                center: .center),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: coinSize + 34, height: coinSize + 34)

                    AwardMedallion(award: award, size: coinSize)
                        .overlay(sheenBand)
                        .scaleEffect(0.55 + 0.45 * coinIn)
                        .opacity(coinIn)
                }
                .padding(.vertical, Theme.Space.xl)

                VStack(spacing: Theme.Space.sm) {
                    Text(award.name)
                        .font(.display(30, weight: .black))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(award.requirement)
                        .font(.rounded(Theme.FontSize.body, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Theme.Space.xl)
                .opacity(textIn)
                .offset(y: reduceMotion ? 0 : (1 - textIn) * 10)

                Spacer()

                VStack(spacing: Theme.Space.md) {
                    if awards.count > 1 {
                        HStack(spacing: 6) {
                            ForEach(awards.indices, id: \.self) { i in
                                Circle()
                                    .fill(i == index ? Theme.purple : Theme.hairline)
                                    .frame(width: 6, height: 6)
                            }
                        }
                    }
                    Text(index < awards.count - 1 ? "Tap for the next one" : "Tap to continue")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .opacity(textIn)
                }
                .padding(.bottom, Theme.Space.xxl)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { advance() }
        .task(id: index) { await run() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Award earned. \(award.name). \(award.requirement)")
        .accessibilityHint(index < awards.count - 1 ? "Tap for the next award" : "Tap to continue")
        .accessibilityAddTraits([.isButton, .isModal])
    }

    /// One holographic band crossing the coin — the PR chip's celebrate sweep, sized for a medal.
    private var sheenBand: some View {
        Rectangle()
            .fill(LinearGradient(colors: [.clear] + Theme.iridescent.map { $0.opacity(0.5) } + [.clear],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: coinSize * 0.55, height: coinSize * 1.7)
            .rotationEffect(.degrees(24))
            .offset(x: sheen * coinSize)
            .clipShape(Circle())
            .allowsHitTesting(false)
    }

    private func advance() {
        if index < awards.count - 1 {
            coinIn = 0; ring = 0; sheen = -1.2; textIn = 0
            index += 1   // .task(id:) re-runs the choreography for the next coin
        } else {
            onDone()
        }
    }

    private func run() async {
        if index == 0 { Haptics.celebration() } else { Haptics.milestone() }
        if reduceMotion {
            coinIn = 1; ring = 1; bloom = 1; textIn = 1; sheen = 1.2
            return
        }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.68)) { coinIn = 1 }
        withAnimation(.easeOut(duration: 0.7)) { ring = 1; bloom = 1 }
        try? await Task.sleep(for: .seconds(0.35))
        withAnimation(.easeInOut(duration: 0.65)) { sheen = 1.2 }
        try? await Task.sleep(for: .seconds(0.15))
        withAnimation(.easeOut(duration: 0.4)) { textIn = 1 }
    }
}

// MARK: - Presenter

/// Watches for earned-but-unseen awards and plays the unlock moment over the host view, then marks
/// them seen. Attach once near the app root — awards land from any path (save flows, Health
/// import, a plan week completing) and the celebration meets the athlete wherever they are.
private struct AwardUnlockPresenter: ViewModifier {
    /// True while a root-level cover (paywall, coach, onboarding, recovery) owns the screen —
    /// the celebration is an overlay UNDER those covers, so presenting now would play the whole
    /// moment invisibly behind them. Deferred until the cover clears.
    var paused: Bool = false
    @Query(filter: #Predicate<EarnedAward> { $0.seen == false }) private var unseen: [EarnedAward]
    @Environment(\.modelContext) private var context
    @State private var queue: [Award] = []
    @State private var presented = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if presented {
                    AwardUnlockView(awards: queue) { dismiss() }
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .onChange(of: unseen.count) { maybePresent() }
            .onChange(of: paused) { maybePresent() }
            .task {
                #if DEBUG
                // --award-unlock: play the unlock moment on demand for sim verification.
                if debugFlag("--award-unlock") {
                    queue = [AwardsCatalog.award("distance.100"),
                             AwardsCatalog.award("speed.5k.sub25"),
                             AwardsCatalog.award("distance.5000")].compactMap { $0 }
                    presented = true
                    return
                }
                #endif
                maybePresent()
            }
    }

    private func maybePresent() {
        guard !presented, !paused, !unseen.isEmpty else { return }
        // Present in the order they were earned; ties break by catalog order so a single run's
        // haul (say, The 5K + First Fifty) reads smallest-to-summit.
        let awards = unseen
            .sorted { ($0.earnedAt, catalogIndex($0.awardID)) < ($1.earnedAt, catalogIndex($1.awardID)) }
            .compactMap { AwardsCatalog.award($0.awardID) }
        guard !awards.isEmpty else {
            // Rows whose id the catalog no longer knows can never present — retire them quietly.
            for a in unseen { a.seen = true }
            try? context.save()
            return
        }
        queue = awards
        Task { @MainActor in
            // A breath after the triggering screen settles (save hand-off, tab landing).
            try? await Task.sleep(for: .seconds(0.7))
            guard !presented, !paused, !unseen.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.3)) { presented = true }
        }
    }

    private func catalogIndex(_ id: String) -> Int {
        AwardsCatalog.all.firstIndex { $0.id == id } ?? .max
    }

    private func dismiss() {
        // Only the awards that actually played get retired — one earned DURING the celebration
        // (a background import) stays unseen and gets its own moment right after.
        let shown = Set(queue.map(\.id))
        for a in unseen where shown.contains(a.awardID) { a.seen = true }
        try? context.save()
        withAnimation(.easeIn(duration: 0.25)) { presented = false }
    }
}

extension View {
    /// Present unlock celebrations for newly-earned awards over this view. Attach once, app-root.
    /// Pass `paused: true` while a root cover owns the screen — presentation defers until clear.
    func awardUnlocks(paused: Bool = false) -> some View {
        modifier(AwardUnlockPresenter(paused: paused))
    }
}
