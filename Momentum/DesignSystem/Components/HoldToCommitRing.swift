import SwiftUI

/// A press-and-hold commitment control — the onboarding "investment" beat (docs/ONBOARDING-MOTION-PLAN
/// §4). The user holds; the **iridescent ring fills** (earned accent), a haptic ramps as it goes, and
/// at full it pops and fires `onCommit`. Releasing early springs it back to empty. This is the Opal
/// "fist-bump" commitment device rendered in momentum's identity — the ring is the same earned
/// iridescence as the route, the progress bar, and the reveal. Honors Reduce Motion (tap to commit,
/// static ring).
struct HoldToCommitRing: View {
    var size: CGFloat = 220
    var lineWidth: CGFloat = 14
    var duration: Double = 1.2
    var onCommit: () -> Void

    @State private var fill = 0.0
    @State private var pressing = false
    @State private var committed = false
    @State private var holdTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ring
            .frame(width: size, height: size)
            .contentShape(Circle())
            .modifier(CommitInteraction(reduceMotion: reduceMotion,
                                        onPress: beginHold, onRelease: endHold, onTap: commitInstantly))
            .accessibilityElement()
            .accessibilityLabel("Hold to commit")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { commitInstantly() }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Theme.hairline, lineWidth: lineWidth)
            IridescentView(intensity: 0.95)
                .mask {
                    Circle()
                        .trim(from: 0, to: max(0.0001, min(1, fill)))
                        .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            center
        }
        .scaleEffect(pressing ? 0.96 : (committed ? 1.04 : 1))
        .animation(Motion.lively, value: pressing)
        .animation(Motion.lively, value: committed)
    }

    @ViewBuilder
    private var center: some View {
        if committed {
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.26, weight: .bold))
                .foregroundStyle(Theme.ink)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        } else {
            Text("HOLD")
                .font(.rounded(Theme.FontSize.headline, weight: .bold))
                .tracking(2)
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    // MARK: Interaction

    private func beginHold() {
        guard !pressing, !committed else { return }
        pressing = true
        withAnimation(.linear(duration: duration)) { fill = 1 }
        holdTask = Task { @MainActor in
            let steps = 6
            for _ in 0..<steps {
                try? await Task.sleep(for: .seconds(duration / Double(steps)))
                if Task.isCancelled { return }
                Haptics.light()           // the ramp — a heartbeat that quickens toward commitment
            }
            if !Task.isCancelled { commit() }
        }
    }

    private func endHold() {
        guard pressing, !committed else { return }
        pressing = false
        holdTask?.cancel(); holdTask = nil
        withAnimation(Motion.lively) { fill = 0 }
    }

    private func commit() {
        committed = true
        pressing = false
        holdTask = nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { fill = 1 }
        Haptics.celebration()
        onCommit()
    }

    private func commitInstantly() {     // Reduce Motion / accessibility path
        guard !committed else { return }
        committed = true
        fill = 1
        Haptics.celebration()
        onCommit()
    }
}

/// Press-and-hold for the full path; a plain tap for Reduce Motion / assistive use.
private struct CommitInteraction: ViewModifier {
    let reduceMotion: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    let onTap: () -> Void

    func body(content: Content) -> some View {
        if reduceMotion {
            content.onTapGesture { onTap() }
        } else {
            content.gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onPress() }
                    .onEnded { _ in onRelease() }
            )
        }
    }
}

#Preview {
    ZStack {
        Color.white.ignoresSafeArea()
        HoldToCommitRing(size: 220) {}
    }
}
