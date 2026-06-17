import SwiftUI
import WatchKit

/// On-wrist live cardio (PRD §4.10) — a paged experience like Apple Workout / Strava: a big
/// colour-coded **metrics** page (time hero, pace, distance, heart rate, calories) and a **controls**
/// page (round Pause/End/Water-lock). Numbers come from `WatchCardioModel` (HealthKit live workout);
/// the clock ticks via `TimelineView`. Real HR/distance need a physical Watch — on the sim the layout
/// renders and the clock runs while sensor values stay at zero.
struct WatchCardioView: View {
    let type: WorkoutType
    @Environment(\.dismiss) private var dismiss
    @State private var model: WatchCardioModel?
    @State private var ending = false

    private let unit: DistanceUnit = .auto

    var body: some View {
        Group {
            if let model {
                if model.failed { unavailable } else { live(model) }
            } else {
                ProgressView()
                    .task {
                        let m = WatchCardioModel(type: type)
                        await m.start()
                        model = m
                    }
            }
        }
        .navigationTitle(type.title)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: Paged live view

    private func live(_ model: WatchCardioModel) -> some View {
        TabView {
            metricsPage(model)
            controlsPage(model)
        }
        .tabViewStyle(.page)
    }

    private func metricsPage(_ model: WatchCardioModel) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    if model.paused { pausedChip }
                    Text(Formatters.duration(s: model.elapsed))
                        .font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(WatchTheme.ink)
                        .minimumScaleFactor(0.6).lineLimit(1)
                        .opacity(model.paused ? 0.55 : 1)

                    metric(heroLabel, heroValue(model), WatchTheme.accent)
                    metric("Distance", Formatters.distance(meters: model.distanceM, unit: unit), WatchTheme.ink)
                    metric("Heart Rate", "\(model.heartRateBPM)", WatchTheme.heart, icon: "heart.fill", suffix: "BPM")
                    metric("Active Cal", "\(Int(model.activeEnergyKcal))", WatchTheme.energy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            }
        }
    }

    private func controlsPage(_ model: WatchCardioModel) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 20) {
                controlButton(model.paused ? "Resume" : "Pause",
                              icon: model.paused ? "play.fill" : "pause.fill",
                              tint: WatchTheme.accent, iconColor: .black) {
                    model.togglePause()
                }
                controlButton("End", icon: "stop.fill", tint: .red, iconColor: .white) {
                    guard !ending else { return }
                    ending = true
                    Task { await model.end(); dismiss() }
                }
            }
            controlButton("Lock", icon: "drop.fill", tint: WatchTheme.control, iconColor: .white, compact: true) {
                WKInterfaceDevice.current().enableWaterLock()
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: Pieces

    private var pausedChip: some View {
        Text("PAUSED")
            .font(.system(size: 11, weight: .bold)).tracking(1.2)
            .foregroundStyle(WatchTheme.accent)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(WatchTheme.accent.opacity(0.18)))
    }

    private func metric(_ label: String, _ value: String, _ color: Color,
                        icon: String? = nil, suffix: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(0.5)
                .foregroundStyle(WatchTheme.inkSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 15, weight: .bold)).foregroundStyle(color)
                }
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(color).minimumScaleFactor(0.7).lineLimit(1)
                if let suffix {
                    Text(suffix).font(.system(size: 12, weight: .semibold)).foregroundStyle(WatchTheme.inkTertiary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private func controlButton(_ label: String, icon: String, tint: Color, iconColor: Color,
                               compact: Bool = false, action: @escaping () -> Void) -> some View {
        let size: CGFloat = compact ? 50 : 60
        return VStack(spacing: 6) {
            Button(action: action) {
                ZStack {
                    Circle().fill(tint)
                    Image(systemName: icon).font(.system(size: compact ? 18 : 23, weight: .bold))
                        .foregroundStyle(iconColor)
                }
                .frame(width: size, height: size)
            }
            .buttonStyle(.plain)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(WatchTheme.inkSecondary)
        }
    }

    private var heroLabel: String { type.discipline == .cycling ? "Speed" : "Pace" }

    private func heroValue(_ model: WatchCardioModel) -> String {
        let e = model.elapsed, d = model.distanceM
        if type.discipline == .cycling {
            return Formatters.speed(ms: e > 0 ? d / e : 0, unit: unit)
        }
        let secPerKm = (d > 0 && e > 0) ? e / (d / 1000) : 0
        return Formatters.pace(secPerKm: secPerKm, unit: unit)
    }

    private var unavailable: some View {
        VStack(spacing: 6) {
            Image(systemName: "heart.slash").font(.title2).foregroundStyle(WatchTheme.inkSecondary)
            Text("Health access needed").font(.headline).multilineTextAlignment(.center)
            Text("Allow workout access to track on your wrist.")
                .font(.caption2).foregroundStyle(WatchTheme.inkSecondary).multilineTextAlignment(.center)
        }
    }
}
