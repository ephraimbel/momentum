import SwiftUI

/// The "building your plan…" beat (PRD §4.1 step 3) — iridescent threads weaving a week into
/// place. Builds perceived value; do not skip. The flow auto-advances after a couple of seconds.
struct BuildingPlanView: View {
    @State private var appear = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            Spacer()
            ZStack {
                IridescentView(intensity: 0.7)
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sheet))
                    .scaleEffect(appear || reduceMotion ? 1 : 0.85)
                    .opacity(appear || reduceMotion ? 1 : 0.4)
            }
            Text("Building your plan…")
                .font(.system(size: Theme.FontSize.title, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("Weaving your week around your goals and recovery.")
                .font(.system(size: Theme.FontSize.body))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { appear = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Building your plan")
    }
}
