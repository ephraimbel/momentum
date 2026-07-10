import SwiftUI

/// Watch home: pick a discipline to start an on-wrist session (PRD §4.10). The three GPS cardio
/// types plus strength — the v1 set the watch can capture itself. Carousel of brand cards, each
/// with a discipline-tinted icon chip and a one-line promise of what the wrist records.
struct WatchRootView: View {
    @State private var path: [WatchDestination] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                card(.cardio(.run), title: "Run", icon: "figure.run",
                     tint: WatchTheme.accent, detail: "Pace · zones")
                card(.cardio(.ride), title: "Ride", icon: "figure.outdoor.cycle",
                     tint: Color(red: 0.62, green: 0.90, blue: 0.78), detail: "Speed · zones")
                card(.cardio(.walk), title: "Walk", icon: "figure.walk",
                     tint: Color(red: 0.84, green: 0.74, blue: 1.0), detail: "GPS · distance")
                card(.strength, title: "Lift", icon: "dumbbell.fill",
                     tint: WatchTheme.ink, detail: "Sets · rest")
            }
            .listStyle(.carousel)
            .navigationTitle { Text("momentum").foregroundStyle(WatchTheme.ink) }
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

    private func card(_ dest: WatchDestination, title: String, icon: String,
                      tint: Color, detail: String) -> some View {
        NavigationLink(value: dest) {
            StartCard(title: title, icon: icon, tint: tint, detail: detail)
        }
        .listRowBackground(Color.clear)
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

/// A start row styled as a brand card — tinted icon chip, discipline name, and what gets captured.
private struct StartCard: View {
    let title: String
    let icon: String
    let tint: Color
    let detail: String

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(tint.opacity(0.20))
                Circle().stroke(tint.opacity(0.25), lineWidth: 1)
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(WatchTheme.ink)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WatchTheme.inkTertiary)
                    .lineLimit(1)
            }
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
