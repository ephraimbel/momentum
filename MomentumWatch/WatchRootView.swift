import SwiftUI

/// Watch home: pick a discipline to start an on-wrist session (PRD §4.10). The three GPS cardio
/// types plus strength — the v1 set the watch can capture itself. Each is a tappable brand card
/// (icon + name) rather than a plain row, for a premium first glance.
struct WatchRootView: View {
    private let cardio: [WorkoutType] = [.run, .ride, .walk]
    @State private var path: [WatchDestination] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(cardio) { type in
                    NavigationLink(value: WatchDestination.cardio(type)) {
                        StartCard(title: type.title, icon: type.systemImage, tint: WatchTheme.accent)
                    }
                    .listRowBackground(Color.clear)
                }
                NavigationLink(value: WatchDestination.strength) {
                    StartCard(title: "Lift", icon: "dumbbell.fill", tint: WatchTheme.accent)
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.carousel)
            .navigationTitle("momentum")
            .navigationDestination(for: WatchDestination.self) { dest in
                switch dest {
                case .cardio(let type): WatchCardioView(type: type)
                case .strength: WatchStrengthView()
                }
            }
        }
        .tint(WatchTheme.accent)
        .onAppear(perform: applyLaunchDestination)
    }

    /// DEBUG deep link for deterministic verification on the watch sim (taps are unreliable there):
    /// `--watch-screen=run|ride|walk|strength` pushes that destination at launch. Mirrors the phone's
    /// `--ui-test-route` / `--seed-demo` pattern.
    private func applyLaunchDestination() {
        #if DEBUG
        guard path.isEmpty,
              let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--watch-screen=") })
        else { return }
        let value = String(arg.dropFirst("--watch-screen=".count))
        if value == "strength" { path = [.strength] }
        else if let type = WorkoutType(rawValue: value) { path = [.cardio(type)] }
        #endif
    }
}

/// A start row styled as a brand card — an accent icon chip + the discipline name.
private struct StartCard: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.22))
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
            }
            .frame(width: 40, height: 40)
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(WatchTheme.ink)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(WatchTheme.surface))
    }
}

/// Where a start row leads.
enum WatchDestination: Hashable {
    case cardio(WorkoutType)
    case strength
}
