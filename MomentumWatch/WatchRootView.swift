import SwiftUI

/// Watch home: pick a discipline to start an on-wrist session (PRD §4.10). The three GPS cardio
/// types plus strength — the v1 set that the watch can capture itself.
struct WatchRootView: View {
    private let cardio: [WorkoutType] = [.run, .ride, .walk]
    @State private var path: [WatchDestination] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Cardio") {
                    ForEach(cardio) { type in
                        NavigationLink(value: WatchDestination.cardio(type)) {
                            Label(type.title, systemImage: type.systemImage)
                        }
                    }
                }
                Section("Strength") {
                    NavigationLink(value: WatchDestination.strength) {
                        Label("Lift", systemImage: "dumbbell.fill")
                    }
                }
            }
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

/// Where a start row leads. Cardio + strength session screens fill these in over the next slices.
enum WatchDestination: Hashable {
    case cardio(WorkoutType)
    case strength
}

