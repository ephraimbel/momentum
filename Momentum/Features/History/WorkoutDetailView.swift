import SwiftUI

/// Read-only workout detail (PRD §7.10) — reuses the summary content, pushed within History's
/// `NavigationStack`. Share is available here too.
struct WorkoutDetailView: View {
    let workout: Workout
    var weightUnit: WeightUnit = .default()
    var distanceUnit: DistanceUnit = .auto

    var body: some View {
        ScrollView {
            Group {
                if workout.type == .strength {
                    StrengthSummaryContent(workout: workout, weightUnit: weightUnit)
                } else {
                    CardioSummaryContent(workout: workout, distanceUnit: distanceUnit)
                }
            }
            .padding(Theme.Space.md)
        }
        .background(Theme.background)
        .navigationTitle(workout.type.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareButton(workout: workout, weightUnit: weightUnit, distanceUnit: distanceUnit)
            }
        }
    }
}
