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
                    Text("Lift").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(WatchTheme.ink)
                    Spacer()
                    Text("\(model.completedSets) SET\(model.completedSets == 1 ? "" : "S")")
                        .font(.system(size: 11, weight: .bold)).tracking(0.8).monospacedDigit()
                        .foregroundStyle(WatchTheme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(WatchTheme.accent.opacity(0.18)))
                }
                stepperCard(value: model.weightText, label: "Weight",
                            onMinus: { model.addWeight(-1) }, onPlus: { model.addWeight(1) })
                stepperCard(value: "\(model.reps)", label: "Reps",
                            onMinus: { model.addReps(-1) }, onPlus: { model.addReps(1) })
                Button(action: model.logSet) {
                    Label("Log set", systemImage: "checkmark")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(WatchTheme.accent)
                .foregroundStyle(.black)
                .padding(.top, 2)
            }
            .padding(.bottom, 4)
        }
    }

    private func stepperCard(value: String, label: String,
                             onMinus: @escaping () -> Void, onPlus: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            stepButton("minus", action: onMinus)
            VStack(spacing: 0) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(WatchTheme.ink).minimumScaleFactor(0.7).lineLimit(1)
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(WatchTheme.inkSecondary)
            }
            .frame(maxWidth: .infinity)
            stepButton("plus", action: onPlus)
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WatchTheme.surface))
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .bold))
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .background(Circle().fill(WatchTheme.control))
        .foregroundStyle(WatchTheme.ink)
    }

    private var restOverlay: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
            let remaining = model.restRemaining(at: ctx.date)
            let progress = min(1, max(0, remaining / model.restDurationS))
            ZStack {
                WatchTheme.bg.ignoresSafeArea()
                Circle().stroke(WatchTheme.surface, lineWidth: 9)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(WatchTheme.iridescent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 4) {
                    Text("REST").font(.system(size: 11, weight: .bold)).tracking(1.8)
                        .foregroundStyle(WatchTheme.inkSecondary)
                    Text(Formatters.duration(s: remaining))
                        .font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(WatchTheme.ink)
                    Button("Skip") { model.skipRest() }
                        .font(.system(size: 13, weight: .semibold)).tint(WatchTheme.control)
                }
                .padding(26)
            }
            .onChange(of: remaining <= 0) { _, done in if done { model.skipRest() } }
        }
    }
}
