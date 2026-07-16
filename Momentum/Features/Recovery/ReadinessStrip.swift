import SwiftUI

/// Today's hub-computed readiness, cached so every OTHER surface (the Trends strip, the athlete
/// panel rail) shows the SAME number the Health hero shows. The hub's `Model.build` computes the
/// richest blend (banded baselines + sleep need/debt); the light `MorningReadiness(load:signals:)`
/// fallback the strip can compute alone overshoots it (83 vs 75, screenshot-verified) — so the
/// cache wins whenever it's from today, and the fallback only covers the pre-first-visit gap.
enum ReadinessTodayCache {
    private static let key = "health.readiness.today"

    static func store(score: Int, band: String, driver: String,
                      now: Date = Date(), calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: now).timeIntervalSinceReferenceDate
        UserDefaults.standard.set(["day": day, "score": score, "band": band, "driver": driver] as [String: Any],
                                  forKey: key)
    }

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

    private var primed: Bool { bandWord == RecoveryModel.Readiness.primed.rawValue }

    var body: some View {
        Button {
            Haptics.light()
            onOpen()
        } label: {
            label
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
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

    /// 44pt mini ring — mint ink; the earned iridescent fill appears only at Primed (§6).
    private var miniRing: some View {
        let score = self.score ?? 0
        return ZStack {
            Circle().stroke(Theme.Health.recoveryWash.opacity(
                colorScheme == .dark ? 0.34 : 0.5), lineWidth: 5)
            if score > 0 {
                Circle()
                    .trim(from: 0, to: CGFloat(score) / 100)
                    .stroke(style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .foregroundStyle(Theme.Health.recoveryInk)
                    .rotationEffect(.degrees(-90))
                    .overlay {
                        if primed {
                            IridescentView(intensity: 0.9, isStatic: reduceMotion)
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
