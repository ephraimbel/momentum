import SwiftUI

/// The "building your plan…" beat (PRD §4.1 step 3) — an anticipation moment that builds perceived
/// value. A progress ring fills toward complete around the iridescent mark while status lines cycle.
/// The flow auto-advances after a couple of seconds. Do not skip.
struct BuildingPlanView: View {
    @State private var progress = 0.0
    @State private var lineIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let lines = ["Balancing your week…", "Spacing hard efforts…",
                         "Setting your paces…", "Finalizing your plan…"]
    private let tick = Timer.publish(every: 0.65, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            Spacer()
            ZStack {
                ProgressRing(progress: progress).frame(width: 156, height: 156)
                MomentumMark().frame(width: 66, height: 66)
            }
            VStack(spacing: Theme.Space.sm) {
                Text("Building your plan")
                    .font(.system(size: Theme.FontSize.title, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text(lines[lineIndex])
                    .font(.system(size: Theme.FontSize.body))
                    .foregroundStyle(Theme.inkSecondary)
                    .id(lineIndex)
                    .transition(.opacity)
            }
            Spacer()
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 2.4)) { progress = 1 }
        }
        .onReceive(tick) { _ in
            withAnimation(.easeInOut) { lineIndex = min(lineIndex + 1, lines.count - 1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Building your plan")
    }
}
