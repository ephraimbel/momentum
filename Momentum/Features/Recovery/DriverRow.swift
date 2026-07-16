import SwiftUI

/// Why today's score is what it is — and what the plan did about it (RECOVERY-HUB-PLAN §5 row 2).
///
/// The top three `MorningReadiness` pillars by |points| render as tappable driver rows with
/// deviation mini-bars growing from a baseline centerline — the contributor cascade, where the
/// pedagogy IS the animation (`points = weight·(score − 50)`, so the bars literally sum to the
/// score's distance from 50). Each driver states its plan effect in plain words. Below them:
/// the illness-watch modifier chips (lilac + words, never red), the ACWR chip once the load
/// ratio runs above 1.3 (§11.1.6 — the tripwire's load half must not be invisible until it
/// fires), the live adaptation readout (all clear / active warnings / today's receipt — with
/// §11.1.5's honest low-from-load copy when the score is low but no acute signal fired), and
/// the `CoachingEvent`-shaped ease/recover timeline.
///
/// The caller maps engine outputs in (`RecoveryAdaptation.decide`/`tripwire` → `Readout`,
/// `CoachingEvent` → `TimelineEntry`); this view computes nothing heavy. The timeline is the
/// Pro depth layer (§8) — free callers pass `[]` and the section simply doesn't render.
/// Reduce Motion: bars appear at full size, no stagger.
struct DriverRow: View {

    /// The live plan response, mapped by the caller from `RecoveryAdaptation.decide`/`tripwire`.
    enum Readout: Equatable {
        /// No signals firing. Renders §11.1.5's honest copy instead when the score is
        /// load-driven low (the plan already carries that via deload cadence).
        case allClear
        /// Active warning lines, verbatim from the engines ("breathing rate above your norm", …).
        case warnings([String])
        /// Today was adjusted — the plain-words receipt ("Today became easy on purpose — …").
        case adjusted(String)
    }

    /// One row of the ease/recover trail — `CoachingEvent`-shaped (headline + persisted reason).
    struct TimelineEntry: Identifiable, Equatable {
        let date: Date
        let headline: String
        let reason: String
        var id: String { "\(date.timeIntervalSinceReferenceDate)·\(headline)" }
    }

    let pillars: [MorningReadiness.Pillar]
    var modifiers: [MorningReadiness.Modifier] = []
    let readout: Readout
    var acwr: Double? = nil
    var timeline: [TimelineEntry] = []
    /// Chips scroll to their card — the Health segment wires this to its scroll proxy.
    var onSelectPillar: ((MorningReadiness.PillarKind) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var grown = false

    /// §6 dark mode: washes warm from 12% to 16%; inks never re-anodize.
    private var washOpacity: Double {
        colorScheme == .dark ? Theme.Health.darkWashOpacity : Theme.Health.washOpacity
    }

    private var topDrivers: [MorningReadiness.Pillar] {
        Array(pillars.sorted { abs($0.points) > abs($1.points) }.prefix(3))
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("TODAY'S DRIVERS")
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Theme.inkTertiary)

                let drivers = topDrivers
                VStack(spacing: Theme.Space.sm) {
                    ForEach(Array(drivers.enumerated()), id: \.element.kind) { i, pillar in
                        driverRow(pillar, index: i,
                                  maxPoints: max(drivers.map { abs($0.points) }.max() ?? 0, 5))
                    }
                }

                if !modifiers.isEmpty || (acwr ?? 0) > 1.3 {
                    chipRow
                }

                readoutView

                if !timeline.isEmpty {
                    Divider().overlay(Theme.hairline)
                    timelineList
                }
            }
        }
        .onAppear { grown = true }   // rows animate themselves (per-row delayed transforms)
    }

    // MARK: Driver rows — the contributor cascade

    private func driverRow(_ pillar: MorningReadiness.Pillar, index: Int, maxPoints: Double) -> some View {
        Button {
            guard let onSelectPillar else { return }
            Haptics.selection()
            onSelectPillar(pillar.kind)
        } label: {
            HStack(spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label(for: pillar))
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(planEffect(for: pillar))
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                Spacer(minLength: Theme.Space.sm)

                deviationBar(points: pillar.points, maxPoints: maxPoints, index: index)

                Text(pointsText(pillar.points))
                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(for: pillar))
        .accessibilityValue("\(pointsText(pillar.points)) points. \(planEffect(for: pillar))")
        .accessibilityAddTraits(onSelectPillar == nil ? [] : .isButton)
    }

    /// A mini-bar growing out of a hairline centerline — right for lifting the score, left for
    /// dragging it. One domain ink (mint); direction is geometry, sign is the numeral, so it
    /// survives grayscale. Transform-only growth with a 70ms stagger; Reduce Motion → static.
    private func deviationBar(points: Double, maxPoints: Double, index: Int) -> some View {
        let positive = points >= 0
        let half: CGFloat = 46
        let width = max(3, half * abs(points) / maxPoints)
        return HStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                Color.clear
                if !positive { bar(width: width, anchor: .trailing, index: index) }
            }
            .frame(width: half)
            ZStack(alignment: .leading) {
                Color.clear
                if positive { bar(width: width, anchor: .leading, index: index) }
            }
            .frame(width: half)
        }
        .frame(height: 16)
        .background(Rectangle().fill(Theme.hairline).frame(width: 1.5, height: 16))
        .accessibilityHidden(true)  // the points value carries the meaning
    }

    private func bar(width: CGFloat, anchor: UnitPoint, index: Int) -> some View {
        Capsule()
            .fill(Theme.Health.recoveryInk)
            .frame(width: width, height: 6)
            .scaleEffect(x: grown ? 1 : 0.001, anchor: anchor)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.07 * Double(index)),
                       value: grown)
    }

    private func pointsText(_ points: Double) -> String {
        let rounded = Int(points.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }

    /// Plain-words driver names — never engine vocabulary.
    private func label(for pillar: MorningReadiness.Pillar) -> String {
        let neutral = abs(pillar.points) < 1.5
        switch pillar.kind {
        case .load:      return neutral ? "Load as usual" : pillar.points > 0 ? "Load well absorbed" : "Heavy recent load"
        case .hrv:       return neutral ? "HRV on your norm" : pillar.points > 0 ? "HRV above your norm" : "HRV below your norm"
        case .sleep:     return neutral ? "Sleep on target" : pillar.points > 0 ? "Slept well" : "Short sleep"
        case .restingHR: return neutral ? "Resting HR normal" : pillar.points > 0 ? "Resting HR settled" : "Resting HR elevated"
        case .checkin:   return neutral ? "Feeling okay" : pillar.points > 0 ? "You feel good" : "Body says tired"
        }
    }

    /// Each driver states its plan effect (§5) — what this signal did, or didn't do, to today.
    private func planEffect(for pillar: MorningReadiness.Pillar) -> String {
        if abs(pillar.points) < 1.5 { return "steady — no pull on today" }
        if pillar.points > 0 { return "supports today's session" }
        if case .adjusted = readout { return "part of why today eased" }
        return "watched — hasn't changed the plan"
    }

    // MARK: Modifier + ACWR chips

    private var chipRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.sm) { chips }
            VStack(alignment: .leading, spacing: Theme.Space.sm) { chips }
        }
    }

    @ViewBuilder private var chips: some View {
        ForEach(modifiers, id: \.kind) { modifier in
            chip(text: modifierText(modifier), points: Int(modifier.points.rounded()),
                 ink: Theme.Health.temperatureInk, wash: Theme.Health.temperatureWash)
        }
        if let acwr, acwr > 1.3 {
            chip(text: String(format: "Load %.1f× your recent norm", acwr), points: nil,
                 ink: Theme.Health.strainInk, wash: Theme.Health.strainWash)
        }
    }

    /// Words + one domain tint, never red — illness-watch is lilac, load is peach (§6).
    private func chip(text: String, points: Int?, ink: Color, wash: Color) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Circle().fill(ink).frame(width: 5, height: 5)
            Text(text)
                .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.ink)
            if let points {
                Text("\(points)")
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(.horizontal, Theme.Space.sm + Theme.Space.xxs)
        .padding(.vertical, Theme.Space.chipV)
        .background(Capsule().fill(wash.opacity(washOpacity)))
        .overlay(Capsule().stroke(Theme.hairline))
    }

    private func modifierText(_ modifier: MorningReadiness.Modifier) -> String {
        switch modifier.kind {
        case .respiratory:      "Breathing above your norm"
        case .wristTemperature: "Running warm vs your normal"
        }
    }

    // MARK: The live readout — the score's consequence, stated honestly

    @ViewBuilder private var readoutView: some View {
        switch readout {
        case .allClear:
            readoutLine(icon: "checkmark.circle",
                        tint: Theme.Health.recoveryInk,
                        text: loadDominatedLow
                            ? "Low from training load, no acute body signals — the plan already carries this via your deload cadence."
                            : "All clear — no signals firing.")
        case .warnings(let lines):
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(lines, id: \.self) { line in
                    readoutLine(icon: "waveform.path.ecg", tint: Theme.ink, text: line)
                }
            }
        case .adjusted(let receipt):
            readoutLine(icon: "arrow.triangle.2.circlepath",
                        tint: Theme.Health.recoveryInk,
                        text: receipt)
                .padding(Theme.Space.sm)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(Theme.Health.recoveryWash.opacity(washOpacity)))
        }
    }

    private func readoutLine(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// §11.1.5(a): the score can read low purely from training load while `decide()` returns
    /// nothing — say so, honestly, instead of a hollow "all clear".
    private var loadDominatedLow: Bool {
        guard let load = pillars.first(where: { $0.kind == .load }), load.points <= -5 else { return false }
        let mostNegative = pillars.min { $0.points < $1.points }?.kind
        return mostNegative == .load && pillars.reduce(0, { $0 + $1.points }) < 0
    }

    // MARK: Ease/recover timeline (Pro — free callers pass [])

    private var timelineList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("WHEN THE PLAN EASED")
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
            VStack(spacing: 0) {
                ForEach(Array(timeline.enumerated()), id: \.element.id) { i, entry in
                    HStack(alignment: .top, spacing: Theme.Space.md) {
                        VStack(spacing: 0) {
                            Image(systemName: "leaf")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .frame(width: 30, height: 30)
                                .background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
                            if i < timeline.count - 1 {
                                Rectangle().fill(Theme.hairline)
                                    .frame(width: 1.5).frame(maxHeight: .infinity)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.headline)
                                    .font(.rounded(Theme.FontSize.caption, weight: .bold))
                                    .foregroundStyle(Theme.ink)
                                Spacer(minLength: Theme.Space.sm)
                                Text(relativeDay(entry.date))
                                    .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(Theme.inkTertiary)
                            }
                            Text(entry.reason)
                                .font(.rounded(Theme.FontSize.label, weight: .medium))
                                .foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, i < timeline.count - 1 ? Theme.Space.md : 0)
                    }
                }
            }
        }
    }

    private func relativeDay(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Previews

#Preview("Adjusted day") {
    ScrollView {
        DriverRow(
            pillars: [
                .init(kind: .load, score: 62, weight: 0.33),
                .init(kind: .hrv, score: 28, weight: 0.28),
                .init(kind: .sleep, score: 41, weight: 0.22),
                .init(kind: .restingHR, score: 44, weight: 0.17),
            ],
            modifiers: [.init(kind: .respiratory, points: -5)],
            readout: .adjusted("Today became easy on purpose — readiness 42 this morning, so the tempo converted to an easy 30."),
            acwr: 1.42,
            timeline: [
                .init(date: .now.addingTimeInterval(-86_400), headline: "Eased Thursday",
                      reason: "HRV well below your norm two mornings running."),
                .init(date: .now.addingTimeInterval(-5 * 86_400), headline: "Recovery day added",
                      reason: "Three hard days in a row with short sleep."),
            ],
            onSelectPillar: { _ in }
        )
        .padding()
    }
    .background(Theme.background)
}

#Preview("All clear") {
    ScrollView {
        DriverRow(
            pillars: [
                .init(kind: .hrv, score: 68, weight: 0.36),
                .init(kind: .sleep, score: 74, weight: 0.29),
                .init(kind: .restingHR, score: 58, weight: 0.35),
            ],
            readout: .allClear
        )
        .padding()
    }
    .background(Theme.background)
}

#Preview("Low from load") {
    ScrollView {
        DriverRow(
            pillars: [
                .init(kind: .load, score: 20, weight: 0.40),
                .init(kind: .hrv, score: 52, weight: 0.33),
                .init(kind: .sleep, score: 55, weight: 0.27),
            ],
            readout: .allClear,
            acwr: 1.35
        )
        .padding()
    }
    .background(Theme.background)
}
