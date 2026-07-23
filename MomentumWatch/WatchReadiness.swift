import SwiftUI

/// The readiness ring, watch-sized — the same one-number honesty as the phone's hero. Ink ring on
/// every ordinary morning; the iridescent sweep is EARNED, appearing only at Primed (≥80, the
/// engine's own cut). Shared by the home card and the circular complication so the wrist never
/// shows two dialects of the same number.
struct WatchReadinessRing: View {
    let score: Int
    let band: String
    var lineWidth: CGFloat = 5

    private var primed: Bool { band == "primed" }

    var body: some View {
        ZStack {
            Circle().stroke(WatchTheme.surfaceStrong, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, Double(score) / 100))
                .stroke(primed ? AnyShapeStyle(WatchTheme.iridescentAngular) : AnyShapeStyle(WatchTheme.ink),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text("\(score)")
                    .font(.system(size: 100, weight: .bold, design: .rounded)).monospacedDigit()
                    .minimumScaleFactor(0.1)
                    .foregroundStyle(WatchTheme.ink)
            }
            .padding(lineWidth + 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Readiness")
        .accessibilityValue("\(score) out of 100, \(band)")
    }
}

/// The two-tap morning check-in, on the wrist where the morning actually happens: Energy, then
/// Legs — the same words the phone's sheet uses, feeding the same `DailyCheckin` on the phone.
/// Answers travel over WatchConnectivity (queued if the phone's away) and the recomputed
/// readiness pushes back as a context update.
struct WatchCheckinView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var energy: String?
    @State private var sent = false

    var body: some View {
        Group {
            if sent {
                sentView
            } else if step == 0 {
                question("How's your energy?", options: [
                    ("Low", "low"), ("OK", "ok"), ("Full", "full"),
                ]) { value in
                    energy = value
                    withAnimation(.smooth(duration: 0.3)) { step = 1 }
                }
            } else {
                question("How are your legs?", options: [
                    ("Fresh", "fresh"), ("OK", "ok"), ("Heavy", "heavy"), ("Sore", "sore"),
                ]) { value in
                    WatchSyncStore.shared.sendCheckin(energy: energy ?? "ok", legs: value)
                    WatchHaptics.done()
                    withAnimation(.smooth(duration: 0.35)) { sent = true }
                }
            }
        }
        .navigationTitle { Text("Check-in").foregroundStyle(WatchTheme.ink) }
    }

    private func question(_ title: String, options: [(label: String, value: String)],
                          onPick: @escaping (String) -> Void) -> some View {
        ScrollView {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(WatchTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 2)
                ForEach(options, id: \.value) { option in
                    Button {
                        WatchHaptics.tick()
                        onPick(option.value)
                    } label: {
                        Text(option.label)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(WatchTheme.control)
                    .foregroundStyle(WatchTheme.ink)
                }
            }
        }
    }

    private var sentView: some View {
        VStack(spacing: 8) {
            if let r = WatchSyncStore.shared.todayReadiness {
                WatchReadinessRing(score: r.score, band: r.band)
                    .frame(width: 74, height: 74)
                Text(bandWord(r.band))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(WatchTheme.ink)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(WatchTheme.accent)
                Text("Noted.")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(WatchTheme.ink)
                Text("Your readiness updates on your iPhone in a moment.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WatchTheme.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            Button("Done") { dismiss() }
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.bordered)
                .tint(WatchTheme.control)
                .padding(.top, 2)
        }
        .padding(.horizontal, 4)
    }
}

func bandWord(_ band: String) -> String {
    switch band {
    case "primed": "Primed"
    case "ready": "Ready"
    case "steady": "Steady"
    case "easy": "Take it easy"
    case "rest": "Rest up"
    default: band.capitalized
    }
}
