import SwiftUI
import SwiftData

/// Change the plan's fundamentals after onboarding — goal, days/week, session length, equipment — and
/// rebuild. Edits are buffered and only applied on "Update", which regenerates the upcoming plan
/// (preserving your calibrated pace + cross-training via `PlanService.rebuild`). Cancel changes nothing.
struct PlanSettingsSheet: View {
    let profile: UserProfile
    var onDone: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var goal: Goal
    @State private var days: Int
    @State private var minutes: Int
    @State private var equipment: Equipment

    init(profile: UserProfile, onDone: @escaping () -> Void) {
        self.profile = profile
        self.onDone = onDone
        _goal = State(initialValue: profile.goal)
        _days = State(initialValue: profile.daysPerWeek)
        _minutes = State(initialValue: profile.sessionMinutes)
        _equipment = State(initialValue: profile.equipment)
    }

    private var lifting: Bool { profile.disciplines.contains(Discipline.strength.rawValue) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    goalSection
                    daysSection
                    sessionSection
                    if lifting { equipmentSection }
                    Text("Updating rebuilds your upcoming plan from today. Completed workouts and your calibrated pace are kept.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxl)
            }
            .background(Theme.background)
            .navigationTitle("Plan settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Update") { apply() }.fontWeight(.semibold) }
            }
        }
        .presentationBackground(Theme.background)
    }

    // MARK: Sections

    private var goalSection: some View {
        let goals: [(Goal, String, String)] = [
            (.loseFat, "Lose fat / get fit", "flame"), (.buildMuscle, "Build muscle", "figure.strengthtraining.traditional"),
            (.getStronger, "Get stronger", "dumbbell.fill"), (.raceDistance, "Run a race", "flag.checkered"),
            (.endurance, "Improve endurance", "wind"), (.stayConsistent, "Stay consistent", "calendar")]
        return section("GOAL") {
            VStack(spacing: Theme.Space.sm) {
                ForEach(goals, id: \.0) { g in
                    SelectionCard(title: g.1, systemImage: g.2, isSelected: goal == g.0) { goal = g.0 }
                }
            }
        }
    }

    private var daysSection: some View {
        section("DAYS / WEEK") {
            segmented([2, 3, 4, 5, 6], current: days, label: { "\($0)" }) { days = $0 }
        }
    }

    private var sessionSection: some View {
        section("SESSION LENGTH") {
            segmented([30, 45, 60, 75], current: minutes, label: { "\($0)m" }) { minutes = $0 }
        }
    }

    private var equipmentSection: some View {
        let opts: [(Equipment, String, String)] = [
            (.fullGym, "Full gym", "building.2"), (.dumbbellsOnly, "Dumbbells only", "dumbbell"),
            (.homeMinimal, "Home minimal", "house"), (.bodyweight, "Bodyweight", "figure.cooldown")]
        return section("EQUIPMENT") {
            VStack(spacing: Theme.Space.sm) {
                ForEach(opts, id: \.0) { o in
                    SelectionCard(title: o.1, systemImage: o.2, isSelected: equipment == o.0) { equipment = o.0 }
                }
            }
        }
    }

    // MARK: Building blocks

    private func segmented(_ values: [Int], current: Int, label: @escaping (Int) -> String, _ set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(values, id: \.self) { v in
                let on = current == v
                Button { Haptics.selection(); set(v) } label: {
                    Text(label(v))
                        .font(.rounded(Theme.FontSize.body, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .foregroundStyle(on ? Theme.background : Theme.ink)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                            if !on { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline) }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            content()
        }
    }

    private func apply() {
        profile.goal = goal
        profile.daysPerWeek = days
        profile.sessionMinutes = minutes
        profile.equipment = equipment
        PlanService.rebuild(for: profile, in: context)   // preserves calibrated pace + cross-training
        Haptics.success()
        onDone()
    }
}
