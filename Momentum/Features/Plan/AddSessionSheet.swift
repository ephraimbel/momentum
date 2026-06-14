import SwiftUI
import SwiftData

/// Plan your own session: pick a day, a discipline, and (for cardio) a distance goal. Inserts a
/// `PlannedSession` into the plan so it shows up on Plan and Today like any AI-prescribed one.
/// Styled to match the app's bespoke language — big display header, day strip, `SelectionCard`s,
/// a custom goal toggle, and a pinned `OversizedButton` — instead of stock iOS controls.
struct AddSessionSheet: View {
    let plan: TrainingPlan
    var defaultDate: Date = Date()
    var onDone: () -> Void

    @Environment(\.modelContext) private var context

    @State private var date: Date
    @State private var discipline: Discipline = .running
    @State private var goalKind: GoalKind = .open
    @State private var goalValue = 5.0

    enum GoalKind: Hashable { case open, distance }
    private let distanceUnit: DistanceUnit = .auto
    private var isCardio: Bool { discipline != .strength }
    private var unitLabel: String { distanceUnit.resolved() == .imperial ? "mi" : "km" }
    private let disciplines: [Discipline] = [.running, .cycling, .walking, .strength]

    init(plan: TrainingPlan, defaultDate: Date = Date(), onDone: @escaping () -> Void) {
        self.plan = plan
        self.defaultDate = defaultDate
        self.onDone = onDone
        _date = State(initialValue: Calendar.current.startOfDay(for: defaultDate))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    daySection
                    activitySection
                    if isCardio { goalSection }
                }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, Theme.Space.sm)
                .padding(.bottom, Theme.Space.xl)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) { addBar }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Plan a session")
                .font(.display(30, weight: .black))
                .foregroundStyle(Theme.ink)
            Spacer()
            Button { onDone() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.surface))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.lg)
        .padding(.bottom, Theme.Space.md)
    }

    // MARK: Day strip

    private var daySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            label("Day")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(next14, id: \.self) { dayBadge($0) }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var next14: [Date] {
        let start = Calendar.current.startOfDay(for: Date())
        return (0..<14).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
    }

    private func dayBadge(_ day: Date) -> some View {
        let on = Calendar.current.isDate(day, inSameDayAs: date)
        return Button { Haptics.selection(); date = day } label: {
            VStack(spacing: 3) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.rounded(Theme.FontSize.label, weight: .bold))
                Text(day.formatted(.dateTime.day()))
                    .font(.display(20, weight: .heavy)).monospacedDigit()
            }
            .foregroundStyle(on ? Theme.background : Theme.ink)
            .frame(width: 54, height: 66)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? Theme.ink : Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(on ? Color.clear : Theme.hairline)
            }
            .scaleEffect(on ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
    }

    // MARK: Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            label("Activity")
            ForEach(disciplines, id: \.self) { d in
                SelectionCard(title: name(d), systemImage: icon(d), isSelected: discipline == d) {
                    discipline = d
                }
            }
        }
    }

    // MARK: Goal (cardio only)

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            label("Goal")
            HStack(spacing: Theme.Space.sm) {
                goalButton(.open, "Open")
                goalButton(.distance, "Distance")
            }
            if goalKind == .distance { distanceStepper }
        }
    }

    private func goalButton(_ kind: GoalKind, _ title: String) -> some View {
        let on = goalKind == kind
        return Button { Haptics.selection(); goalKind = kind } label: {
            Text(title)
                .font(.rounded(Theme.FontSize.body, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 52)
                .foregroundStyle(on ? Theme.background : Theme.ink)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? Theme.ink : Theme.surface)
                    RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(on ? Color.clear : Theme.hairline)
                }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
    }

    private var distanceStepper: some View {
        HStack(spacing: Theme.Space.lg) {
            Spacer()
            stepBtn("minus") { goalValue = max(0.5, goalValue - 0.5) }
            VStack(spacing: 0) {
                Text(goalValue.formatted(.number.precision(.fractionLength(goalValue == goalValue.rounded() ? 0 : 1))))
                    .font(.display(40, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text(unitLabel.uppercased()).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            }.frame(minWidth: 96)
            stepBtn("plus") { goalValue += 0.5 }
            Spacer()
        }
        .padding(.top, Theme.Space.xs)
        .animation(.snappy(duration: 0.2), value: goalValue)
    }

    private func stepBtn(_ s: String, _ a: @escaping () -> Void) -> some View {
        Button { Haptics.light(); a() } label: {
            Image(systemName: s).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 52, height: 52).background { Circle().fill(Theme.surface); Circle().stroke(Theme.hairline) }
        }.buttonStyle(.plain)
    }

    // MARK: Add bar

    private var addBar: some View {
        OversizedButton(title: "Add to plan", systemImage: "plus") { add() }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.sm)
            .momentumGlass(in: Rectangle(), stroke: false)
    }

    // MARK: Helpers

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
    private func name(_ d: Discipline) -> String {
        switch d { case .running: "Run"; case .cycling: "Ride"; case .walking: "Walk"; case .strength: "Strength" }
    }
}
