import SwiftUI

// The Trends strength chapter's two lead cards (2026-08-28): the muscle-load WHEEL and the
// strength-progression ROWS — Bevel's structure, our theme. Monochrome ink, iridescence only
// on the region carrying the most load and on each lift's newest point (earned progress).

// MARK: - Muscle load wheel

/// "Total volume" ↔ "Muscular load": six body regions around a wheel, each a wedge of four
/// concentric ring segments that fill outward with the region's share of the biggest one.
/// The chevron flips the metric; the labels around the wheel carry the numbers.
struct MuscleLoadCard: View {
    let loads: [StrengthTrends.RegionLoad]
    var weightUnit: WeightUnit = .kg
    var days: Int = 30
    var animate: Bool = true
    /// Tap-through to the Muscle load detail (the wheel, the body, every region).
    var onOpen: (() -> Void)? = nil
    @State private var metric: Metric = .volume
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Metric: CaseIterable {
        case volume, share
        var title: String { self == .volume ? "Total volume" : "Muscular load" }
        var icon: String { self == .volume ? "scalemass.fill" : "figure.strengthtraining.traditional" }
        var next: Metric { self == .volume ? .share : .volume }
    }

    private var totalVolume: Double { loads.reduce(0) { $0 + $1.volumeKg } }
    private var totalSets: Double { loads.reduce(0) { $0 + $1.sets } }

    /// The wheel's value per region for the current metric (kg for volume, share 0…1 for load).
    private func value(_ l: StrengthTrends.RegionLoad) -> Double {
        metric == .volume ? l.volumeKg : (totalSets > 0 ? l.sets / totalSets : 0)
    }
    private func label(_ l: StrengthTrends.RegionLoad) -> String {
        switch metric {
        case .volume:
            let v = weightUnit == .lb ? l.volumeKg * Formatters.lbPerKg : l.volumeKg
            return v <= 0 ? "0" : "\(Formatters.compact(v)) \(weightUnit == .lb ? "lb" : "kg")"
        case .share:
            return "\(Int((value(l) * 100).rounded()))%"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: metric.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                Text(metric.title).font(.rounded(Theme.FontSize.headline, weight: .bold)).foregroundStyle(Theme.ink)
                    .contentTransition(.opacity)
                Spacer(minLength: Theme.Space.sm)
                MetricInfoButton(explainer: MetricExplainers.muscleBalance)
                Button {
                    Haptics.selection()
                    withAnimation(.smooth(duration: 0.35)) { metric = metric.next }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Switch to \(metric.next.title)")
            }
            Text("Last \(days) days · working sets")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            RadialMuscleWheel(loads: loads, value: value, label: label, animate: animate && !reduceMotion)
                .frame(height: 310)
                .padding(.top, Theme.Space.xs)
                .id(metric)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .onTapGesture { if let onOpen { Haptics.light(); onOpen() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(metric.title), last \(days) days")
        .accessibilityHint(onOpen == nil ? "" : "Opens the muscle load detail")
    }
}

/// The wheel itself. Six 60° wedges (gapped), four rings each; a region fills rings in
/// proportion to its share of the strongest region, each ring darker than the one inside it.
/// The strongest region wears the earned iridescence. Labels sit at each wedge's bisector.
struct RadialMuscleWheel: View {
    let loads: [StrengthTrends.RegionLoad]
    let value: (StrengthTrends.RegionLoad) -> Double
    let label: (StrengthTrends.RegionLoad) -> String
    var animate: Bool = true
    /// Wheel radius as a share of the shorter side (the detail page runs it larger).
    var scale: CGFloat = 0.31
    @State private var grown = false

    private static let rings = 4
    private static let gapDegrees = 6.0
    private static let ringGap: CGFloat = 3.5

    private var maxValue: Double { loads.map(value).max() ?? 0 }
    private var topRegion: StrengthTrends.BodyRegion? {
        guard maxValue > 0 else { return nil }
        return loads.max { value($0) < value($1) }?.region
    }

    /// Wheel order clockwise from the top: chest, back, legs, shoulders, core, arms.
    private func angle(for region: StrengthTrends.BodyRegion) -> Double {
        let i = StrengthTrends.BodyRegion.allCases.firstIndex(of: region) ?? 0
        return -90 + Double(i) * 60
    }

    /// Rings lit for a region: at least one when it trained at all, all four for the leader.
    private func litRings(_ l: StrengthTrends.RegionLoad) -> Int {
        let v = value(l)
        guard v > 0, maxValue > 0 else { return 0 }
        return max(1, Int((v / maxValue * Double(Self.rings)).rounded(.up)))
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let outer = side * scale
            let inner = outer * 0.28
            let ringW = (outer - inner - Self.ringGap * CGFloat(Self.rings - 1)) / CGFloat(Self.rings)
            ZStack {
                ForEach(loads) { l in
                    let base = angle(for: l.region)
                    let lit = litRings(l)
                    let leader = l.region == topRegion
                    let share = maxValue > 0 ? value(l) / maxValue : 0
                    ForEach(0..<Self.rings, id: \.self) { ring in
                        // Centre-line radius of this ring; the stroke's round caps make the
                        // segment a soft pill, and the cap eats into the angular gap, so the
                        // sweep is trimmed by the cap's own angle to keep every gap even.
                        let r = inner + CGFloat(ring) * (ringW + Self.ringGap) + ringW / 2
                        let capDeg = Double(ringW / 2 / r) * 180 / .pi
                        let on = ring < lit
                        RingArc(startAngle: .degrees(base - 30 + Self.gapDegrees / 2 + capDeg),
                                endAngle: .degrees(base + 30 - Self.gapDegrees / 2 - capDeg),
                                radius: r)
                            .trim(from: 0, to: grown ? 1 : 0.001)
                            .stroke(fill(on: on, ring: ring, leader: leader, share: share),
                                    style: StrokeStyle(lineWidth: ringW, lineCap: .round))
                            .animation(.spring(response: 0.7, dampingFraction: 0.86)
                                        .delay(0.05 * Double(ring) + 0.03 * Double(StrengthTrends.BodyRegion.allCases.firstIndex(of: l.region) ?? 0)),
                                       value: grown)
                            .animation(.smooth(duration: 0.45), value: on)
                    }
                    labelView(l, at: labelPoint(center: center, angle: base, radius: outer + side * 0.135))
                        .opacity(grown ? 1 : 0)
                        .offset(y: grown ? 0 : 6)
                        .animation(.easeOut(duration: 0.5).delay(0.25), value: grown)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { grown = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loads.map { "\($0.region.displayName) \(label($0))" }.joined(separator: ", "))
    }

    /// The wheel reads like the muscle map (owner call 2026-08-28): every region is lavender,
    /// and the colour gets STRONGER with volume rather than switching from grey to lit. A lit
    /// ring's strength is the region's share of the biggest region, ramped outward ring by ring;
    /// unlit rings keep a faint lavender track so the whole wheel is one graph, not six grey
    /// stubs. The leader alone wears the iridescent burn, the earned top of the scale. Before
    /// this, lit rings were ink grey and a region at 35% of the max looked untrained.
    private func fill(on: Bool, ring: Int, leader: Bool, share: Double) -> AnyShapeStyle {
        guard on else { return AnyShapeStyle(Theme.purple.opacity(0.07)) }
        if leader {
            let alpha = [0.5, 0.66, 0.83, 1.0][ring]
            return AnyShapeStyle(AngularGradient(colors: Theme.iridescent + [Theme.iridescent[0]], center: .center).opacity(alpha))
        }
        let ramp = [0.55, 0.7, 0.85, 1.0][ring]
        let strength = 0.3 + 0.7 * min(max(share, 0), 1)
        return AnyShapeStyle(Theme.purple.opacity(strength * ramp))
    }

    private func labelPoint(center: CGPoint, angle: Double, radius: CGFloat) -> CGPoint {
        let rad: Double = angle * .pi / 180
        return CGPoint(x: center.x + CGFloat(Foundation.cos(rad)) * radius, y: center.y + CGFloat(Foundation.sin(rad)) * radius)
    }

    private func labelView(_ l: StrengthTrends.RegionLoad, at p: CGPoint) -> some View {
        VStack(spacing: 1) {
            Text(label(l))
                .font(.display(15, weight: .heavy)).monospacedDigit()
                .foregroundStyle(value(l) > 0 ? Theme.ink : Theme.inkTertiary)
                .contentTransition(.numericText())
            Text(l.region.displayName)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
        }
        .fixedSize()
        .position(p)
    }
}

/// One ring's arc (stroked with round caps by the wheel).
struct RingArc: Shape {
    var startAngle: Angle
    var endAngle: Angle
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                 startAngle: startAngle, endAngle: endAngle, clockwise: false)
        return p
    }
}

// MARK: - Strength progression rows

/// "Strength progression": one row per lift — name, equipment · sessions, and a step sparkline
/// of its e1RM ending in a lit point. Tap a row for the lift's full history; the arrow opens
/// every lift.
struct StrengthProgressionCard: View {
    let rows: [StrengthTrends.LiftMetric]
    var weightUnit: WeightUnit = .kg
    var animate: Bool = true
    var onOpenAll: () -> Void
    var onOpen: (StrengthTrends.LiftMetric) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                Text("Strength progression").font(.rounded(Theme.FontSize.headline, weight: .bold)).foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.Space.sm)
                Button(action: { Haptics.light(); onOpenAll() }) {
                    Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("All lifts")
            }
            .padding(.bottom, Theme.Space.xs)
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, m in
                if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                Button { Haptics.light(); onOpen(m) } label: {
                    StrengthProgressionRow(metric: m, weightUnit: weightUnit, animate: animate, delay: 0.12 * Double(i))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableScaleStyle(scale: 0.985))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

struct StrengthProgressionRow: View {
    let metric: StrengthTrends.LiftMetric
    var weightUnit: WeightUnit = .kg
    var animate: Bool = true
    /// Draw-in stagger, so a list of rows arrives as a cascade rather than a slam.
    var delay: Double = 0

    private var subtitle: String {
        let gear = metric.equipment.map { $0.rawValue.capitalized } ?? "Lift"
        return "\(gear) · \(metric.sessions) session\(metric.sessions == 1 ? "" : "s")"
    }

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(metric.name).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(subtitle).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.sm)
            StepSparkline(values: metric.spark, animate: animate, delay: delay)
                .frame(width: 104, height: 34)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.name)
        .accessibilityValue("\(Formatters.weight(kg: metric.currentE1RMKg, unit: weightUnit)) estimated one rep max, \(subtitle)")
        .accessibilityHint("Shows the full history")
    }
}

/// e1RM as a STEP line (strength moves in jumps, session to session) with the newest point lit.
/// A single session draws a flat line to its point: nothing to climb yet, honestly.
struct StepSparkline: View {
    let values: [Double]
    var animate: Bool = true
    var delay: Double = 0
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            if let last = pts.last {
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: CGPoint(x: 0, y: first.y))
                    var prev = CGPoint(x: 0, y: first.y)
                    for pt in pts {
                        p.addLine(to: CGPoint(x: pt.x, y: prev.y))
                        p.addLine(to: pt)
                        prev = pt
                    }
                }
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(Theme.ink.opacity(0.5), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                Circle().fill(IridescentMaterial()).frame(width: 14, height: 14).blur(radius: 5).opacity(drawn ? 0.9 : 0)
                    .position(last)
                Circle().fill(IridescentMaterial()).frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Theme.background, lineWidth: 1.5))
                    .scaleEffect(drawn ? 1 : 0.2).opacity(drawn ? 1 : 0)
                    .position(last)
            }
        }
        .onAppear {
            if reduceMotion || !animate { drawn = true }
            else { withAnimation(.easeOut(duration: 0.8).delay(delay)) { drawn = true } }
        }
        .accessibilityHidden(true)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let v = values.filter(\.isFinite)
        guard !v.isEmpty else { return [] }
        let lo = v.min() ?? 0, hi = v.max() ?? 1
        let span = max(hi - lo, 0.001)
        let inset: CGFloat = 5
        let w = size.width - inset * 2, h = size.height - inset * 2
        if v.count == 1 { return [CGPoint(x: size.width - inset, y: size.height / 2)] }
        return v.enumerated().map { i, val in
            CGPoint(x: inset + w * CGFloat(i) / CGFloat(v.count - 1),
                    y: inset + h * (1 - CGFloat((val - lo) / span)))
        }
    }
}

/// Every lift, same rows, from the card's arrow.
struct StrengthProgressionListView: View {
    let rows: [StrengthTrends.LiftMetric]
    var weightUnit: WeightUnit = .kg
    var onOpen: (StrengthTrends.LiftMetric) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, m in
                    if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                    Button { Haptics.light(); onOpen(m) } label: {
                        StrengthProgressionRow(metric: m, weightUnit: weightUnit, animate: true, delay: 0.05 * Double(min(i, 8)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableScaleStyle(scale: 0.985))
                }
            }
            .padding(Theme.Space.md)
            .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .padding(Theme.Space.lg)
        }
        .background(Theme.background)
        .navigationTitle("Strength progression")
    }
}

// MARK: - Muscle load detail

/// The wheel's tap-through: the same wheel at full size, the body figure lit from the very same
/// numbers, a window picker, and every region spelled out. High-end, quiet, all one language.
struct MuscleLoadDetailView: View {
    let workouts: [Workout]
    var weightUnit: WeightUnit = .kg
    var initialDays: Int = 30
    @State private var days: Int = 30
    @State private var metric: MuscleLoadCard.Metric = .volume
    @State private var loads: [StrengthTrends.RegionLoad] = []
    @State private var resolved = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var totalVolume: Double { loads.reduce(0) { $0 + $1.volumeKg } }
    private var totalSets: Double { loads.reduce(0) { $0 + $1.sets } }
    private func value(_ l: StrengthTrends.RegionLoad) -> Double {
        metric == .volume ? l.volumeKg : (totalSets > 0 ? l.sets / totalSets : 0)
    }
    private func label(_ l: StrengthTrends.RegionLoad) -> String {
        switch metric {
        case .volume:
            let v = weightUnit == .lb ? l.volumeKg * Formatters.lbPerKg : l.volumeKg
            return v <= 0 ? "0" : "\(Formatters.compact(v)) \(weightUnit == .lb ? "lb" : "kg")"
        case .share: return "\(Int((value(l) * 100).rounded()))%"
        }
    }
    private var ranked: [StrengthTrends.RegionLoad] { loads.sorted { value($0) > value($1) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                HStack(spacing: Theme.Space.sm) {
                    SegmentedCapsule(items: [7, 30, 90], selection: $days, scale: .compact,
                                     title: { "\($0)D" }, spokenLabel: { "Last \($0) days" })
                    Spacer(minLength: 0)
                    SegmentedCapsule(items: MuscleLoadCard.Metric.allCases, selection: $metric, scale: .compact,
                                     title: { $0 == .volume ? "Volume" : "Load" })
                }
                if resolved {
                    headline
                    VStack(spacing: 0) {
                        RadialMuscleWheel(loads: loads, value: value, label: label, animate: !reduceMotion, scale: 0.34)
                            .frame(height: 340)
                            .id("\(days)-\(metric == .volume)")
                    }
                    .padding(Theme.Space.md)
                    .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    bodyCard
                    regionsCard
                } else {
                    RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface).frame(height: 340)
                        .redacted(reason: .placeholder)
                }
            }
            .padding(Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationTitle("Muscle load")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !resolved { days = initialDays } }
        .task(id: "\(days)-\(workouts.contentSignature)") {
            let w = workouts, d = days
            let built = StrengthTrends.regionLoads(in: w, days: d)
            withAnimation(.smooth(duration: 0.4)) { loads = built; resolved = true }
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric == .volume ? "WEIGHT MOVED" : "WHERE THE LOAD SITS")
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                if metric == .volume {
                    Text(Formatters.compact(weightUnit == .lb ? totalVolume * Formatters.lbPerKg : totalVolume))
                        .font(.display(40, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                    Text(weightUnit == .lb ? "lb" : "kg").font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                } else if let top = ranked.first, value(top) > 0 {
                    Text(top.region.displayName).font(.display(40, weight: .black)).foregroundStyle(Theme.ink)
                    Text("\(Int((value(top) * 100).rounded()))% of your sets").font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                } else {
                    Text("—").font(.display(40, weight: .black)).foregroundStyle(Theme.inkTertiary)
                }
            }
            Text("Last \(days) days · working sets across every lift")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The figure, lit from the WHEEL's own numbers: every muscle in a region carries that
    /// region's share of the leader, on the same relative scale the rings use — so the region
    /// with four rings burns full and a one-ring region is a faint tint. (The absolute
    /// weekly-sets grading would light the whole body for anyone training everything.)
    private var bodyActivation: [MuscleGroup: Double] {
        let maxV = loads.map(value).max() ?? 0
        guard maxV > 0 else { return [:] }
        var out: [MuscleGroup: Double] = [:]
        for m in MuscleGroup.allCases where m != .fullBody {
            guard let r = StrengthTrends.BodyRegion.of(m), let l = loads.first(where: { $0.region == r }) else { continue }
            out[m] = value(l) / maxV * MuscleMapGrading.fullBurnWeeklySets
        }
        return out
    }

    private var bodyCard: some View {
        MuscleMapView(activation: bodyActivation, sides: [.front, .back], grading: .weeklyVolume, forceStatic: reduceMotion)
            .frame(height: 320)
            .frame(maxWidth: .infinity)
            .padding(Theme.Space.md)
            .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .animation(.smooth(duration: 0.45), value: metric)
    }

    private var regionsCard: some View {
        let maxV = ranked.first.map(value) ?? 0
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("BY REGION").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            ForEach(Array(ranked.enumerated()), id: \.element.id) { i, l in
                if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                HStack(spacing: Theme.Space.md) {
                    Text(l.region.displayName)
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 92, alignment: .leading)
                    GeometryReader { geo in
                        Capsule()
                            .fill(i == 0 && value(l) > 0 ? AnyShapeStyle(IridescentMaterial()) : AnyShapeStyle(Theme.ink.opacity(0.7)))
                            .frame(width: max(value(l) > 0 ? 6 : 0, geo.size.width * (maxV > 0 ? value(l) / maxV : 0)))
                            .frame(maxHeight: .infinity, alignment: .center)
                            .animation(.smooth(duration: 0.5), value: metric)
                    }
                    .frame(height: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(label(l)).font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                            .contentTransition(.numericText())
                        Text(l.sets == l.sets.rounded() ? "\(Int(l.sets)) sets" : String(format: "%.1f sets", l.sets))
                            .font(.rounded(Theme.FontSize.caption, weight: .medium)).monospacedDigit().foregroundStyle(Theme.inkTertiary)
                    }
                    .frame(width: 84, alignment: .trailing)
                }
                .padding(.vertical, 8)
            }
            if let least = ranked.last, let top = ranked.first, value(top) > 0, value(least) < value(top) * 0.35 {
                Text("\(least.region.displayName) is carrying the least. A little more there evens you out.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .padding(.top, 2)
            }
        }
        .padding(Theme.Space.md)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
