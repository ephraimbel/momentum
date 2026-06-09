import SwiftUI

/// The global quick-action button — a black circular FAB in the bottom-right, deliberately *outside*
/// the liquid-glass tab bar. Tap to expand a clean, animated menu of activities to start instantly
/// (run / walk / ride / hike / strength). The "+" rotates to "×"; options spring up over a soft
/// scrim. Honors Reduce Motion (crossfade instead of spring).
struct QuickActionFAB: View {
    let launcher: WorkoutLauncher

    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let actions: [WorkoutType] = [.run, .walk, .ride, .hike, .strength]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isOpen {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { toggle() }
            }
            VStack(alignment: .trailing, spacing: Theme.Space.sm) {
                if isOpen {
                    ForEach(actions) { type in
                        actionRow(type)
                            .transition(.scale(scale: 0.5, anchor: .bottomTrailing).combined(with: .opacity))
                    }
                }
                fab
            }
            .padding(.trailing, Theme.Space.md)
            .padding(.bottom, 26)   // align the FAB's center with the floating tab pill
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .ignoresSafeArea(.container, edges: .bottom)   // position from the physical bottom, like the tab bar
    }

    private var fab: some View {
        Button { toggle() } label: {
            ZStack {
                Circle().fill(Theme.ink)
                    .frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
                Image(systemName: "plus")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(Theme.background)
                    .rotationEffect(.degrees(isOpen ? 45 : 0))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? "Close quick actions" : "Quick start a workout")
    }

    private func actionRow(_ type: WorkoutType) -> some View {
        Button { select(type) } label: {
            HStack(spacing: Theme.Space.sm) {
                Text(type.title)
                    .font(.rounded(Theme.FontSize.body, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, Theme.Space.md).padding(.vertical, 9)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().stroke(Theme.hairline))
                ZStack {
                    Circle().fill(Theme.surface)
                    Circle().stroke(Theme.hairline)
                    Image(systemName: type.systemImage)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.ink)
                }
                .frame(width: 50, height: 50)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start \(type.title.lowercased())")
    }

    private func toggle() {
        Haptics.light()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2)
                                   : .spring(response: 0.38, dampingFraction: 0.78)) {
            isOpen.toggle()
        }
    }

    private func select(_ type: WorkoutType) {
        Haptics.selection()
        withAnimation(.easeOut(duration: 0.2)) { isOpen = false }
        if type == .strength { launcher.startStrength() } else { launcher.startCardio(type) }
    }
}
