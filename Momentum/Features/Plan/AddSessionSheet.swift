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
    @State private var sport: WorkoutType = .run
    @State private var goalKind: GoalKind = .open
    @State private var goalValue = 5.0          // km/mi for distance
    @State private var goalMinutes = 30.0       // minutes for timed sports
    @State private var showSportPicker = false

    enum GoalKind: Hashable { case open, distance }
    private let distanceUnit: DistanceUnit = .auto
    private var isGPS: Bool { sport.isGPS }
    private var isTimed: Bool { sport.isTimed }
    private var unitLabel: String { distanceUnit.resolved() == .imperial ? "mi" : "km" }

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
                    if isGPS { goalSection } else { durationSection }   // strength-style gets a duration too
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
        .sheet(isPresented: $showSportPicker) {
            SportPicker(selection: $sport) { showSportPicker = false }
        }
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
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.sm) {
                        ForEach(dayStrip, id: \.self) { dayBadge($0).id($0) }
                    }
                    .padding(.vertical, 2)
                }
                // Bring the pre-selected day into view — it can start off-screen (a future Pro week, or
                // an earlier-this-week rest day), which is exactly when a hidden selection goes unnoticed.
                .onAppear { proxy.scrollTo(Calendar.current.startOfDay(for: date), anchor: .center) }
            }
        }
    }

    /// The day strip always spans from the earlier of {today, the pre-selected day} through at least
    /// two weeks out — so a `defaultDate` outside today…+13 (future week / past rest day) is still
    /// shown and selectable, never silently applied on a hidden day. Capped so it can't run away.
    private var dayStrip: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let def = cal.startOfDay(for: defaultDate)
        let first = min(today, def)
        let last = max(cal.date(byAdding: .day, value: 13, to: today) ?? today, def)
        let span = min((cal.dateComponents([.day], from: first, to: last).day ?? 13) + 1, 70)
        return (0..<max(1, span)).compactMap { cal.date(byAdding: .day, value: $0, to: first) }
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

    // MARK: Activity — any sport via the full picker

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            label("Activity")
            Button { Haptics.light(); showSportPicker = true } label: {
                HStack(spacing: Theme.Space.md) {
                    Image(systemName: sport.systemImage).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 44)
                        .background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sport.title).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                        Text("Tap to change").font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                }
                .padding(Theme.Space.md)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                    RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Goal — distance for GPS sports

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

    // MARK: Goal — duration for timed sports (swim, row, yoga, tennis…)

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            label("Goal")
            HStack(spacing: Theme.Space.sm) {
                goalButton(.open, "Open")
                goalButton(.distance, "Duration")
            }
            if goalKind == .distance { minutesStepper }
        }
    }

    private var minutesStepper: some View {
        HStack(spacing: Theme.Space.lg) {
            Spacer()
            stepBtn("minus") { goalMinutes = max(5, goalMinutes - 5) }
            VStack(spacing: 0) {
                Text("\(Int(goalMinutes))")
                    .font(.display(40, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text("MIN").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            }.frame(minWidth: 96)
            stepBtn("plus") { goalMinutes += 5 }
            Spacer()
        }
        .padding(.top, Theme.Space.xs)
        .animation(.snappy(duration: 0.2), value: goalMinutes)
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
        s.sportType = sport.rawValue
        s.discipline = sport.discipline      // coaching bucket; sportType carries the exact sport
        s.status = .planned
        if isGPS {
            s.runType = .easy
            if goalKind == .distance {
                s.targetDistanceM = goalValue * (distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000)
            }
        } else if goalKind == .distance {
            // Any non-GPS sport (timed OR strength-style) sets a duration goal — so a hand-added
            // strength session reads as real work ("Strength · 45 min") instead of an empty stub.
            s.targetDurationS = goalMinutes * 60
        }
        plan.sessions.append(s)
        context.insert(s)
        try? context.save()
        Haptics.success()
        onDone()
    }
}
