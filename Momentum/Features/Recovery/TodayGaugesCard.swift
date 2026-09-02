import SwiftUI

/// Today at a glance (glass pass 2026-08-27, the Bevel/Oura opener): three gauges — Strain,
/// Load, Sleep — side by side in one raised card, and the coaching line under them. Recovery is
/// deliberately NOT here: the readiness ring directly above already says it, and the same
/// number twice in a row read as a mistake. Every value is an engine output already on the page
/// (DayStrain, ACWRGovernor, SleepReport); a missing one draws the bare track, never a fake zero.
struct TodayGaugesCard: View {
    /// Today's DayStrain score, 0–100.
    let strain: Double?
    /// Training load — the 7:28 recent-to-usual ratio. The arc normalizes at 1.5× for legibility;
    /// a full arc is not a safety or injury threshold.
    let acwr: Double?
    /// Last night asleep ÷ need, 0…1+ (clamped for the arc; the label shows hours).
    let sleepFraction: Double?
    let sleepText: String?
    /// The readiness guidance sentence — the "coaching" line.
    let coaching: String?
    /// Tap-throughs — each ring opens its own full-window detail (the Oura/Bevel move). nil
    /// leaves that ring inert (previews, specimen data), with no chevron promising depth.
    var onOpenStrain: (() -> Void)? = nil
    var onOpenLoad: (() -> Void)? = nil
    var onOpenSleep: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            EyebrowLabel(text: "Today", tint: Theme.purple)
            HStack(spacing: 0) {
                gauge(GaugeRing(value: strain.map { $0 / 100 },
                                text: strain.map { "\(Int($0.rounded()))" } ?? "",
                                label: "Strain", tint: Theme.Health.strainInk,
                                showsChevron: onOpenStrain != nil),
                      open: onOpenStrain, name: "Strain")
                divider
                gauge(GaugeRing(value: acwr.map { min(1, $0 / 1.5) },
                                text: acwr.map { String(format: "%.2f", $0) } ?? "",
                                label: "Load", tint: Theme.purple,
                                showsChevron: onOpenLoad != nil),
                      open: onOpenLoad, name: "Load")
                divider
                gauge(GaugeRing(value: sleepFraction.map { min(1, $0) },
                                text: sleepText ?? "",
                                label: "Sleep", tint: Theme.Health.sleepInk,
                                showsChevron: onOpenSleep != nil),
                      open: onOpenSleep, name: "Sleep")
            }
            if let coaching, !coaching.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                VStack(alignment: .leading, spacing: 4) {
                    Text("COACHING")
                        .font(.rounded(10, weight: .bold)).tracking(1.2)
                        .foregroundStyle(Theme.inkTertiary)
                    Text(coaching)
                        .font(.rounded(15, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Theme.Space.md + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raised(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// One ring as a tap target. A ring with nowhere to go stays a plain readout — no press
    /// feedback, no button trait, no chevron.
    @ViewBuilder
    private func gauge(_ ring: GaugeRing, open: (() -> Void)?, name: String) -> some View {
        if let open {
            Button {
                Haptics.light()
                open()
            } label: {
                ring.frame(maxWidth: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(RaisedPressStyle(scale: 0.96))
            .accessibilityHint("Shows the full \(name.lowercased()) trend")
        } else {
            ring.frame(maxWidth: .infinity)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 64)
    }
}
