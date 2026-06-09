import SwiftUI
import SwiftData

/// Plan your own session: pick a day, a discipline, and (for cardio) a distance goal. Inserts a
/// `PlannedSession` into the plan so it shows up on Plan and Today like any AI-prescribed one.
struct AddSessionSheet: View {
    let plan: TrainingPlan
    var defaultDate: Date = Date()
    var onDone: () -> Void

    @Environment(\.modelContext) private var context

    @State private var date: Date
    @State private var discipline: Discipline = .running
    @State private var goalKind: GoalKind = .open
    @State private var goalValue = 5.0

    enum GoalKind { case open, distance }
    private let distanceUnit: DistanceUnit = .auto
    private var isCardio: Bool { discipline != .strength }
    private var unitLabel: String { distanceUnit.resolved() == .imperial ? "mi" : "km" }

    init(plan: TrainingPlan, defaultDate: Date = Date(), onDone: @escaping () -> Void) {
        self.plan = plan
        self.defaultDate = defaultDate
        self.onDone = onDone
        _date = State(initialValue: defaultDate)
    }

    private let disciplines: [Discipline] = [.running, .cycling, .walking, .strength]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    DatePicker("Day", selection: $date, displayedComponents: .date)
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))

                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        label("Activity")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.Space.sm) {
                                ForEach(disciplines, id: \.self) { d in
                                    disciplinePill(d)
                                }
                            }
                        }
                    }

                    if isCardio {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            label("Goal")
                            HStack {
                                Picker("", selection: $goalKind) {
                                    Text("Open").tag(GoalKind.open); Text("Distance").tag(GoalKind.distance)
                                }.pickerStyle(.segmented).frame(width: 180)
                                Spacer()
                            }
                            if goalKind == .distance { distanceStepper }
                        }
                    }
                }
                .padding(Theme.Space.lg)
            }
            .background(Theme.background)
            .navigationTitle("Add session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { add() }.fontWeight(.bold) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
    }

    private func disciplinePill(_ d: Discipline) -> some View {
        let on = discipline == d
        return Button { Haptics.selection(); discipline = d } label: {
            HStack(spacing: 6) {
                Image(systemName: icon(d)).font(.system(size: 14, weight: .bold))
                Text(label(d)).font(.rounded(Theme.FontSize.body, weight: .bold))
            }
            .foregroundStyle(on ? Theme.background : Theme.ink)
            .padding(.horizontal, Theme.Space.md).padding(.vertical, 10)
            .background {
                Capsule().fill(on ? Theme.ink : Theme.surface)
                Capsule().stroke(Theme.hairline)
            }
        }
        .buttonStyle(.plain)
    }

    private var distanceStepper: some View {
        HStack(spacing: Theme.Space.lg) {
            stepBtn("minus") { goalValue = max(0.5, goalValue - 0.5) }
            VStack(spacing: 0) {
                Text(goalValue.formatted(.number.precision(.fractionLength(goalValue == goalValue.rounded() ? 0 : 1))))
                    .font(.display(28, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                Text(unitLabel.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            }.frame(minWidth: 80)
            stepBtn("plus") { goalValue += 0.5 }
            Spacer()
        }
    }

    private func stepBtn(_ s: String, _ a: @escaping () -> Void) -> some View {
        Button { Haptics.light(); a() } label: {
            Image(systemName: s).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44).background { Circle().fill(Theme.surface); Circle().stroke(Theme.hairline) }
        }.buttonStyle(.plain)
    }

    private func label(_ t: String) -> some View {
        Text(t.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
    }

    private func add() {
        let s = PlannedSession()
        s.date = Calendar.current.startOfDay(for: date)
        s.discipline = discipline
        s.status = .planned
        if isCardio {
            s.runType = .easy
            if goalKind == .distance {
                s.targetDistanceM = goalValue * (distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000)
            }
        }
        plan.sessions.append(s)
        context.insert(s)
        try? context.save()
        Haptics.success()
        onDone()
    }

    private func icon(_ d: Discipline) -> String {
        switch d { case .running: "figure.run"; case .cycling: "bicycle"; case .walking: "figure.walk"; case .strength: "dumbbell.fill" }
    }
    private func label(_ d: Discipline) -> String {
        switch d { case .running: "Run"; case .cycling: "Ride"; case .walking: "Walk"; case .strength: "Strength" }
    }
}
