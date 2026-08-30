import SwiftUI
import SwiftData

/// The live timed-activity screen — a calm, full-bleed stopwatch for sports that are just duration
/// (tennis, yoga, …). Start is automatic on appear; pause/resume and finish below; the X confirms
/// leaving and offers Finish & save once there's a minute on the clock — never a silent loss.
struct TimedTrackingView: View {
    let type: WorkoutType
    let container: ModelContainer
    var onFinish: (UUID?) -> Void

    @State private var vm: TimedTrackingViewModel?
    @State private var confirmDiscard = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(Services.self) private var services

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let vm { content(vm) } else { ProgressView() }
        }
        .task {
            guard vm == nil else { return }
            // Voice coach is Pro (PRD §10) — pass it only when entitled, else nil (silent).
            let voice = services.paywall.isEntitled(to: .voiceCoach) ? services.voiceCoach : nil
            let model = TimedTrackingViewModel(type: type, container: container, voice: voice)
            model.start()
            vm = model
            if !reduceMotion { withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulse = true } }
        }
    }

    private func content(_ vm: TimedTrackingViewModel) -> some View {
        VStack(spacing: 0) {
            header
            Spacer()
            elapsed(vm)
            Spacer()
            controls(vm)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.lg)
        .confirmationDialog("End this \(type.title.lowercased())?",
                            isPresented: $confirmDiscard, titleVisibility: .visible) {
            // Leaving must never silently cost the session (mirrors the strength X): a minute or
            // more on the clock earns a save path; under that there's nothing worth keeping.
            if vm.elapsed >= 60 {
                Button("Finish & save") { onFinish(vm.finish()) }
            }
            Button("Discard", role: .destructive) { onFinish(vm.discard()) }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text(vm.elapsed >= 60
                 ? "Save your \(Formatters.duration(s: vm.elapsed)) so far, or discard it."
                 : "Nothing to save yet. Discard this \(type.title.lowercased())?")
        }
    }

    private var header: some View {
        HStack {
            Button { confirmDiscard = true } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.surface))
            }
            .accessibilityLabel("End workout")
            Spacer()
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: type.systemImage).font(.system(size: 15, weight: .bold))
                Text(type.title).font(.rounded(Theme.FontSize.body, weight: .bold))
            }
            .foregroundStyle(Theme.ink)
            Spacer()
            Color.clear.frame(width: 36, height: 36)   // balance the X
        }
    }

    private func elapsed(_ vm: TimedTrackingViewModel) -> some View {
        VStack(spacing: Theme.Space.sm) {
            Text(Formatters.duration(s: vm.elapsed))
                .font(.display(72, weight: .black))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
            HStack(spacing: 7) {
                Circle()
                    .fill(vm.isPaused ? Theme.inkTertiary : Theme.purple)
                    .frame(width: 8, height: 8)
                    .opacity(vm.isPaused ? 1 : (pulse ? 0.4 : 1))
                Text(vm.isPaused ? "PAUSED" : "RECORDING")
                    .font(.rounded(Theme.FontSize.label, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
    }

    private func controls(_ vm: TimedTrackingViewModel) -> some View {
        VStack(spacing: Theme.Space.sm) {
            OversizedButton(title: vm.isPaused ? "Resume" : "Pause",
                            systemImage: vm.isPaused ? "play.fill" : "pause.fill",
                            kind: .outline) { vm.togglePause() }
            OversizedButton(title: "Finish", systemImage: "checkmark") { onFinish(vm.finish()) }
        }
    }
}
