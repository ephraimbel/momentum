import SwiftUI

/// The Health segment's hero — one honest 0–100 readiness ring (RECOVERY-HUB-PLAN §5 row 1).
///
/// A 180pt ring fills in mint ink over a 22% mint-wash track (warmed to ~28% in dark — §6), with hairline ticks at the band
/// cuts (25/45/65/80 — `RecoveryModel.band`, the one banding function app-wide). The numeral
/// counts up in lockstep with the trim sweep; the band word and guidance crossfade in after.
/// Iridescence is *earned*: the fill renders as the `MeshGradient` mesh only at `.primed` (≥ 80).
/// A check-in-only score draws its fill **dashed** — self-reported never impersonates measured —
/// and `nil` readiness renders the "learning you" state (dashed mint ring + the check-in path),
/// never a fake number. The engine's confidence tier lives in the partial-data footnote
/// (§11.2.7 — that footnote is confidence's home).
///
/// Inputs are pre-computed engine outputs — nothing heavy happens here, so no `Model.build()`
/// hop is needed (the caller builds `MorningReadiness` + the 7-day strip off the render path).
///
/// **P4 choreography (§9-P4 moment 1):** light haptic ticks land as the count-up crosses each
/// band cut on its way to the score; the band word crossfades in with one quiet pulse; and at
/// `.primed` the iridescent fill lands with ONE 1.2s sweep glint before settling into
/// IridescentView's slow 8s ambient loop. All of it is cancelled if the card disappears
/// mid-flight. Reduce Motion: ring and numeral appear complete behind a plain crossfade, no
/// pulse, no sweep; iridescence holds static (IridescentView handles that itself) — but the
/// haptic still fires once, immediately (haptics are not motion, §6).
struct ReadinessHeroCard: View {
    /// Today's morning score, or `nil` while we're still learning the athlete.
    let readiness: MorningReadiness?
    /// Trailing 7 days of scores, oldest → today; `nil` holes render hollow. Pro-only history.
    var weekScores: [Int?] = []
    /// History (the 7-day strip) is the depth layer (§8); the hero itself is always free.
    var isPro: Bool = false
    /// Opens the morning check-in (`CheckinSheet` at the call site) from the learning-you state.
    var onCheckin: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var trackShown = false
    @State private var sweep = 0.0          // 0...1 — drives trim + counter in lockstep
    @State private var detailsShown = false
    @State private var bandPulse = 1.0
    @State private var revealed = false     // the choreography runs once per life, not per scroll-back
    @State private var revealTask: Task<Void, Never>?
    @State private var glintPhase = 0.0     // 0→1 carries the one-time primed sweep around the ring
    @State private var glintShown = false

    private static let ringSize: CGFloat = 180
    private static let ringWidth: CGFloat = 14
    /// Stroke-centerline diameter — inset by half the stroke so the 14pt band stays inside
    /// the 180pt frame, with the band ticks crossing its center.
    private static let ringDiameter: CGFloat = ringSize - ringWidth

    /// §6 dark mode: same ink, warmer wash — the 22% ring track warms in the fill ratio
    /// (12% → 16%), so ~28% on the charcoal surface; inks never re-anodize.
    private var trackOpacity: Double { colorScheme == .dark ? 0.28 : 0.22 }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                header
                if let readiness {
                    scored(readiness)
                } else {
                    learningYou
                }
                Divider().overlay(Theme.hairline)
                educationFooter
            }
        }
        .onAppear(perform: reveal)
        .onDisappear {
            revealTask?.cancel()
            revealTask = nil
            // Settle anything mid-flight so a lazy-container reappear shows the finished card.
            glintShown = false
            bandPulse = 1.0
        }
    }

    // MARK: Header

    private var header: some View {
        // The readiness ⓘ lives in the education footer below — one affordance, one sheet.
        Text("READINESS")
            .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
            .foregroundStyle(Theme.inkTertiary)
    }

    // MARK: Scored state

    @ViewBuilder
    private func scored(_ readiness: MorningReadiness) -> some View {
        let target = Double(readiness.score) / 100
        let checkinOnly = readiness.pillars.count == 1 && readiness.pillars.first?.kind == .checkin

        VStack(spacing: Theme.Space.md) {
            ZStack {
                ring(progress: sweep * target,
                     primed: readiness.band == .primed,
                     dashedFill: checkinOnly)
                VStack(spacing: Theme.Space.xxs) {
                    AnimatedCounter(value: sweep * Double(readiness.score)) { "\(Int($0.rounded()))" }
                        .font(.display(52, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text(readiness.band.rawValue)
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).tracking(0.6)
                        .foregroundStyle(Theme.inkSecondary)
                        .opacity(detailsShown ? 1 : 0)
                        .scaleEffect(bandPulse)
                }
            }
            .frame(width: Self.ringSize, height: Self.ringSize)
            .frame(maxWidth: .infinity)

            Text(readiness.guidance)
                .font(.rounded(Theme.FontSize.body, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .opacity(detailsShown ? 1 : 0)

            if isPro, weekScores.compactMap({ $0 }).count > 1 {
                dotStrip.opacity(detailsShown ? 1 : 0)
            }

            if let footnote = footnote(readiness, checkinOnly: checkinOnly) {
                Text(footnote)
                    .font(.rounded(Theme.FontSize.label, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .opacity(detailsShown ? 1 : 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Readiness")
        .accessibilityValue("\(readiness.score) out of 100, \(readiness.band.rawValue). \(readiness.guidance)")
    }

    /// The partial-data footnote — lists the inputs used and names the most notable absence;
    /// the confidence tier renders here in plain words (§11.2.7). Full-signal mornings need none.
    private func footnote(_ readiness: MorningReadiness, checkinOnly: Bool) -> String? {
        if checkinOnly { return "From your check-in" }
        guard readiness.pillars.count < MorningReadiness.PillarKind.allCases.count else { return nil }
        let names = readiness.pillars.map { $0.kind.plainName }
        var line = "From " + names.joined(separator: " + ")
        let present = Set(readiness.pillars.map(\.kind))
        // One calm clause for the most notable missing input — never a warning triangle.
        if !present.contains(.sleep) { line += " — no sleep data last night" }
        else if !present.contains(.hrv) { line += " — no HRV last night" }
        else if !present.contains(.restingHR) { line += " — no resting heart rate last night" }
        else if !present.contains(.load) { line += " — training history still building" }
        else if !present.contains(.checkin) { line += " — no check-in yet today" }
        switch readiness.confidence {
        case .high, .medium: break
        case .low:           line += " · partial signal"
        case .minimal:       line += " · light signal — more mornings sharpen this"
        }
        return line
    }

    // MARK: The ring

    /// Mint-ink fill on a mint-wash track (`trackOpacity`), hairline ticks at the band cuts. At `.primed` the
    /// fill is the earned iridescent mesh (its 8s ambient loop and Reduce Motion freeze are
    /// IridescentView's own); everywhere below, mint ink — today's always-iridescent readiness
    /// ring is retired by §6's earned-only rule.
    @ViewBuilder
    private func ring(progress: Double, primed: Bool, dashedFill: Bool) -> some View {
        let style = StrokeStyle(lineWidth: Self.ringWidth,
                                lineCap: dashedFill ? .butt : .round,
                                dash: dashedFill ? [4, 7] : [])
        ZStack {
            Circle()
                .stroke(Theme.Health.recoveryWash.opacity(trackOpacity), lineWidth: Self.ringWidth)
                .frame(width: Self.ringDiameter, height: Self.ringDiameter)
                .opacity(trackShown ? 1 : 0)

            if primed {
                IridescentView(intensity: 0.95)
                    .mask { fillArc(progress, style: style) }
                sweepGlint
                    .mask { fillArc(progress, style: style) }
            } else {
                fillArc(progress, style: style)
                    .foregroundStyle(Theme.Health.recoveryInk)
            }

            ticks.opacity(trackShown ? 1 : 0)
        }
    }

    private func fillArc(_ progress: Double, style: StrokeStyle) -> some View {
        Circle()
            .trim(from: 0, to: max(0.0001, min(1, progress)))
            .stroke(style: style)
            .frame(width: Self.ringDiameter, height: Self.ringDiameter)
            .rotationEffect(.degrees(-90))
    }

    /// The earned one-time sweep (§5 row 1, §9-P4): a narrow bright wedge carried once around
    /// the primed ring by a rotation transform — transforms only, then it's gone and the 8s
    /// ambient loop carries on alone. Idle at `glintPhase == 0` / `glintShown == false`; the
    /// reveal timeline drives one 1.2s revolution. Never scheduled under Reduce Motion.
    private var sweepGlint: some View {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 0.44),
                .init(color: .white.opacity(0.65), location: 0.5),
                .init(color: .clear, location: 0.56),
                .init(color: .clear, location: 1),
            ]),
            center: .center
        )
        // Wedge sits at 180° in gradient space; +90° parks it at 12 o'clock — the fill's origin.
        .rotationEffect(.degrees(90 + glintPhase * 360))
        .opacity(glintShown ? 1 : 0)
        .allowsHitTesting(false)
    }

    /// Hairline ticks at the band boundaries 25/45/65/80 — the ring wears the banding math.
    private var ticks: some View {
        ForEach([0.25, 0.45, 0.65, 0.80], id: \.self) { cut in
            Capsule()
                .fill(Theme.hairline)
                .frame(width: 1.5, height: Self.ringWidth + 5)
                .offset(y: -Self.ringDiameter / 2)   // the band's centerline radius
                .rotationEffect(.degrees(cut * 360))
        }
    }

    // MARK: 7-day micro-strip

    private var dotStrip: some View {
        let days = normalizedWeek
        return HStack(spacing: Theme.Space.sm) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, score in
                ZStack {
                    if let score {
                        Circle()
                            .fill(Theme.Health.recoveryInk.opacity(0.25 + 0.75 * Double(score) / 100))
                            .frame(width: 8, height: 8)
                    } else {
                        Circle()
                            .stroke(Theme.hairline, lineWidth: 1)
                            .frame(width: 8, height: 8)
                    }
                }
                .overlay {
                    if i == days.count - 1 {  // today wears an ink ring
                        Circle().stroke(Theme.ink, lineWidth: 1).frame(width: 12, height: 12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last 7 days of readiness")
        .accessibilityValue(days.map { $0.map(String.init) ?? "no data" }.joined(separator: ", "))
    }

    private var normalizedWeek: [Int?] {
        let tail = Array(weekScores.suffix(7))
        return Array(repeating: Int?.none, count: max(0, 7 - tail.count)) + tail
    }

    // MARK: Learning-you state (nil model)

    /// No score yet — never a fake number. Same ring, dashed mint, and the check-in path: the
    /// athlete's own words build the score while baselines grow (§5 empty states).
    private var learningYou: some View {
        VStack(spacing: Theme.Space.md) {
            ZStack {
                Circle()
                    .stroke(Theme.Health.recoveryInk.opacity(0.45),
                            style: StrokeStyle(lineWidth: Self.ringWidth, dash: [4, 7]))
                    .frame(width: Self.ringDiameter, height: Self.ringDiameter)
                VStack(spacing: Theme.Space.xs) {
                    Image(systemName: "sunrise")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                    Text("Learning you")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .frame(width: Self.ringSize, height: Self.ringSize)
            .frame(maxWidth: .infinity)

            Text("Check in each morning — how you feel builds today's score while your baselines grow night by night.")
                .font(.rounded(Theme.FontSize.body, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            if let onCheckin {
                Button {
                    Haptics.light()
                    onCheckin()
                } label: {
                    Text("Morning check-in")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, Theme.Space.lg)
                        .padding(.vertical, Theme.Space.pillV)
                        .background(Capsule().fill(Theme.ink))
                }
                .buttonStyle(.plain)
            }

            // §5 cold-start copy — "From your check-in" belongs to the check-in-scored state
            // (the footnote above); here there's no score yet, so say what's actually happening.
            Text("Never a fake number — your first score lands once there's real signal")
                .font(.rounded(Theme.FontSize.label, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Education footer

    private var educationFooter: some View {
        HStack(spacing: Theme.Space.xs) {
            Text("How readiness is scored")
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
            MetricInfoButton(explainer: MetricExplainers.readiness)
        }
    }

    // MARK: Reveal choreography

    /// The reveal: track fades (0.15s) → trim sweep + count-up in lockstep (`Motion.travel`,
    /// ~0.9s) with a light haptic tick at each band cut the numeral crosses → band word +
    /// guidance crossfade with one quiet 1.0→1.03→1.0 pulse → at `.primed`, ONE 1.2s sweep
    /// glint, then IridescentView's slow 8s ambient loop alone. The timeline lives in one
    /// cancellable task (`onDisappear` tears it down) and runs once per card life.
    /// Reduce Motion: everything renders final behind a plain appearance — no sweep, no pulse,
    /// static mesh — but one tick still lands immediately (haptics are not motion, §6).
    private func reveal() {
        guard !revealed else { return }
        revealed = true
        guard !reduceMotion else {
            trackShown = true; sweep = 1; detailsShown = true
            // One tick, immediately (haptics are not motion) — but only when a score actually
            // revealed, and never sub-25: the learning-you state and Depleted mornings stay as
            // silent here as on the animated path (no shame buzz, §6).
            if let score = readiness?.score, score >= 25 { Haptics.light() }
            return
        }
        withAnimation(.easeOut(duration: 0.15)) { trackShown = true }
        withAnimation(Motion.travel.delay(0.15)) { sweep = 1 }
        withAnimation(.easeOut(duration: Motion.slow).delay(0.85)) { detailsShown = true }
        revealTask = Task { @MainActor in
            await runChoreography()
        }
    }

    /// `Motion.travel`'s spring step-response, inverted: fraction-complete → seconds-from-start,
    /// so each band tick lands as the numeral actually crosses its cut. The naive linear
    /// cut/score mapping read ~180–560 ms late against the spring (response 0.5, damping 0.86 is
    /// ~61% done at 0.15s and ~95% by 0.30s) — a trailing drumroll on a settled number.
    private static func springTime(toProgress p: Double) -> Double {
        let knots: [(t: Double, p: Double)] = [(0, 0), (0.05, 0.18), (0.10, 0.42), (0.15, 0.61),
                                               (0.20, 0.75), (0.25, 0.87), (0.30, 0.95),
                                               (0.40, 0.99), (0.50, 1.0)]
        guard p > 0 else { return 0 }
        for (a, b) in zip(knots, knots.dropFirst()) where p <= b.p {
            return a.t + (p - a.p) / max(b.p - a.p, 0.0001) * (b.t - a.t)
        }
        return knots[knots.count - 1].t
    }

    /// Everything on the reveal clock (t = 0 at `onAppear`; the counter travels 0.15 → ~1.05s).
    /// Nothing runs for the learning-you state — no score, nothing to choreograph.
    @MainActor
    private func runChoreography() async {
        guard let readiness else { return }
        var events: [(at: Double, run: @MainActor () -> Void)] = []

        // Band-crossing ticks — on the spring's own clock (inverted step-response above), so the
        // tick lands as the displayed value crosses each cut. Sub-25 scores cross nothing and
        // stay silent — no shame buzz.
        let score = readiness.score
        if score > 0 {
            for cut in [25, 45, 65, 80] where cut <= score {
                events.append((at: 0.15 + Self.springTime(toProgress: Double(cut) / Double(score)),
                               run: { Haptics.light() }))
            }
        }

        // The band word lands: one quiet pulse (crossfade is already in flight via detailsShown).
        events.append((at: 0.90, run: { withAnimation(Motion.lively) { bandPulse = 1.03 } }))
        events.append((at: 1.08, run: { withAnimation(Motion.lively) { bandPulse = 1.0 } }))

        // Primed only: the iridescent fill lands with ONE 1.2s sweep, then the ambient loop.
        if readiness.band == .primed {
            events.append((at: 1.05, run: {
                glintShown = true
                withAnimation(.easeInOut(duration: 1.2)) { glintPhase = 1 }
            }))
            events.append((at: 2.25, run: {
                withAnimation(.easeOut(duration: 0.2)) { glintShown = false }
            }))
        }

        var elapsed = 0.0
        for event in events.sorted(by: { $0.at < $1.at }) {
            let wait = event.at - elapsed
            if wait > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                catch { return }   // card disappeared — choreography cancelled
            }
            elapsed = event.at
            event.run()
        }
    }
}

// MARK: - Plain-words pillar names (footnote vocabulary)

extension MorningReadiness.PillarKind {
    /// The human name each pillar wears in hub copy — shared vocabulary with `DriverRow`.
    var plainName: String {
        switch self {
        case .load:      "training load"
        case .hrv:       "HRV"
        case .sleep:     "sleep"
        case .restingHR: "resting HR"
        case .checkin:   "your check-in"
        }
    }
}

// MARK: - Previews

#Preview("Scored") {
    ScrollView {
        ReadinessHeroCard(readiness: MorningReadiness(signals: .demo),
                          weekScores: [58, 64, nil, 71, 77, 62, 74],
                          isPro: true)
            .padding()
    }
    .background(Theme.background)
}

#Preview("Primed") {
    // Banded baselines push .demo's strong morning over the 80 cut — exercises the earned
    // iridescent fill, the full four-tick ladder, and the one-time 1.2s sweep.
    ScrollView {
        ReadinessHeroCard(
            readiness: MorningReadiness(
                signals: .demo,
                hrvBaseline: .init(mean: 55, sd: 5, dayCount: 30, windowDays: 30),
                restingHRBaseline: .init(mean: 52, sd: 2, dayCount: 30, windowDays: 30),
                sleepNeedH: 7.0),
            weekScores: [66, 71, 74, nil, 78, 79, 86],
            isPro: true)
            .padding()
    }
    .background(Theme.background)
}

#Preview("Strained") {
    ScrollView {
        ReadinessHeroCard(readiness: MorningReadiness(signals: .demoStrained),
                          weekScores: [70, 66, 61, nil, 52, 44, 39],
                          isPro: true)
            .padding()
    }
    .background(Theme.background)
}

#Preview("Learning you") {
    ScrollView {
        ReadinessHeroCard(readiness: nil, onCheckin: {})
            .padding()
    }
    .background(Theme.background)
}
