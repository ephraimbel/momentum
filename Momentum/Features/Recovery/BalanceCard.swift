import SwiftUI
import Charts

/// "Strain & recovery" — the Health segment's signature chart (docs/RECOVERY-HUB-PLAN.md §5 row 3,
/// §11.1.1). Two curves on ONE shared 0–100 axis — what you're spending (strain, peach ink) vs
/// what you have to spend (recovery, mint ink) — with a 12% wash between them that names the gap,
/// the trailing-7-day state word from `StrainRecoveryBalance`, and, when the plan supplies them,
/// outlined peach ghost bars showing how the week's remaining planned sessions will land against
/// the recovery trend. Descriptive only — the action path stays `RecoveryAdaptation`.
///
/// The supercompensation moment (§6 moment 3, P4): when recovery crosses back ABOVE strain after
/// a dip — the most recent strain-over → recovery-over crossover, landed within the last 3 days —
/// the crossover point earns a small static-iridescent dot ring with a one-time 1.2s halo glint,
/// and the "dip is the point" micro-caption lands under the state word. Transforms + opacity
/// only; under Reduce Motion the ring shows static and the halo never runs.
///
/// Color doctrine (§6): mint+peach is the sole sanctioned two-tint pairing on one chart, and it
/// ships with the mandated redundancy — a 2-swatch legend plus shape-coded end markers (mint
/// CIRCLE vs peach SQUARE — the weakest pair under CVD). Text never wears a data color; both
/// curves interpolate linearly so the wash edges sit exactly on the lines.
///
/// Inputs are engine outputs computed off-render upstream (the `Model.build()` hop happened in
/// the segment's model); the array math here is a few dozen points per render — deliberately fine
/// on the render path.
struct BalanceCard: View {
    /// Trailing 7-day spine (`StrainRecoveryBalance(… spineDays: 7 …)`).
    let week: StrainRecoveryBalance
    /// Trailing 30-day spine (`spineDays: 30`).
    let month: StrainRecoveryBalance
    /// Upcoming planned sessions as `PlannedLoad.estimate` outputs (§11.1.1) — rendered as
    /// outlined peach bars beyond today. Past-dated entries are ignored (history is real data).
    var ghostBars: [(date: Date, estLoad: Double)] = []
    /// FitnessFreshness CTL — converts ghost loads onto the strain scale through the exact
    /// `DayStrain` saturating curve so ghosts speak the chart's 0–100 currency. Defaults to the
    /// engine's cold-start floor.
    var chronicLoad: Double = 30

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var range: BalanceRange = .week
    @State private var revealed = false
    @State private var endsShown = false
    /// The supercompensation marker is visible (lands after the end dots; immediate under
    /// Reduce Motion). Card-level state so the 7d/30d swap never replays the moment.
    @State private var glintShown = false
    /// The one-time halo has expanded and faded. Pre-set (no animation) under Reduce Motion,
    /// so the halo simply never appears there.
    @State private var glintBloomed = false
    @State private var scrub: Date?

    private enum BalanceRange: String, CaseIterable {
        case week = "7D", month = "30D"
    }

    private var current: StrainRecoveryBalance { range == .week ? week : month }
    /// §6 dark mode: washes warm from 12% to 16%; inks never re-anodize.
    private var washOpacity: Double {
        colorScheme == .dark ? Theme.Health.darkWashOpacity : Theme.Health.washOpacity
    }

    var body: some View {
        let plot = Plot.build(current, ghostBars: ghostBars, chronicLoad: chronicLoad)
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            header
            if plot.plottable {
                chart(plot)
                    // Range swap is a crossfade, never a morph — the frame and the 0–100 axis are
                    // identical in both ranges, so axes never jump (§5 row 3).
                    .id(range)
                    .transition(.opacity)
                legend(plot)
            } else {
                emptyState
            }
            verdict(plot)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)))
        .onAppear(perform: reveal)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Strain & recovery")
                    .font(.rounded(Theme.FontSize.headline, weight: .bold)).foregroundStyle(Theme.ink)
                Text("What you're spending vs what you have to spend")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
            Spacer(minLength: Theme.Space.sm)
            rangePicker
        }
    }

    /// The house `SegmentedCapsule`, same as Progress's page bar and every window picker. This
    /// card used to invert the convention — a SURFACE-filled pill with ink text, where everywhere
    /// else the selected pill is ink with knocked-out text — so scrolling from Trends into Health
    /// crossed two contradictory answers to "which one is on?".
    private var rangePicker: some View {
        SegmentedCapsule(items: BalanceRange.allCases, selection: $range, scale: .compact,
                         title: { $0.rawValue },
                         spokenLabel: { "Show \($0 == .week ? "last seven days" : "last thirty days")" },
                         onChange: { _ in scrub = nil })   // a pinned day means nothing in the new window
    }

    // MARK: Chart

    private func chart(_ plot: Plot) -> some View {
        Chart {
            washMarks(plot)
            lineMarks(plot.strain, ink: Theme.Health.strainInk)
            lineMarks(plot.recovery, ink: Theme.Health.recoveryInk)
            if endsShown { endDots(plot) }
            scrubMarks(plot)
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: plot.xDomain)
        .chartYAxis {
            // Gridlines at 25/50/75 only — 1px solid hairline, never dashed (§5 global rules).
            AxisMarks(position: .leading, values: [25.0, 50.0, 75.0]) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel()
                    .font(Font.rounded(Theme.FontSize.label, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        .chartXAxis {
            if range == .week {
                // Ghost bars extend the domain up to ~14 days — 14 single-letter labels cram
                // (screenshot-verified). Past 8 days, label every other day.
                AxisMarks(values: .stride(by: .day, count: ghostBars.isEmpty ? 1 : 2)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                        .font(Font.rounded(Theme.FontSize.label, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.inkTertiary)
                }
            } else {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(Font.rounded(Theme.FontSize.label, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
        }
        .chartOverlay { proxy in chartOverlay(plot, proxy: proxy) }
        .frame(height: 190)
        // Left-to-right mask reveal, 0.6s (§5 row 3). The spec's trailing-anchored cover recede
        // and this leading-anchored mask grow are the same left-to-right read — a mask stays
        // correct on both light and dark surfaces where a cover rectangle wouldn't.
        .mask(alignment: .leading) {
            Rectangle().scaleEffect(x: revealed ? 1 : 0.0001, anchor: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Strain and recovery, \(range == .week ? "last seven days" : "last thirty days")")
        .accessibilityValue(a11ySummary(plot))
    }

    /// One solid mint/peach line per contiguous run; runs separated by more than one missing day
    /// break, bridged by a dotted hairline (§5 row 3) — a hole never reads as real data.
    @ChartContentBuilder
    private func lineMarks(_ segments: [Plot.Segment], ink: Color) -> some ChartContent {
        ForEach(segments) { seg in
            if seg.dotted {
                ForEach(seg.points, id: \.date) { p in
                    LineMark(x: .value("Day", p.date), y: .value("Score", p.value),
                             series: .value("series", seg.id))
                }
                .foregroundStyle(Theme.hairline)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            } else if seg.points.count == 1, let p = seg.points.first {
                // An isolated day between holes still shows — as a small ink dot, not a line.
                PointMark(x: .value("Day", p.date), y: .value("Score", p.value))
                    .symbolSize(22)
                    .foregroundStyle(ink)
            } else {
                ForEach(seg.points, id: \.date) { p in
                    LineMark(x: .value("Day", p.date), y: .value("Score", p.value),
                             series: .value("series", seg.id))
                }
                .foregroundStyle(ink)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }
        }
    }

    /// The between-curves wash, split at every crossing (§5 row 3): mint where recovery holds
    /// above strain (surplus), peach where strain runs over recovery. Slices insert the exact
    /// interpolated crossing point so the color never changes mid-air.
    @ChartContentBuilder
    private func washMarks(_ plot: Plot) -> some ChartContent {
        ForEach(plot.wash) { slice in
            ForEach(slice.points, id: \.date) { p in
                AreaMark(x: .value("Day", p.date),
                         yStart: .value("Low", p.lo),
                         yEnd: .value("High", p.hi),
                         series: .value("wash", "w\(slice.id)"))
            }
            .foregroundStyle((slice.surplus ? Theme.Health.recoveryWash : Theme.Health.strainWash)
                .opacity(washOpacity))
            .interpolationMethod(.linear)
        }
    }

    /// Shape-coded end markers with a 2pt surface ring, plus direct end labels in ink —
    /// identity survives CVD and grayscale without leaning on hue. The labels sit on OPPOSITE
    /// sides — strain's ABOVE its square, recovery's BELOW its circle — so the two numbers can
    /// never stack into one unreadable pile at the right edge; when the end values nearly meet,
    /// `endLabelSpacing` widens so the labels clear past each other instead of touching.
    @ChartContentBuilder
    private func endDots(_ plot: Plot) -> some ChartContent {
        let spacing = endLabelSpacing(plot)
        if let r = plot.lastRecovery {
            PointMark(x: .value("Day", r.date), y: .value("Score", r.value))
                .symbol(.circle).symbolSize(118).foregroundStyle(Theme.surface)
            PointMark(x: .value("Day", r.date), y: .value("Score", r.value))
                .symbol(.circle).symbolSize(55).foregroundStyle(Theme.Health.recoveryInk)
                // Near the floor, "bottom" would overflow and get pushed back up INTO the plot —
                // step aside to .leading instead so it can never stack on the strain label.
                .annotation(position: r.value < 12 ? .leading : .bottom, spacing: spacing,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                    endLabel(r.value)
                }
        }
        if let s = plot.lastStrain {
            PointMark(x: .value("Day", s.date), y: .value("Score", s.value))
                .symbol(.square).symbolSize(144).foregroundStyle(Theme.surface)
            PointMark(x: .value("Day", s.date), y: .value("Score", s.value))
                .symbol(.square).symbolSize(64).foregroundStyle(Theme.Health.strainInk)
                // Same ceiling case: at ~90+ the "top" label overflows, is pushed down inside the
                // chart, and lands on the recovery label (the screenshot's 98-over-75 stack).
                .annotation(position: s.value > 88 ? .leading : .top, spacing: spacing,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                    endLabel(s.value)
                }
        }
    }

    /// Anti-collision spacing for the direct end labels. With strain-above / recovery-below the
    /// labels only converge when recovery ends over strain (each label points into the gap
    /// between the dots), and they touch when that gap is small-to-middling — so within ~12
    /// points either way, or a converging gap under ~24, the spacing widens enough (at ~1.7px
    /// per point on the fixed 0–100 × 190pt frame) that the labels cross cleanly past each
    /// other rather than meeting in the middle.
    private func endLabelSpacing(_ plot: Plot) -> CGFloat {
        guard let r = plot.lastRecovery?.value, let s = plot.lastStrain?.value else { return 5 }
        let gap = r - s   // > 0 ⇒ recovery over strain ⇒ the labels converge
        return (abs(gap) < 12 || (gap > 0 && gap < 24)) ? 16 : 5
    }

    private func endLabel(_ value: Double) -> some View {
        Text("\(Int(value.rounded()))")
            .font(.display(13, weight: .bold)).monospacedDigit()
            .foregroundStyle(Theme.inkSecondary)
    }

    /// The shared-x scrub lollipop: a hairline rule, both marks re-stamped in their shapes, and
    /// one ink pill carrying the day's numbers (a missing side reads "—", never a fake zero).
    @ChartContentBuilder
    private func scrubMarks(_ plot: Plot) -> some ChartContent {
        if let scrub, let day = plot.days.first(where: { $0.date == scrub }) {
            RuleMark(x: .value("Day", day.date))
                .foregroundStyle(Theme.hairline)
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, spacing: 4) { scrubPill(day) }
            if let r = day.readiness {
                PointMark(x: .value("Day", day.date), y: .value("Score", r))
                    .symbol(.circle).symbolSize(42).foregroundStyle(Theme.Health.recoveryInk)
            }
            if let s = day.strain {
                PointMark(x: .value("Day", day.date), y: .value("Score", s))
                    .symbol(.square).symbolSize(46).foregroundStyle(Theme.Health.strainInk)
            }
        }
    }

    private func scrubPill(_ day: StrainRecoveryBalance.Day) -> some View {
        VStack(spacing: 2) {
            Text(day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.rounded(9, weight: .bold)).tracking(0.6)
                .foregroundStyle(Theme.inkTertiary)
            Text("Recovery \(day.readiness.map { "\(Int($0.rounded()))" } ?? "—")  ·  Strain \(day.strain.map { "\(Int($0.rounded()))" } ?? "—")")
                .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, Theme.Space.sm).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
            .fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.hairline)))
    }

    // MARK: Ghost bars + scrub capture (chart overlay)

    private func chartOverlay(_ plot: Plot, proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            let plotRect = proxy.plotFrame.map { geo[$0] } ?? .zero
            ZStack {
                if !plot.ghosts.isEmpty {
                    // §11.1.1 — planned sessions as OUTLINED peach bars beyond today: the chart
                    // no competitor can draw. Stroked, never filled — a forecast never
                    // impersonates measured data.
                    Canvas { ctx, _ in
                        for g in plot.ghosts {
                            guard let x = proxy.position(forX: g.date),
                                  let yTop = proxy.position(forY: g.score),
                                  let yBase = proxy.position(forY: 0.0) else { continue }
                            let rect = CGRect(x: plotRect.minX + x - 2.5,
                                              y: plotRect.minY + min(yTop, yBase),
                                              width: 5,
                                              height: max(2, abs(yBase - yTop)))
                            let path = Path(roundedRect: rect,
                                            cornerRadii: RectangleCornerRadii(topLeading: 2.5, topTrailing: 2.5))
                            // Whisper-quiet: a forecast must never compete with measured curves
                            // (the screenshot review read full-strength ghosts as data).
                            ctx.stroke(path, with: .color(Theme.Health.strainInk.opacity(0.45)), lineWidth: 1)
                        }
                    }
                    .allowsHitTesting(false)
                }
                // §6 moment 3 — supercompensation made visible: recovery just crossed back over
                // strain after a dip, so the crossover point earns the iridescent glint.
                if supercompActive,
                   let cross = plot.supercomp,
                   let x = proxy.position(forX: cross.date),
                   let y = proxy.position(forY: cross.value) {
                    SupercompGlint(shown: glintShown, bloomed: glintBloomed)
                        .position(x: plotRect.minX + x, y: plotRect.minY + y)
                        .allowsHitTesting(false)
                }
                // Press-and-hold to scrub — a plain drag would steal the page's vertical scroll.
                Rectangle().fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(scrubGesture(plot, proxy: proxy, plotRect: plotRect))
            }
        }
    }

    private func scrubGesture(_ plot: Plot, proxy: ChartProxy, plotRect: CGRect) -> some Gesture {
        // 0.25s hold before the scrub arms (was 0.15): a slow, resting-thumb page scroll could
        // trip the shorter threshold and the chart would eat the drag — the page must ALWAYS
        // out-prioritize the scrub (walk-test verified). Deliberate press-and-hold still scrubs.
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                guard let date = proxy.value(atX: drag.location.x - plotRect.minX, as: Date.self) else { return }
                // Snap to the nearest spine day that carries at least one value.
                scrub = plot.days
                    .filter { $0.readiness != nil || $0.strain != nil }
                    .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?
                    .date
            }
            .onEnded { _ in scrub = nil }
    }

    // MARK: Legend · verdict · footer

    private func legend(_ plot: Plot) -> some View {
        HStack(spacing: Theme.Space.md) {
            legendItem(label: "Recovery") {
                Circle().fill(Theme.Health.recoveryInk).frame(width: 8, height: 8)
            }
            legendItem(label: "Strain") {
                Rectangle().fill(Theme.Health.strainInk).frame(width: 8, height: 8)
            }
            if !plot.ghosts.isEmpty {
                legendItem(label: "Planned") {
                    RoundedRectangle(cornerRadius: 1.5)
                        .stroke(Theme.Health.strainInk.opacity(0.6), lineWidth: 1)
                        .frame(width: 7, height: 11)
                }
            }
            Spacer()
        }
        .accessibilityHidden(true)   // identity is carried by the chart's a11y summary
    }

    private func legendItem(label: String, @ViewBuilder swatch: () -> some View) -> some View {
        HStack(spacing: 5) {
            swatch()
            Text(label).font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
        }
    }

    /// The trailing-7-day state word + one plain-words line. The word stays monochrome — the
    /// verdict is information, not a color-coded judgment; there is no bad color in the hub.
    /// When recovery just crossed back over strain (§6's supercompensation moment), the
    /// "dip is the point" micro-caption lands underneath — the glint's meaning in words.
    private func verdict(_ plot: Plot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Text(stateWord.uppercased())
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, Theme.Space.sm).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.background).overlay(Capsule().stroke(Theme.hairline)))
                Text(stateSentence)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if plot.supercomp != nil && supercompActive {
                Text("Recovery caught back up — that dip was the training working.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Text("Big strain on big recovery is a training block working; the same strain on a low-recovery week is where overreaching quietly starts.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.sm)
            MetricInfoButton(explainer: MetricExplainers.strainRecoveryBalance)
        }
    }

    private var emptyState: some View {
        Text("A few tracked days will draw your balance here — recovery holding above strain is the pattern you want.")
            .font(.rounded(Theme.FontSize.caption, weight: .medium))
            .foregroundStyle(Theme.inkTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    // The state is always the trailing-7 read (both engine instances compute the same window);
    // the 7d/30d toggle changes the curve, never the verdict.
    /// The supercompensation story only tells when the week's verdict AGREES with it — a
    /// "that dip was the training working" caption under an OVERREACHING pill is two verdicts
    /// arguing on one card (screenshot-verified clash). Building/balanced weeks only.
    private var supercompActive: Bool {
        week.state == .building || week.state == .balanced
    }

    private var stateWord: String {
        switch week.state {
        case .building:     "Building"
        case .balanced:     "Balanced"
        case .overreaching: "Overreaching"
        case .detraining:   "Detraining"
        case .insufficient: "Learning"
        }
    }

    private var stateSentence: String {
        switch week.state {
        case .building:     "Productive stress — the block is working."
        case .balanced:     "Strain and recovery are trading evenly."
        case .overreaching: "Spending past what recovery replaces — an easier day is cheap right now."
        case .detraining:   "Plenty in the tank — there's room to add."
        case .insufficient: "A few more tracked days will name the pattern."
        }
    }

    private func a11ySummary(_ plot: Plot) -> String {
        var parts: [String] = []
        if let r = plot.lastRecovery { parts.append("recovery \(Int(r.value.rounded()))") }
        if let s = plot.lastStrain { parts.append("strain \(Int(s.value.rounded()))") }
        if plot.supercomp != nil && supercompActive { parts.append("recovery just crossed back above strain") }
        parts.append(stateSentence)
        return parts.joined(separator: ", ")
    }

    // MARK: Motion

    private func reveal() {
        if reduceMotion {
            // Reduce Motion: the chart appears complete — no sweep, no pop (§5 row 3). The
            // crossover marker shows static (the achievement shows, it just doesn't move) and
            // the halo is pre-bloomed, so it never runs.
            revealed = true
            endsShown = true
            glintShown = true
            glintBloomed = true
        } else {
            withAnimation(.easeOut(duration: 0.6)) { revealed = true }
            withAnimation(Motion.lively.delay(0.6)) { endsShown = true }   // dots + labels pop last
            // The supercompensation glint lands last: the dot ring pops in after the end dots,
            // then ONE 1.2s halo bloom — one-time, never a loop. Sequenced with a real sleep
            // (not two delayed transactions on the same tick) so the halo's shared opacity
            // animates pop-in → bloom deterministically.
            withAnimation(Motion.lively.delay(0.85)) { glintShown = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.15))
                withAnimation(.easeOut(duration: 1.2)) { glintBloomed = true }
            }
        }
    }

    // MARK: Plot assembly (pure array math over ≤ 30 points)

    private struct Plot {
        struct Point { let date: Date; let value: Double }
        struct Segment: Identifiable {
            let id: String
            let dotted: Bool
            let points: [Point]
        }
        struct WashSlice: Identifiable {
            struct P { let date: Date; let lo: Double; let hi: Double }
            let id: Int
            let surplus: Bool      // recovery ≥ strain → mint; else peach
            let points: [P]
        }

        let days: [StrainRecoveryBalance.Day]
        let recovery: [Segment]
        let strain: [Segment]
        let wash: [WashSlice]
        let lastRecovery: Point?
        let lastStrain: Point?
        /// The most recent strain-over → recovery-over crossover, when it landed within the
        /// last 3 days (§6 moment 3 — recovery arriving after strain). Nil = no fresh crossover,
        /// no glint, no caption.
        let supercomp: Point?
        let ghosts: [(date: Date, score: Double)]
        let xDomain: ClosedRange<Date>
        let plottable: Bool

        /// Points ≤ 2 days apart (at most one missing day between them) stay on one solid run;
        /// anything wider is a real gap — the "> 1 day" rule from §5 row 3.
        private static let solidGap: TimeInterval = 2.5 * 86_400

        static func build(_ balance: StrainRecoveryBalance,
                          ghostBars: [(date: Date, estLoad: Double)],
                          chronicLoad: Double) -> Plot {
            let days = balance.days
            let rPts = days.compactMap { d in d.readiness.map { Point(date: d.date, value: $0) } }
            let sPts = days.compactMap { d in d.strain.map { Point(date: d.date, value: $0) } }

            let lastSpine = days.last?.date ?? Date()
            let firstSpine = days.first?.date ?? lastSpine.addingTimeInterval(-6 * 86_400)
            let ghosts = ghostBars
                .filter { $0.date > lastSpine }
                .map { (date: $0.date, score: ghostScore($0.estLoad, chronicLoad: chronicLoad)) }
                .filter { $0.score >= 1 }
                .sorted { $0.date < $1.date }

            // Pad the domain so end dots and their labels never sit on the clipped plot edge.
            let upper = (ghosts.last?.date ?? lastSpine).addingTimeInterval(0.6 * 86_400)
            let lower = firstSpine.addingTimeInterval(-0.3 * 86_400)

            return Plot(days: days,
                        recovery: segments(rPts, key: "r"),
                        strain: segments(sPts, key: "s"),
                        wash: washSlices(days),
                        lastRecovery: rPts.last,
                        lastStrain: sPts.last,
                        supercomp: supercompCrossing(days),
                        ghosts: ghosts,
                        xDomain: lower...upper,
                        plottable: rPts.count >= 2 || sPts.count >= 2)
        }

        /// The exact `DayStrain` saturating curve (score = 100·(1 − e^(−raw/(1.6·max(CTL,30))))),
        /// applied to a planned load estimate — ghosts and history share one currency.
        static func ghostScore(_ estLoad: Double, chronicLoad: Double) -> Double {
            let reference = max(chronicLoad, 30)
            return 100 * (1 - exp(-max(0, estLoad) / (1.6 * reference)))
        }

        static func segments(_ pts: [Point], key: String) -> [Segment] {
            var runs: [[Point]] = []
            var run: [Point] = []
            for p in pts {
                if let last = run.last, p.date.timeIntervalSince(last.date) > solidGap {
                    runs.append(run)
                    run = []
                }
                run.append(p)
            }
            if !run.isEmpty { runs.append(run) }

            var segs: [Segment] = []
            for (i, r) in runs.enumerated() {
                segs.append(Segment(id: "\(key)\(i)", dotted: false, points: r))
                if i < runs.count - 1, let a = r.last, let b = runs[i + 1].first {
                    segs.append(Segment(id: "\(key)b\(i)", dotted: true, points: [a, b]))
                }
            }
            return segs
        }

        /// The supercompensation crossover (§6 moment 3 — "the dip is the point"): the most
        /// recent place recovery climbed back ABOVE strain after running under it, kept only
        /// when it landed within the last 3 days of the spine — the moment is fresh or it's
        /// nothing. Same both-sided points and interpolation math as `washSlices`, and a real
        /// gap (> 1 missing day) breaks the story — a comeback is never read across a dotted
        /// bridge.
        static func supercompCrossing(_ days: [StrainRecoveryBalance.Day]) -> Point? {
            let pts: [(date: Date, r: Double, s: Double)] = days.compactMap { d in
                guard let r = d.readiness, let s = d.strain else { return nil }
                return (d.date, r, s)
            }
            guard pts.count >= 2, let lastSpine = days.last?.date else { return nil }
            let freshCutoff = lastSpine.addingTimeInterval(-3 * 86_400)

            var latest: Point?
            for i in 1..<pts.count {
                let prev = pts[i - 1], p = pts[i]
                guard p.date.timeIntervalSince(prev.date) <= solidGap else { continue }
                guard prev.r < prev.s, p.r >= p.s else { continue }   // strain-over → recovery-over
                let d0 = prev.r - prev.s, d1 = p.r - p.s
                let t = d0 / (d0 - d1)   // d0 < 0 ≤ d1 ⇒ denominator nonzero, t ∈ (0, 1]
                let date = prev.date.addingTimeInterval(t * p.date.timeIntervalSince(prev.date))
                if date >= freshCutoff {
                    latest = Point(date: date, value: prev.r + t * (p.r - prev.r))
                }
            }
            return latest
        }

        /// Both-sided days only, broken at real gaps (no wash across a dotted bridge), split at
        /// every recovery/strain crossing with the interpolated crossing point stitched into both
        /// neighboring slices so the mint→peach handoff happens exactly where the lines cross.
        static func washSlices(_ days: [StrainRecoveryBalance.Day]) -> [WashSlice] {
            let pts: [(date: Date, r: Double, s: Double)] = days.compactMap { d in
                guard let r = d.readiness, let s = d.strain else { return nil }
                return (d.date, r, s)
            }

            var slices: [WashSlice] = []
            var points: [WashSlice.P] = []
            var surplus: Bool?
            var nextID = 0

            func close() {
                if points.count >= 2, let surplus {
                    slices.append(WashSlice(id: nextID, surplus: surplus, points: points))
                    nextID += 1
                }
                points = []
                surplus = nil
            }

            for (i, p) in pts.enumerated() {
                if i > 0, p.date.timeIntervalSince(pts[i - 1].date) > solidGap { close() }

                let sign = p.r >= p.s
                if surplus == nil { surplus = sign }
                if sign != surplus, i > 0 {
                    // Interpolate the crossing between the previous point and this one.
                    let prev = pts[i - 1]
                    let d0 = prev.r - prev.s, d1 = p.r - p.s
                    let t = d0 / (d0 - d1)   // signs differ ⇒ denominator is nonzero
                    let crossDate = prev.date.addingTimeInterval(t * p.date.timeIntervalSince(prev.date))
                    let crossValue = prev.r + t * (p.r - prev.r)
                    points.append(WashSlice.P(date: crossDate, lo: crossValue, hi: crossValue))
                    close()
                    surplus = sign
                    points.append(WashSlice.P(date: crossDate, lo: crossValue, hi: crossValue))
                }
                points.append(WashSlice.P(date: p.date, lo: min(p.r, p.s), hi: max(p.r, p.s)))
            }
            close()
            return slices
        }
    }
}

// MARK: - Supercompensation glint (§6 moment 3)

/// The earned marker at the recovery-over-strain crossover — supercompensation made visible.
/// A small dot ring wearing the static iridescent mesh (the earned accent, never a third data
/// color) over a surface core so the crossing stays legible on both curves, arriving with ONE
/// 1.2s expanding halo glint. Transforms + opacity only; nothing here loops. Under Reduce
/// Motion the card passes `shown` and `bloomed` pre-set, so the ring simply shows, static.
private struct SupercompGlint: View {
    /// The resident ring is visible (the card schedules this after the end dots pop).
    let shown: Bool
    /// The one-time halo has expanded and faded — animated exactly once by the card's reveal.
    let bloomed: Bool

    var body: some View {
        ZStack {
            // The one-time halo: a wider iridescent ring that expands and fades once.
            iridescentRing(diameter: 15, lineWidth: 2)
                .scaleEffect(bloomed ? 2.2 : 0.7)
                .opacity(bloomed ? 0 : (shown ? 0.9 : 0))
            // The resident marker: surface core + static iridescent dot ring — the crossover
            // stays findable after the glint has played.
            Circle()
                .fill(Theme.surface)
                .frame(width: 9, height: 9)
                .scaleEffect(shown ? 1 : 0.4)
                .opacity(shown ? 1 : 0)
            iridescentRing(diameter: 15, lineWidth: 2.5)
                .scaleEffect(shown ? 1 : 0.4)
                .opacity(shown ? 1 : 0)
        }
        // Decorative — the meaning is carried by the verdict's micro-caption and the chart's
        // accessibility summary.
        .accessibilityHidden(true)
    }

    private func iridescentRing(diameter: CGFloat, lineWidth: CGFloat) -> some View {
        IridescentView(intensity: 1.0, isStatic: true)
            .frame(width: diameter, height: diameter)
            .mask { Circle().strokeBorder(lineWidth: lineWidth) }
    }
}

// Previews compile into Release unless gated — and these are built from invented vitals,
// nights and strain series. No fabricated health data belongs in a shipped binary
// (production-readiness sweep 2026-07-16; the rest of this family was already gated).
#if DEBUG
// MARK: - Preview

#Preview("Balance — light") {
    BalanceCardPreview()
}

#Preview("Balance — dark") {
    BalanceCardPreview().preferredColorScheme(.dark)
}

private struct BalanceCardPreview: View {
    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        func day(_ ago: Int) -> Date { cal.date(byAdding: .day, value: -ago, to: today)! }

        // A month with a hard mid-block, a data hole, and a crossing — exercises wash split,
        // dotted bridge, and both end markers.
        let pairs: [(day: Date, strain: Double?, readiness: Double?)] = (0..<30).map { ago in
            let t = Double(29 - ago)
            let strain: Double? = (ago == 11 || ago == 12 || ago == 13) ? nil : min(95, max(4, 46 + 30 * sin(t * 0.55) + Double((ago * 7) % 11) - 5))
            let readiness: Double? = ago == 21 ? nil : min(96, max(20, 64 + 16 * sin(t * 0.32 + 1.9)))
            return (day(ago), strain, readiness)
        }
        let week = StrainRecoveryBalance(dailyPairs: pairs, spineDays: 7, ctlDelta7: 1.4)
        let month = StrainRecoveryBalance(dailyPairs: pairs, spineDays: 30, ctlDelta7: 1.4)
        let ghosts: [(date: Date, estLoad: Double)] = [
            (cal.date(byAdding: .day, value: 1, to: today)!, 55),
            (cal.date(byAdding: .day, value: 3, to: today)!, 120),
        ]

        return ScrollView {
            BalanceCard(week: week, month: month, ghostBars: ghosts, chronicLoad: 42)
                .padding(Theme.Space.md)
        }
        .background(Theme.background)
    }
}
#endif
