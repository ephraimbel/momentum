import SwiftUI

/// On-wrist strength logger (PRD §4.10): the Digital Crown lands the weight (haptic detent per
/// plate step — the fiddly number gets the precise input), buttons cover reps, one tap logs the
/// set and starts the rest countdown. The rest ring owns the screen until it elapses or is
/// skipped, and its last three seconds tick on the wrist so eyes stay on the bar.
struct WatchStrengthView: View {
    @State private var model = WatchStrengthModel()
    @State private var crownWeight: Double = 0
    @State private var crownSynced = false

    var body: some View {
        ZStack {
            logger
            if model.restEndsAt != nil { restOverlay }
        }
        .navigationTitle("Lift")
        // The rest ring owns the screen — no back chevron floating over it.
        .toolbar(model.restEndsAt != nil ? .hidden : .automatic, for: .navigationBar)
        .onAppear {
            #if DEBUG
            model.seedDemoIfRequested()
            #endif
            crownWeight = model.weightDisplayValue
            crownSynced = true
        }
    }

    private var logger: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack {
                    Text("\(model.completedSets) SET\(model.completedSets == 1 ? "" : "S")")
                        .font(.system(size: 11, weight: .bold)).tracking(0.8).monospacedDigit()
                        .foregroundStyle(WatchTheme.accent)
                        .contentTransition(.numericText(countsDown: false))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(WatchTheme.accent.opacity(0.18)))
                        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: model.completedSets)
                    Spacer()
                }
                stepperCard(value: model.weightText, label: "Weight · crown",
                            onMinus: { bumpWeight(-1) }, onPlus: { bumpWeight(1) })
                    .focusable(true)
                    .digitalCrownRotation($crownWeight,
                                          from: 0, through: 1500,
                                          by: model.weightStepDisplay,
                                          sensitivity: .medium,
                                          isContinuous: false,
                                          isHapticFeedbackEnabled: true)
                    .onChange(of: crownWeight) { _, value in
                        guard crownSynced else { return }
                        model.setWeightDisplay(value)
                    }
                stepperCard(value: "\(model.reps)", label: "Reps",
                            onMinus: { model.addReps(-1) }, onPlus: { model.addReps(1) })
                Button(action: model.logSet) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .symbolEffect(.bounce, value: model.completedSets)
                        Text("Log set")
                    }
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
                    .font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(WatchTheme.ink).minimumScaleFactor(0.7).lineLimit(1)
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(WatchTheme.inkSecondary)
            }
            .frame(maxWidth: .infinity)
            stepButton("plus", action: onPlus)
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WatchTheme.surface))
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .bold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .background(Circle().fill(WatchTheme.control))
        .foregroundStyle(WatchTheme.ink)
    }

    private func bumpWeight(_ direction: Double) {
        model.addWeight(direction)
        crownSynced = false
        crownWeight = model.weightDisplayValue
        crownSynced = true
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
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.smooth(duration: 0.3), value: Int(remaining))
                    Button("Skip") { model.skipRest() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WatchTheme.ink)
                        .buttonStyle(.bordered)
                        .tint(WatchTheme.control)
                        .fixedSize()
                }
                .padding(26)
            }
            // The endgame ticks on the wrist (3·2·1) and rest closes with the GO tap — eyes stay
            // on the bar, not the dial.
            .onChange(of: Int(remaining.rounded(.up))) { _, second in
                if (1...3).contains(second) { WatchHaptics.tick() }
            }
            .onChange(of: remaining <= 0) { _, done in
                if done {
                    WatchHaptics.go()
                    model.skipRest()
                }
            }
        }
    }
}
