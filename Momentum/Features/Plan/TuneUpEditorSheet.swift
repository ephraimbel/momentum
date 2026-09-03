import SwiftUI

/// One tune-up race, edited in place (2026-09-03): pick it from the catalog or set the distance and
/// date by hand, choose whether to race it or train through it, and optionally give it a time.
/// Mirrors the Plan Settings race section's grammar (raised cards, `SelectionCard`, the same
/// catalog picker), and enforces the timing rules inline so Save never fails on them.
struct TuneUpEditorSheet: View {
    /// Nil = adding a new one.
    let event: TuneUpEvent?
    /// Where the date may land (a week out at the earliest, three days before the goal at the latest).
    let range: ClosedRange<Date>
    /// The season's other tune-ups, for the spacing rule.
    let others: [TuneUpEvent]
    var onSave: (TuneUpEvent) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var distance: RaceDistance
    @State private var date: Date
    @State private var racesIt: Bool
    @State private var hasGoalTime: Bool
    @State private var goalHours: Int
    @State private var goalMinutes: Int
    @State private var showRacePicker = false

    init(event: TuneUpEvent?, range: ClosedRange<Date>, others: [TuneUpEvent],
         onSave: @escaping (TuneUpEvent) -> Void) {
        self.event = event
        self.range = range
        self.others = others
        self.onSave = onSave
        _name = State(initialValue: event?.name ?? "")
        _distance = State(initialValue: event.map { RaceDistance.nearest(toMeters: $0.distanceM) } ?? .tenK)
        let start = event?.date ?? Calendar.current.date(byAdding: .weekOfYear, value: 4, to: range.lowerBound) ?? range.lowerBound
        _date = State(initialValue: min(max(start, range.lowerBound), range.upperBound))
        _racesIt = State(initialValue: event.map { $0.priority == .b } ?? true)
        let goal = event?.goalTimeS
        _hasGoalTime = State(initialValue: goal != nil)
        _goalHours = State(initialValue: goal.map { Int($0) / 3600 } ?? 0)
        _goalMinutes = State(initialValue: goal.map { (Int($0) % 3600) / 60 } ?? 45)
    }

    /// The spacing rule, stated inline: a B keeps seven days from another B, three from a C;
    /// a C keeps three from anything.
    private var conflict: TuneUpEvent? {
        let cal = Calendar.current
        return others.first { other in
            let gap = abs(cal.dateComponents([.day], from: cal.startOfDay(for: other.date),
                                             to: cal.startOfDay(for: date)).day ?? 0)
            let required = (racesIt && other.priority == .b) ? 7 : 3
            return gap < required
        }
    }

    private var goalTimeS: Double? {
        let seconds = Double(goalHours * 3600 + goalMinutes * 60)
        return hasGoalTime && seconds > 0 ? seconds : nil
    }

    private var canSave: Bool { conflict == nil && range.contains(Calendar.current.startOfDay(for: date).clamped(to: range)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    section("THE RACE") {
                        VStack(spacing: Theme.Space.sm) {
                            Button { showRacePicker = true } label: {
                                HStack(spacing: Theme.Space.md) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(name.isEmpty ? "Find the race" : name)
                                            .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                                            .lineLimit(1)
                                        Text("Pick it from the catalog, or set the distance and date below")
                                            .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                                }
                                .padding(Theme.Space.md)
                                .background(card)
                            }
                            .buttonStyle(.plain)
                            ForEach(RaceDistance.allCases) { d in
                                SelectionCard(title: d.label, isSelected: distance == d) {
                                    withAnimation(Motion.standard) { distance = d }
                                }
                            }
                        }
                    }

                    section("RACE DAY") {
                        DatePicker("Race day", selection: $date, in: range, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .padding(Theme.Space.sm)
                            .background(card)
                    }

                    section("HOW TO TREAT IT") {
                        VStack(spacing: Theme.Space.sm) {
                            SelectionCard(title: "Race it", subtitle: "Two easy days in, an honest effort, easy days out. The week bends; the block does not.",
                                          isSelected: racesIt) {
                                withAnimation(Motion.standard) { racesIt = true }
                            }
                            SelectionCard(title: "Train through", subtitle: "A hard session with a bib on. It stands in for that week's quality and nothing else moves.",
                                          isSelected: !racesIt) {
                                withAnimation(Motion.standard) { racesIt = false }
                            }
                        }
                    }

                    section("TARGET") {
                        VStack(spacing: Theme.Space.sm) {
                            Toggle(isOn: $hasGoalTime.animation(Motion.standard)) {
                                Text("Target finish time")
                                    .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                            }
                            .padding(Theme.Space.md)
                            .background(card)
                            if hasGoalTime {
                                HStack(spacing: 0) {
                                    Picker("Hours", selection: $goalHours) {
                                        ForEach(0..<7, id: \.self) { Text("\($0) hr").tag($0) }
                                    }
                                    .pickerStyle(.wheel)
                                    Picker("Minutes", selection: $goalMinutes) {
                                        ForEach(0..<60, id: \.self) { Text(String(format: "%02d min", $0)).tag($0) }
                                    }
                                    .pickerStyle(.wheel)
                                }
                                .frame(height: 110)
                                .background(card)
                            }
                        }
                    }

                    if let conflict {
                        HStack(alignment: .top, spacing: Theme.Space.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text("Too close to your \(RaceDistance.nearest(toMeters: conflict.distanceM).label) on \(conflict.date.formatted(.dateTime.month(.abbreviated).day())). A raced tune-up keeps a week from another; anything keeps three days.")
                                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(Theme.Space.md)
                        .background(card)
                    }
                }
                .padding(Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxl)
            }
            .background(Theme.background)
            .navigationTitle(event == nil ? "Add a tune-up" : "Tune-up race")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(event == nil ? "Add" : "Save") {
                        Haptics.light()
                        onSave(TuneUpEvent(id: event?.id ?? UUID(), name: name,
                                           date: Calendar.current.startOfDay(for: date),
                                           distanceM: distance.meters,
                                           priority: racesIt ? .b : .c, goalTimeS: goalTimeS))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                    .accessibilityIdentifier("tuneup-save")
                }
            }
            .sheet(isPresented: $showRacePicker) {
                RacePickerSheet { race, pickedDistance, pickedDate in
                    withAnimation(Motion.standard) {
                        name = race.name
                        distance = pickedDistance
                        date = min(max(pickedDate, range.lowerBound), range.upperBound)
                    }
                }
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            content()
        }
    }

    private var card: some View {
        Color.clear.raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

private extension Date {
    func clamped(to range: ClosedRange<Date>) -> Date { min(max(self, range.lowerBound), range.upperBound) }
}
