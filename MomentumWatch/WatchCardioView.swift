import SwiftUI

/// On-wrist live cardio (PRD §4.10): big elapsed clock + distance, pace/speed, heart rate, and
/// energy, with pause/end. Numbers come from `WatchCardioModel` (HealthKit live workout); the clock
/// ticks via `TimelineView`. Real HR/distance need a physical Watch — on the sim the layout renders
/// and the clock runs while sensor values stay at zero.
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

    private func live(_ model: WatchCardioModel) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Formatters.duration(s: model.elapsed))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(WatchTheme.ink)
                        .padding(.top, 2)

                    metric(heroValue(model), heroLabel)
                    metric(Formatters.distance(meters: model.distanceM, unit: unit), "Distance")
                    metric("\(model.heartRateBPM)", "BPM", accent: true)
                    metric("\(Int(model.activeEnergyKcal))", "Active cal")

                    controls(model)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func controls(_ model: WatchCardioModel) -> some View {
        HStack(spacing: 10) {
            Button {
                model.togglePause()
            } label: {
                Image(systemName: model.paused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(WatchTheme.surface)

            Button {
                guard !ending else { return }
                ending = true
                Task { await model.end(); dismiss() }
            } label: {
                Image(systemName: "stop.fill").frame(maxWidth: .infinity)
            }
            .tint(.red)
        }
        .font(.title3)
        .padding(.top, 6)
    }

    private func metric(_ value: String, _ label: String, accent: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(accent ? WatchTheme.accent : WatchTheme.ink)
            Spacer(minLength: 6)
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(WatchTheme.inkSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
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
