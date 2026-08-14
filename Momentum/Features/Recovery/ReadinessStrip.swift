import SwiftUI

/// Today's readiness, cached so every surface (the Today deck's morning readout, the Trends
/// strip, the Health hero) shows the SAME number. Since 2026-07-22 every writer computes the one
/// full-blend recipe (`ReadinessToday` — banded baselines + learned sleep need/debt); whichever
/// surface computed most recently publishes here, and nothing renders a light blend anymore (the
/// old deck/strip fallback read 83 where the full blend read 75 — that class of mismatch is gone).
enum ReadinessTodayCache {
    private static let key = "health.readiness.today"

    static func store(score: Int, band: String, driver: String,
                      now: Date = Date(), calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: now).timeIntervalSinceReferenceDate
        UserDefaults.standard.set(["day": day, "score": score, "band": band, "driver": driver] as [String: Any],
                                  forKey: key)
    }

    /// Forget the published score — the data wipes call this so a fresh start's first morning
    /// can't open on the deleted athlete's number.
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    static func today(now: Date = Date(), calendar: Calendar = .current)
        -> (score: Int, band: String, driver: String)? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key),
              let day = dict["day"] as? Double,
              day == calendar.startOfDay(for: now).timeIntervalSinceReferenceDate,
              let score = dict["score"] as? Int,
              let band = dict["band"] as? String,
              let driver = dict["driver"] as? String else { return nil }
        return (score, band, driver)
    }
}

extension MorningReadiness {
    /// The pillar doing the most work today, in plain words — one phrasing for every surface.
    var displayDriverLine: String {
        guard let top = pillars.max(by: { abs($0.points) < abs($1.points) }) else {
            return RecoveryModel.guidance(band)
        }
        let up = top.points >= 0
        switch top.kind {
        case .load:      return up ? "Load well absorbed" : "Recent load still settling"
        case .hrv:       return up ? "HRV above your norm" : "HRV below your norm"
        case .sleep:     return up ? "Slept well" : "Short night"
        case .restingHR: return up ? "Resting HR steady" : "Resting HR elevated"
        case .checkin:   return up ? "Feeling good today" : "Body says take it easier"
        }
    }
}

/// The compact readiness hand-off in Progress → Trends (RECOVERY-HUB-PLAN §2, amended): one glance
/// — mini ring, score, band word, the single biggest driver — and a tap that lands on the Health
/// segment where the full story lives. Trends keeps exactly this strip; the retired Form/Recovery
/// cards' depth (ring detail, signals, vitals, balance) is all Health's now. TSB/Form stays with
/// `FitnessFreshnessCard` in the Pro trends cluster.
struct ReadinessStrip: View {
    /// Plain display values — the caller decides cache-vs-computed (`ReadinessTodayCache` first).
    let score: Int?
    let bandWord: String?
    let driverLine: String?
    var onOpen: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The primed mini-ring's mesh animates only while visible (see `miniRing`).
    @State private var onScreen = true

    private var primed: Bool { bandWord == RecoveryModel.Readiness.primed.rawValue }

    var body: some View {
        Button {
            Haptics.light()
            onOpen()
        } label: {
            label
        }
        .onScrollVisibilityChange(threshold: 0.05) { onScreen = $0 }
        .buttonStyle(.plain)
        // No `.accessibilityElement(children: .ignore)` here — a Button is already one element,
        // and the extra wrapper made XCUITest/VoiceOver read the combined child text instead of
        // this label+value pair (the readiness score was silently unexposed).
        .accessibilityLabel("Readiness")
        .accessibilityValue(score.map { "\($0) out of 100, \(bandWord ?? "")" } ?? "Learning you")
        .accessibilityHint("Opens the Health segment")
    }

    /// Hoisted from the Button so the type-checker never chews on one giant expression.
    private var label: some View {
        HStack(spacing: Theme.Space.md) {
                miniRing
                VStack(alignment: .leading, spacing: 1) {
                    if let bandWord, let driverLine {
                        Text(bandWord)
                            .font(.rounded(Theme.FontSize.body, weight: .bold))
                            .foregroundStyle(Theme.ink)
                        Text(driverLine)
                            .font(.rounded(Theme.FontSize.label, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary)
                            .lineLimit(1)
                    } else {
                        Text("Readiness")
                            .font(.rounded(Theme.FontSize.body, weight: .bold))
                            .foregroundStyle(Theme.ink)
                        Text("Learning you — check in or connect Health")
                            .font(.rounded(Theme.FontSize.label, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Theme.Space.sm)
                if let score {
                    Text("\(score)")
                        .font(.display(26, weight: .black)).monospacedDigit()
                        .foregroundStyle(Theme.ink)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
            }
        .padding(Theme.Space.md)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.hairline)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// 44pt mini ring — the bright band color with its soft glow (matching the hero ring);
    /// the earned iridescent fill still appears only at Primed (§6).
    private var miniRing: some View {
        let score = self.score ?? 0
        let color = Theme.Health.readinessColor(RecoveryModel.band(score))
        return ZStack {
            Circle().stroke(color.opacity(
                colorScheme == .dark ? 0.18 : 0.14), lineWidth: 5)
            if score > 0 {
                Circle()
                    .trim(from: 0, to: CGFloat(score) / 100)
                    .stroke(style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .foregroundStyle(color)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.5), radius: 6)
                    .overlay {
                        if primed {
                            // Frozen when scrolled off — this strip lives inside the Progress
                            // scroll and its mesh kept ticking at 30 fps once past (perf audit
                            // 2026-08-13; visibility gate set on the strip's body).
                            IridescentView(intensity: 0.9, isStatic: reduceMotion || !onScreen)
                                .mask(Circle().trim(from: 0, to: CGFloat(score) / 100)
                                    .stroke(style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                    .rotationEffect(.degrees(-90)))
                        }
                    }
            }
        }
        .frame(width: 44, height: 44)
    }

}
