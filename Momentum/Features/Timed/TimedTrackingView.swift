import SwiftUI
import SwiftData

/// The live timed-activity screen — a calm, full-bleed stopwatch for sports that are just duration
/// (tennis, yoga, …). Start is automatic on appear; pause/resume and finish below; an X discards.
struct TimedTrackingView: View {
    let type: WorkoutType
    let container: ModelContainer
    var onFinish: (UUID?) -> Void

    @State private var vm: TimedTrackingViewModel?
    @State private var confirmDiscard = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let vm { content(vm) } else { ProgressView() }
        }
        .task {
            guard vm == nil else { return }
            let model = TimedTrackingViewModel(type: type, container: container)
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
        .confirmationDialog("Discard this \(type.title.lowercased())?",
                            isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { onFinish(vm.discard()) }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("This won't be saved to your history.")
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
            .accessibilityLabel("Discard")
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
                    .fill(vm.isPaused ? Theme.inkTertiary : Theme.route)
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
