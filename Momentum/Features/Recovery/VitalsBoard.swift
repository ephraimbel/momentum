import SwiftUI
import Charts

/// One vital, shaped for a board tile (docs/RECOVERY-HUB-PLAN.md §5 row 5). The segment's
/// `Model.build()` fills these from `HealthService` day-bucketed history + `HealthBaselines`
/// off the render path; the board computes nothing but layout. All strings arrive as words —
/// the builder owns the judgment ("In your normal range"), the tile never re-derives it.
struct VitalTileModel: Identifiable {
    enum Kind: String, CaseIterable {
        case hrv, restingHR, respiratory, wristTemp, walkingHR
    }

    let kind: Kind
    /// Most recent daily value; nil = no reading yet (empty means absent, never zero).
    let latest: Double?
    let unit: String
    /// Factual delta words, e.g. "+4 ms vs normal". Empty = no chip.
    let delta: String
    /// In/out-of-band stated in words — never a color judgment (§6: no bad color in the hub).
    let inBand: String
    /// Trailing ~30 daily values, oldest → newest.
    let spark: [Double]
    /// The personal band (mean ± 1 SD) once `HealthBaselines` has ≥ 7 days; nil before.
    let band: (lower: Double, upper: Double)?
    /// Days banked toward the baseline, and the establishment bar (14).
    let baselineDayCount: Int
    let targetDays: Int

    var id: String { kind.rawValue }
    var isBuilding: Bool { baselineDayCount < targetDays }
    /// "No data at all" — drives the §11.2.3 adaptive slot.
    var hasAnyData: Bool { latest != nil || !spark.isEmpty || baselineDayCount > 0 }

    var title: String {
        switch kind {
        case .hrv: "HRV"
        case .restingHR: "Resting HR"
        case .respiratory: "Respiratory"
        case .wristTemp: "Wrist temp"
        case .walkingHR: "Walking HR"
        }
    }

    var explainer: MetricExplainer {
        switch kind {
        case .hrv: MetricExplainers.hrv
        case .restingHR: MetricExplainers.restingHR
        case .respiratory: MetricExplainers.respiratoryRate
        case .wristTemp: MetricExplainers.wristTemperature
        case .walkingHR: MetricExplainers.walkingHR
        }
    }

    /// Temperature is the lone lilac tile; every other vital is ice (§6 — one pastel per domain).
    var ink: Color { kind == .wristTemp ? Theme.Health.temperatureInk : Theme.Health.vitalsInk }
    var wash: Color { kind == .wristTemp ? Theme.Health.temperatureWash : Theme.Health.vitalsWash }

    func format(_ value: Double) -> String {
        switch kind {
        case .respiratory, .wristTemp: String(format: "%.1f", value)
        default: "\(Int(value.rounded()))"
        }
    }
}

/// "Your vitals" — the 2×2 grid of upgraded vital tiles: latest value, delta chip, in/out-of-band
/// in words, and a 30-day sparkline riding the personal-band ribbon (the ribbon IS the reference —
/// no axes on tiles). Tap a charted tile for the full 30-day `TrendChartCard`. Tile priority:
/// HRV · resting HR · respiratory · wrist-temp-or-walking-HR — the 4th slot adapts because
/// Garmin/Oura/Whoop never write wrist temperature (§11.2.3). Confidence lives on the hero's
/// footnote, not here (§11.2.7) — tiles only ever show their own building state.
struct VitalsBoard: View {
    let tiles: [VitalTileModel]
    /// §8 free/Pro split: free tiles keep the latest value + delta chip + in/out-of-band words;
    /// the 30-day sparkline, band ribbon, and trend-sheet tap are the Pro depth layer.
    var isPro: Bool = true
    /// When every vital is empty and this is provided, the board collapses to one elegant
    /// `ConnectRow` (§5) instead of a grid of dashes.
    var onConnect: (() -> Void)? = nil
    /// Long-window history for the tap-through detail — day-bucketed values for the last `days`
    /// days, per kind (the segment wires this to `HealthService`). nil (previews, stubs) falls
    /// back to the tile's own 30-day spark, so the sheet still opens — just without the year.
    var history: ((VitalTileModel.Kind, _ days: Int) async -> [(day: Date, value: Double)])? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var selected: VitalTileModel?

    private let columns = [GridItem(.flexible(), spacing: Theme.Space.sm),
                           GridItem(.flexible(), spacing: Theme.Space.sm)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            VStack(alignment: .leading, spacing: 4) {
                EyebrowLabel(text: "Your vitals", tint: Theme.Health.vitalsInk)
                Text("Every band is your own normal — learned from your nights, never compared.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if ordered.allSatisfy({ !$0.hasAnyData }), let onConnect {
                ConnectRow(onConnect: onConnect)
            } else if ordered.allSatisfy({ !$0.hasAnyData }) {
                // Health IS connected but nothing writes these signals — the phone alone can't.
                // Name the actual requirement instead of four bare "No readings yet" tiles.
                Text("These vitals arrive from a wearable — Apple Watch, Garmin, Oura, or Whoop — syncing to Apple Health. Wear one overnight and they fill in on their own.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Theme.Space.sm)
            } else {
                LazyVGrid(columns: columns, spacing: Theme.Space.sm) {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, model in
                        VitalTileView(model: model, appeared: appeared, index: index, isPro: isPro) {
                            if isPro, model.spark.count > 1 { selected = model }
                        }
                    }
                }
            }
        }
        .sheet(item: $selected) { model in
            TrendDetailSheet(detail: detail(for: model))
        }
        .onAppear {
            if reduceMotion { appeared = true }
            else { withAnimation(Motion.entrance) { appeared = true } }
        }
    }

    /// The tap-through detail (the Trends `TrendDetailSheet`, one level deeper): month-to-year
    /// windows fetched live from Health, the line in the vital's domain ink over the personal-band
    /// ribbon, and the same ⓘ prose beneath. Without a fetcher the series falls back to the
    /// tile's 30-day spark re-anchored on real dates ending today.
    private func detail(for model: VitalTileModel) -> TrendDetail {
        let fetch = history
        return TrendDetail(
            id: "vital-\(model.kind.rawValue)",
            title: model.title,
            unit: model.unit,
            form: .line,
            stats: [.average, .latest],
            hugsY: true,
            tint: model.ink,
            band: model.band,
            bandTint: model.wash,
            bandNote: model.band != nil ? "mean ± 1 SD · \(model.baselineDayCount) days" : nil,
            explainer: model.explainer,
            format: { model.format($0) },
            series: { weeks in
                if let fetch {
                    let fetched = await fetch(model.kind, weeks * 7)
                    if !fetched.isEmpty {
                        return fetched.map { .init(date: $0.day, value: $0.value) }
                    }
                }
                let calendar = Calendar.current
                let today = calendar.startOfDay(for: Date())
                let count = model.spark.count
                return model.spark.enumerated().compactMap { index, value in
                    calendar.date(byAdding: .day, value: -(count - 1 - index), to: today)
                        .map { .init(date: $0, value: value) }
                }
            })
    }

    /// §11.2.3 slotting: HRV, RHR, respiratory always; the 4th tile is wrist temperature unless
    /// it has no data at all, in which case walking HR takes the slot.
    private var ordered: [VitalTileModel] {
        var byKind: [VitalTileModel.Kind: VitalTileModel] = [:]
        for tile in tiles { byKind[tile.kind] = tile }
        var result: [VitalTileModel] = []
        for kind in [VitalTileModel.Kind.hrv, .restingHR, .respiratory] {
            if let tile = byKind[kind] { result.append(tile) }
        }
        if let temp = byKind[.wristTemp], temp.hasAnyData {
            result.append(temp)
        } else if let walking = byKind[.walkingHR] {
            result.append(walking)
        } else if let temp = byKind[.wristTemp] {
            result.append(temp)
        }
        return result
    }
}

// MARK: - Tile

private struct VitalTileView: View {
    let model: VitalTileModel
    let appeared: Bool
    let index: Int
    let isPro: Bool
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// §6 trigger 4: the ribbon wears its one-time welcome shimmer this appearance.
    @State private var ribbonShimmer = false
    /// 0→1 drives the masked sweep's offset across the ribbon (transform only).
    @State private var ribbonSweep: CGFloat = 0

    private var washOpacity: Double {
        colorScheme == .dark ? Theme.Health.darkWashOpacity : Theme.Health.washOpacity
    }
    /// The band ribbon runs hotter than the shared wash — at 0.12/0.16 it all but vanished in
    /// screenshots, and the "your normal range" story is the whole point of the sparkline.
    private var ribbonOpacity: Double { colorScheme == .dark ? 0.22 : 0.18 }
    /// The trend sheet + sparkline are Pro depth (§8) — free tiles are words only.
    private var chartable: Bool { isPro && model.spark.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                // The vital's glyph in its own ink on a soft disc (glass pass 2026-08-27) —
                // the tile announces its family before the number does.
                Image(systemName: glyph)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.ink)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(model.ink.opacity(0.13)))
                    .accessibilityHidden(true)
                Text(model.title.uppercased())
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1)
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityHidden(true)   // the collapsed readout below speaks the title
                Spacer(minLength: 4)
                // Outside the ignored element so VoiceOver can still reach the ⓘ.
                MetricInfoButton(explainer: model.explainer)
            }
            readout
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.title)
                .accessibilityValue(accessibilityValue)
                .accessibilityAddTraits(chartable ? .isButton : [])
                .accessibilityHint(chartable ? "Shows the full trend" : "")
        }
        .healthCard()
        .contentShape(Rectangle())
        .onTapGesture { if chartable { onOpen() } }
        .onAppear(perform: armBaselineShimmer)
    }

    /// One SF Symbol per vital family.
    private var glyph: String {
        switch model.kind {
        case .hrv: "waveform.path.ecg"
        case .restingHR: "heart.fill"
        case .respiratory: "lungs.fill"
        case .wristTemp: "thermometer.medium"
        case .walkingHR: "figure.walk"
        }
    }

    // MARK: Earned shimmer (§6 trigger 4 — first vitals baseline banked)

    /// The day the baseline lands exactly on the 14-day bar, the ribbon earns a single welcome
    /// shimmer — once ever per vital kind (persisted), a welcome moment, never recurring.
    private func armBaselineShimmer() {
        guard chartable, model.band != nil,
              model.baselineDayCount == model.targetDays,
              HealthShimmerGate.claim("health.shimmer.baseline.\(model.kind.rawValue)")
        else { return }
        ribbonShimmer = true
        guard !reduceMotion else { return }   // static tint on the ribbon — shows, doesn't move
        // Let the sparkline draw on first, then one masked sweep along the ribbon.
        withAnimation(.easeInOut(duration: 1.2).delay(0.6)) { ribbonSweep = 1 }
    }

    /// One iridescent sweep constrained to the band ribbon's frame (Reduce Motion: a static
    /// tint). The rect re-derives the ribbon from the same domain math the chart plots with,
    /// so the welcome lights exactly the band the athlete just banked. Transforms/opacity only.
    private func ribbonWelcome(band: (lower: Double, upper: Double),
                               domainLow: Double, domainHigh: Double) -> some View {
        GeometryReader { geo in
            let span = max(domainHigh - domainLow, .ulpOfOne)
            let top = geo.size.height * (domainHigh - band.upper) / span
            let height = geo.size.height * (band.upper - band.lower) / span
            IridescentView(intensity: reduceMotion ? 0.5 : 0.9, isStatic: true)
                .mask {
                    if reduceMotion {
                        Rectangle()
                    } else {
                        // A 35%-width band travelling fully off-left → fully off-right.
                        Rectangle()
                            .frame(width: geo.size.width * 0.35)
                            .offset(x: (ribbonSweep - 0.5) * geo.size.width * 1.35)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .frame(height: max(2, height))
                .offset(y: top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Everything under the header row, collapsed into the one spoken element.
    private var readout: some View {
        VStack(alignment: .leading, spacing: 6) {
            valueRow
            if model.hasAnyData, model.isBuilding {
                buildingBlock
            } else if model.hasAnyData {
                Text(model.inBand)
                    .font(.rounded(Theme.FontSize.label, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if chartable {
                    sparkChart
                } else if isPro {
                    Color.clear.frame(height: 40)
                }
            } else {
                Text("No readings yet")
                    .font(.rounded(Theme.FontSize.label, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                if isPro { Color.clear.frame(height: 40) }
            }
        }
    }

    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let latest = model.latest {
                Text(model.format(latest))
                    .font(.display(24, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(model.unit)
                    .font(.rounded(Theme.FontSize.label, weight: .bold))
                    .foregroundStyle(Theme.inkTertiary)
                if !model.delta.isEmpty { deltaChip }
            } else {
                Text("—")
                    .font(.display(22, weight: .heavy))
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
    }

    /// Factual words in a soft domain-wash capsule. Text stays monochrome — a data color never
    /// carries type (§6); the wash alone says which family this vital belongs to.
    private var deltaChip: some View {
        Text(model.delta)
            .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
            .foregroundStyle(model.ink)
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(model.ink.opacity(0.12)))
    }

    /// 30-day 2pt ink sparkline over the personal-band ribbon (mean ± 1 SD, quiet wash).
    /// No axes — the ribbon is the reference. Reveals left-to-right; Reduce Motion lands it whole.
    private var sparkChart: some View {
        let values = model.spark.filter(\.isFinite)
        var lower = values.min() ?? 0
        var upper = values.max() ?? 1
        if let band = model.band {
            lower = min(lower, band.lower)
            upper = max(upper, band.upper)
        }
        let pad = max((upper - lower) * 0.15, 0.01)
        return Chart {
            if let band = model.band, values.count > 1 {
                // Pinned to the line's x-extent so the ribbon's X type matches the LineMarks.
                RectangleMark(xStart: .value("Day", 0),
                              xEnd: .value("Day", values.count - 1),
                              yStart: .value("Band low", band.lower),
                              yEnd: .value("Band high", band.upper))
                    .foregroundStyle(model.wash.opacity(ribbonOpacity))
                    .cornerRadius(4)
            }
            ForEach(Array(values.enumerated()), id: \.offset) { day, value in
                // A soft wash under the line in the vital's own ink (glass pass 2026-08-27),
                // anchored to the chart floor so it never spills past the tile.
                AreaMark(x: .value("Day", day),
                         yStart: .value("floor", lower - pad),
                         yEnd: .value("Value", value))
                    .foregroundStyle(LinearGradient(colors: [model.ink.opacity(0.20), model.ink.opacity(0.0)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", day), y: .value("Value", value))
                    .foregroundStyle(model.ink)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let last = values.last {
                PointMark(x: .value("Day", values.count - 1), y: .value("Value", last))
                    .symbolSize(30).foregroundStyle(model.ink)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: (lower - pad)...(upper + pad))
        .frame(height: 40)
        .mask(alignment: .leading) {
            Rectangle().scaleEffect(x: appeared ? 1 : 0.001, anchor: .leading)
        }
        .animation(reduceMotion ? nil : Motion.entrance.delay(0.05 * Double(index)),
                   value: appeared)
        .overlay {
            if ribbonShimmer, let band = model.band {
                ribbonWelcome(band: band, domainLow: lower - pad, domainHigh: upper + pad)
            }
        }
    }

    /// < 14 baseline days: the tile states it plainly and shows the 14-tick progress row —
    /// the building state must look as designed as the full one (plan risk #6).
    private var buildingBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Building your baseline — \(min(model.baselineDayCount, model.targetDays)) of \(model.targetDays) days")
                .font(.rounded(Theme.FontSize.label, weight: .medium)).monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1).minimumScaleFactor(0.75)
            HStack(spacing: 3) {
                ForEach(0..<model.targetDays, id: \.self) { day in
                    Capsule()
                        .fill(day < model.baselineDayCount ? model.ink : Theme.hairline)
                        .frame(height: 4)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 18, alignment: .center)
        }
    }

    private var accessibilityValue: String {
        guard model.hasAnyData else { return "no readings yet" }
        var parts: [String] = []
        if let latest = model.latest { parts.append("\(model.format(latest)) \(model.unit)") }
        if model.isBuilding {
            parts.append("building your baseline, \(min(model.baselineDayCount, model.targetDays)) of \(model.targetDays) days")
        } else {
            if !model.delta.isEmpty { parts.append(model.delta) }
            parts.append(model.inBand)
        }
        return parts.joined(separator: ", ")
    }
}

// Previews compile into Release unless gated — and these are built from invented vitals,
// nights and strain series. No fabricated health data belongs in a shipped binary
// (production-readiness sweep 2026-07-16; the rest of this family was already gated).
#if DEBUG
// MARK: - Preview

#Preview("VitalsBoard") {
    let hrvSpark: [Double] = (0..<30).map { 62 + 8 * sin(Double($0) / 4) + Double($0 % 5) }
    let rhrSpark: [Double] = (0..<30).map { 49 + 2 * sin(Double($0) / 6) }
    let respSpark: [Double] = (0..<30).map { 14.2 + 0.4 * sin(Double($0) / 5) }
    let tiles = [
        VitalTileModel(kind: .hrv, latest: 64, unit: "ms", delta: "+4 vs normal",
                       inBand: "In your normal range", spark: hrvSpark,
                       band: (lower: 56, upper: 74), baselineDayCount: 30, targetDays: 14),
        VitalTileModel(kind: .restingHR, latest: 49, unit: "bpm", delta: "−1 vs normal",
                       inBand: "In your normal range", spark: rhrSpark,
                       band: (lower: 47, upper: 52), baselineDayCount: 30, targetDays: 14),
        VitalTileModel(kind: .respiratory, latest: 14.4, unit: "br/min", delta: "",
                       inBand: "Steady, as usual", spark: respSpark,
                       band: (lower: 13.8, upper: 15.0), baselineDayCount: 9, targetDays: 14),
        VitalTileModel(kind: .wristTemp, latest: nil, unit: "°C", delta: "",
                       inBand: "", spark: [], band: nil, baselineDayCount: 0, targetDays: 14),
        VitalTileModel(kind: .walkingHR, latest: 68, unit: "bpm", delta: "steady",
                       inBand: "In your normal range", spark: rhrSpark.map { $0 + 19 },
                       band: (lower: 64, upper: 72), baselineDayCount: 21, targetDays: 14),
    ]
    return ScrollView {
        VitalsBoard(tiles: tiles).padding()
    }
    .background(Theme.background)
}
#endif
