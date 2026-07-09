import SwiftUI

/// Read-only workout detail (PRD §7.10) — reuses the summary content, pushed within History's
/// `NavigationStack`. Share is available here too.
struct WorkoutDetailView: View {
    @Bindable var workout: Workout
    var weightUnit: WeightUnit = .default()
    var distanceUnit: DistanceUnit = .auto
    @Environment(\.modelContext) private var context

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: Theme.Space.md) {
                visibilityRow
                Group {
                    if workout.type.isStrengthStyle {
                        StrengthSummaryContent(workout: workout, weightUnit: weightUnit)
                    } else if workout.type.isTimed {
                        TimedSummaryContent(workout: workout)
                    } else {
                        CardioSummaryContent(workout: workout, distanceUnit: distanceUnit)
                    }
                }
            }
            .padding(Theme.Space.md)
        }
        .onAppear {
            #if DEBUG
            // Deterministic sim verification of the time-in-zones card (simctl can't scroll).
            if ProcessInfo.processInfo.arguments.contains("--detail-scroll-zones") {
                // Two attempts — the card's id only exists once its async HR series has loaded.
                for delay in [2.0, 4.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        withAnimation { proxy.scrollTo("timeInZones", anchor: .center) }
                    }
                }
            }
            #endif
        }
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

    /// Per-workout visibility — overrides the profile default for this one workout (PRD §11).
    private var visibilityRow: some View {
        Menu {
            Picker("Visibility", selection: visibility) {
                ForEach(WorkoutPrivacy.allCases, id: \.self) { p in
                    Label(p.label, systemImage: p.icon).tag(p)
                }
            }
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: workout.privacy.icon).font(.system(size: 13, weight: .semibold))
                Text("Visible to \(workout.privacy.label.lowercased())")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.Space.md).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline))
        }
        .accessibilityLabel("Workout visibility, \(workout.privacy.label)")
    }

    private var visibility: Binding<WorkoutPrivacy> {
        Binding(get: { workout.privacy }, set: { workout.privacy = $0; try? context.save() })
    }
}
