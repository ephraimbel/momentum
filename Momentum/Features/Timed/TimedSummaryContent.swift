import SwiftUI

/// Read-only summary for a timed activity — the duration hero plus optional effort and note. Shared by
/// `TimedSaveView` (editing) and `WorkoutDetailView` (history), mirroring Cardio/StrengthSummaryContent.
struct TimedSummaryContent: View {
    let workout: Workout
    var showsHeader: Bool = true

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            if showsHeader { header }

            VStack(spacing: Theme.Space.xs) {
                Text(Formatters.duration(s: workout.durationS))
                    .font(.display(Theme.FontSize.heroNumber, weight: .black))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Text("DURATION")
                    .font(.rounded(Theme.FontSize.label, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.inkTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.lg)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))

            if let effort = workout.perceivedEffort {
                detailRow("Effort", "\(effort) / 10")
            }
            if !workout.note.isEmpty {
                Text(workout.note)
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Space.sm) {
            ZStack {
                Circle().fill(LinearGradient(colors: Theme.iridescent.map { $0.opacity(0.25) },
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 72, height: 72)
                Image(systemName: workout.type.systemImage)
                    .font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.ink)
            }
            Text(workout.title.isEmpty ? workout.type.title : workout.title)
                .font(.display(Theme.FontSize.title, weight: .black)).foregroundStyle(Theme.ink)
            Text(workout.startedAt.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            Spacer()
            Text(value).font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
    }
}
