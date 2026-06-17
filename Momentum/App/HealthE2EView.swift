#if DEBUG
import SwiftUI
import SwiftData

/// Sim-only end-to-end probe for the Apple Health import (launch with `--health-e2e`). It requests
/// Health authorization, seeds a few synthetic *foreign* workouts (run / ride / strength), runs the
/// live import against the real `HKHealthStore`, and surfaces a machine-readable result. A UITest
/// taps the system auth sheet, then reads `health-e2e-status` — proving the round-trip without a
/// physical Garmin. Never reachable in release builds.
struct HealthE2EView: View {
    @Environment(Services.self) private var services
    @Environment(\.modelContext) private var context
    @Query private var workouts: [Workout]
    @State private var status = "starting…"

    var body: some View {
        VStack(spacing: 16) {
            Text("Health Import E2E")
                .font(.headline)
            Text(status)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .accessibilityIdentifier("health-e2e-status")
        }
        .task {
            let granted = await services.health.requestAuthorization()
            guard granted else { status = "RESULT auth=denied"; return }
            await (services.health as? HealthService)?.seedSyntheticHealthWorkouts()
            let imported = await services.health.importExternalWorkouts(into: context, since: nil)
            let summary = workouts
                .sorted { $0.startedAt > $1.startedAt }
                .prefix(3)
                .map { "\($0.type.rawValue):\(Int(($0.gps?.distanceM ?? 0)))m" }
                .joined(separator: " ")
            status = "RESULT auth=ok imported=\(imported) total=\(workouts.count)\n\(summary)"
        }
    }
}
#endif
