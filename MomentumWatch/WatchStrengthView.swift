import SwiftUI

/// On-wrist strength logger (PRD §4.10): weight/reps steppers + a one-tap "Log set" that fires a
/// haptic and starts the rest countdown. The rest ring takes over the screen until it elapses or is
/// skipped, mirroring the phone's rest timer.
struct WatchStrengthView: View {
    @State private var model = WatchStrengthModel()

    var body: some View {
        ZStack {
            logger
            if model.restEndsAt != nil { restOverlay }
        }
        .navigationTitle("Lift")
        .onAppear {
            #if DEBUG
            model.seedDemoIfRequested()
            #endif
        }
    }

    private var logger: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack {
                    Text("Lift").font(.headline).foregroundStyle(WatchTheme.ink)
                    Spacer()
                    Text("\(model.completedSets) set\(model.completedSets == 1 ? "" : "s")")
                        .font(.caption2.monospacedDigit()).foregroundStyle(WatchTheme.inkSecondary)
                }
                stepperRow(value: model.weightText, label: "",
                           onMinus: { model.addWeight(-1) }, onPlus: { model.addWeight(1) })
                stepperRow(value: "\(model.reps)", label: "reps",
                           onMinus: { model.addReps(-1) }, onPlus: { model.addReps(1) })
                Button(action: model.logSet) {
                    Text("Log set").font(.headline).frame(maxWidth: .infinity)
                }
                .tint(WatchTheme.accent)
                .padding(.top, 2)
            }
        }
    }

    private func stepperRow(value: String, label: String,
                            onMinus: @escaping () -> Void, onPlus: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: onMinus) { Image(systemName: "minus") }
                .tint(WatchTheme.surface)
            VStack(spacing: 0) {
                Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(WatchTheme.ink)
                if !label.isEmpty {
                    Text(label.uppercased()).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(WatchTheme.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            Button(action: onPlus) { Image(systemName: "plus") }
                .tint(WatchTheme.surface)
        }
        .font(.title3)
    }

    private var restOverlay: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
            let remaining = model.restRemaining(at: ctx.date)
            let progress = min(1, max(0, remaining / model.restDurationS))
            ZStack {
                WatchTheme.bg.ignoresSafeArea()
                Circle()
                    .stroke(WatchTheme.surface, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(WatchTheme.iridescent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 4) {
                    Text("REST").font(.system(size: 11, weight: .bold)).tracking(1.5)
                        .foregroundStyle(WatchTheme.inkSecondary)
                    Text(Formatters.duration(s: remaining))
                        .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(WatchTheme.ink)
                    Button("Skip") { model.skipRest() }
                        .font(.caption2).tint(WatchTheme.surface)
                }
                .padding(24)
            }
            .onChange(of: remaining <= 0) { _, done in if done { model.skipRest() } }
        }
    }
}
