import SwiftUI
import SwiftData

/// The workout library (2026-07-23): browse the sport's canonical quality sessions, sized and
/// paced for THIS athlete, and drop one onto the plan. Every card is personalized before it's
/// ever opened — the library never shows a generic workout, because the athlete's calibrated 5k
/// prices every rep. Picking one writes the same `PlannedSession` grammar the plan generator
/// uses, so preview, live guidance, watch sync, and post-run scoring all just work.
///
/// Design: monochrome. A library is a menu, not an achievement — iridescence stays earned.
struct WorkoutLibrarySheet: View {
    let plan: TrainingPlan
    var defaultDate: Date = Date()
    var onDone: () -> Void

    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]

    private var distanceUnit: DistanceUnit {
        DistanceUnit(rawValue: profiles.first?.distanceUnit ?? "auto") ?? .auto
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    intro.reveal(0)
                    ForEach(Array(WorkoutLibrary.Category.allCases.enumerated()), id: \.element) { i, category in
                        section(category).reveal(0.05 + 0.04 * Double(i))
                    }
                }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, Theme.Space.sm)
                .padding(.bottom, Theme.Space.xl)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background)
            .navigationTitle("Workout library")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }.fontWeight(.semibold).foregroundStyle(Theme.ink)
                }
            }
            .navigationDestination(for: WorkoutLibrary.Entry.self) { entry in
                WorkoutLibraryDetail(entry: entry, plan: plan, defaultDate: defaultDate,
                                     distanceUnit: distanceUnit, onAdded: onDone)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
    }

    private var intro: some View {
        Text("The classics, priced for you — every pace below comes from your own calibrated fitness. Pick one and your coach guides you through it, step by step.")
            .font(.rounded(Theme.FontSize.caption, weight: .medium))
            .foregroundStyle(Theme.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: A category section

    private func section(_ category: WorkoutLibrary.Category) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: category.icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text(category.rawValue.uppercased())
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                    .foregroundStyle(Theme.ink)
            }
            Text(category.blurb)
                .font(.rounded(Theme.FontSize.label, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .padding(.bottom, 2)
            VStack(spacing: Theme.Space.sm) {
                ForEach(WorkoutLibrary.entries(in: category)) { entry in
                    NavigationLink(value: entry) { card(entry) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    /// One workout card: name + tier, the one-line what, and the personalized shape underneath —
    /// "8 × 400m @ 4:41 /km · ~45 min" — so browsing already speaks in the athlete's numbers.
    private func card(_ entry: WorkoutLibrary.Entry) -> some View {
        let rx = WorkoutLibrary.prescription(entry, p5k: plan.p5kSPerKm, unit: distanceUnit)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Text(entry.name)
                    .font(.rounded(Theme.FontSize.body, weight: .bold))
                    .foregroundStyle(Theme.ink)
                tierChip(entry.tier)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Text(entry.what)
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.shapeLine(rx, entry: entry, p5k: plan.p5kSPerKm, unit: distanceUnit))
                .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.inkTertiary)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the full workout")
    }

    private func tierChip(_ tier: WorkoutLibrary.Tier) -> some View {
        Text(tier.rawValue)
            .font(.rounded(Theme.FontSize.label, weight: .semibold))
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Theme.background))
            .overlay(Capsule().stroke(Theme.hairline))
    }

    /// "8 × 400m @ 4:41 /km · ~45 min" — the browsing-level shape summary. The grammar's zone
    /// annotation ("@ VO2") is engine-facing; browsing shows the athlete's actual pace instead.
    static func shapeLine(_ rx: WorkoutLibrary.Prescription, entry: WorkoutLibrary.Entry,
                          p5k: Double, unit: DistanceUnit) -> String {
        var parts: [String] = []
        if let grammar = rx.intervals {
            let shape = grammar.components(separatedBy: " @").first ?? grammar
            parts.append(shape.replacingOccurrences(of: "×", with: " × "))
        } else if let m = rx.targetDistanceM {
            parts.append(Formatters.distance(meters: m, unit: unit))
        }
        if entry.category != .hills, entry.category != .foundations {
            parts.append("@ " + Formatters.pace(secPerKm: rx.targetPaceSPerKm, unit: unit))
        }
        if let workout = StructuredWorkoutBuilder.build(from: rx.makeSession(on: .now), p5kSPerKm: p5k) {
            let est = WorkoutLibrary.estimatedDurationS(workout, easyPaceSPerKm: PlanEngine.pace(.easy, p5k: p5k))
            parts.append("~\(Int((est / 60).rounded())) min")
        }
        return parts.joined(separator: " · ")
    }
}

extension WorkoutLibrary.Entry: Hashable {
    static func == (lhs: WorkoutLibrary.Entry, rhs: WorkoutLibrary.Entry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Detail (the coach's full brief)

/// One workout, fully briefed: the personalized structure, a size dial, the coach's voice —
/// why it works, how it should feel, how to execute — and a day strip to put it on the plan.
struct WorkoutLibraryDetail: View {
    let entry: WorkoutLibrary.Entry
    let plan: TrainingPlan
    let defaultDate: Date
    let distanceUnit: DistanceUnit
    var onAdded: () -> Void

    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]

    @State private var volume: Double?
    @State private var day: Date
    @State private var saveFailed = false
    /// Latched on the first Add tap — a double-tap must never write two sessions.
    @State private var adding = false

    init(entry: WorkoutLibrary.Entry, plan: TrainingPlan, defaultDate: Date,
         distanceUnit: DistanceUnit, onAdded: @escaping () -> Void) {
        self.entry = entry
        self.plan = plan
        self.defaultDate = defaultDate
        self.distanceUnit = distanceUnit
        self.onAdded = onAdded
        _day = State(initialValue: Calendar.current.startOfDay(for: defaultDate))
    }

    private var prescription: WorkoutLibrary.Prescription {
        WorkoutLibrary.prescription(entry, volume: volume, p5k: plan.p5kSPerKm, unit: distanceUnit)
    }

    private var workout: StructuredWorkout? {
        StructuredWorkoutBuilder.build(from: prescription.makeSession(on: day),
                                       p5kSPerKm: plan.p5kSPerKm,
                                       raceDistanceM: profiles.first?.raceDistanceM)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header.reveal(0)
                structureCard.reveal(0.05)
                dialSection.reveal(0.09)
                coachSections.reveal(0.13)
                daySection.reveal(0.17)
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.xl)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { addBar }
        .alert("Couldn't add the workout", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Something went wrong writing to storage. Your choices are still here — try again.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("\(entry.category.rawValue) · \(entry.tier.rawValue)".uppercased())
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                .foregroundStyle(Theme.inkTertiary)
            Text(entry.name)
                .font(.display(30, weight: .black))
                .foregroundStyle(Theme.ink)
            Text(entry.what)
                .font(.rounded(Theme.FontSize.body, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The personalized structure

    private var structureCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionLabel("YOUR SESSION")
            if let workout {
                let lines = workout.summaryLines(distanceUnit: distanceUnit)
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        HStack(alignment: .firstTextBaseline) {
                            Text(line.label)
                                .font(.rounded(Theme.FontSize.caption, weight: .bold))
                                .foregroundStyle(Theme.ink)
                            Spacer(minLength: Theme.Space.sm)
                            Text(line.detail)
                                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        .padding(.vertical, 9)
                        if i < lines.count - 1 {
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                    }
                }
                estimateLine(workout)
            }
        }
        .padding(Theme.Space.md)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
        }
    }

    private func estimateLine(_ workout: StructuredWorkout) -> some View {
        let est = WorkoutLibrary.estimatedDurationS(workout, easyPaceSPerKm: PlanEngine.pace(.easy, p5k: plan.p5kSPerKm))
        var parts = ["~\(Int((est / 60).rounded())) min"]
        if workout.plannedDistanceM > 0 {
            parts.append(Formatters.distance(meters: workout.plannedDistanceM, unit: distanceUnit) + " total")
        }
        return Text(parts.joined(separator: " · "))
            .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
            .foregroundStyle(Theme.inkTertiary)
            .padding(.top, Theme.Space.xs)
    }

    // MARK: The size dial

    @ViewBuilder private var dialSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionLabel("SIZE IT")
            HStack(spacing: Theme.Space.sm) {
                switch entry.dial {
                case let .reps(options, def):
                    ForEach(options, id: \.self) { n in
                        dialOption(label: "\(n)", caption: "reps",
                                   on: Int(volume ?? Double(def)) == n) { volume = Double(n) }
                    }
                case let .kilometers(options, def):
                    ForEach(options, id: \.self) { km in
                        let m = RunRounding.snap(meters: km * 1000, unit: distanceUnit)
                        let value = distanceUnit.resolved() == .imperial ? m / Formatters.metersPerMile : m / 1000
                        dialOption(label: Formatters.distanceNumeral(value),
                                   caption: distanceUnit.resolved() == .imperial ? "mi" : "km",
                                   on: (volume ?? def) == km) { volume = km }
                    }
                case let .minutes(options, def):
                    ForEach(options, id: \.self) { min in
                        dialOption(label: "\(Int(min))", caption: "min",
                                   on: (volume ?? def) == min) { volume = min }
                    }
                }
            }
            Text("Bounded to what a coach would actually prescribe — size the session, never distort it.")
                .font(.rounded(Theme.FontSize.label, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func dialOption(label: String, caption: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.selection(); action() } label: {
            VStack(spacing: 1) {
                Text(label)
                    .font(.display(20, weight: .heavy)).monospacedDigit()
                Text(caption)
                    .font(.rounded(Theme.FontSize.label, weight: .semibold))
            }
            .foregroundStyle(on ? .white : Theme.ink)
            .frame(maxWidth: .infinity).frame(height: 58)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? Theme.purple : Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(on ? Color.clear : Theme.hairline)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
        .accessibilityLabel("\(label) \(caption)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: The coach's voice

    private var coachSections: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            prose("WHY IT WORKS", entry.why)
            prose("HOW IT SHOULD FEEL", entry.feels)
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                sectionLabel("FROM YOUR COACH")
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    ForEach(Array(entry.execution.enumerated()), id: \.offset) { _, cue in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                            Circle().fill(Theme.ink).frame(width: 4, height: 4)
                                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                            Text(cue)
                                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                                .foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface)
                    RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
                }
            }
        }
    }

    private func prose(_ heading: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionLabel(heading)
            Text(body)
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Day strip (AddSessionSheet's exact grammar)

    private var daySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionLabel("DAY")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.sm) {
                        ForEach(dayStrip, id: \.self) { dayBadge($0).id($0) }
                    }
                    .padding(.vertical, 2)
                }
                .onAppear { proxy.scrollTo(Calendar.current.startOfDay(for: day), anchor: .center) }
            }
        }
    }

    private var dayStrip: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let def = cal.startOfDay(for: defaultDate)
        let first = min(today, def)
        let last = max(cal.date(byAdding: .day, value: 13, to: today) ?? today, def)
        let span = min((cal.dateComponents([.day], from: first, to: last).day ?? 13) + 1, 70)
        var days = (0..<max(1, span)).compactMap { cal.date(byAdding: .day, value: $0, to: first) }
        if !days.contains(where: { cal.isDate($0, inSameDayAs: def) }) { days.append(def) }
        return days
    }

    private func dayBadge(_ d: Date) -> some View {
        let on = Calendar.current.isDate(d, inSameDayAs: day)
        return Button { Haptics.selection(); day = d } label: {
            VStack(spacing: 3) {
                Text(d.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.rounded(Theme.FontSize.label, weight: .bold))
                Text(d.formatted(.dateTime.day()))
                    .font(.display(20, weight: .heavy)).monospacedDigit()
            }
            .foregroundStyle(on ? .white : Theme.ink)
            .frame(width: 54, height: 66)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? Theme.purple : Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(on ? Color.clear : Theme.hairline)
            }
            .scaleEffect(on ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
    }

    // MARK: Add

    private var addBar: some View {
        Button(action: add) {
            Text(addLabel)
                .font(.rounded(Theme.FontSize.body, weight: .bold))
                .foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity).frame(height: 56)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.ink))
        }
        .buttonStyle(.plain)
        .disabled(adding)
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
        .background(Theme.background.opacity(0.94))
    }

    private var addLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Add for today" }
        if cal.isDateInTomorrow(day) { return "Add for tomorrow" }
        return "Add for \(day.formatted(.dateTime.weekday(.wide)))"
    }

    private func add() {
        guard !adding else { return }
        adding = true
        let session = prescription.makeSession(on: day)
        context.insert(session)
        plan.sessions.append(session)
        do {
            try context.save()
            Haptics.success()
            PhoneWatchSync.shared.scheduleRefresh()
            onAdded()
        } catch {
            context.delete(session)
            adding = false
            saveFailed = true
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
            .foregroundStyle(Theme.inkTertiary)
    }
}
