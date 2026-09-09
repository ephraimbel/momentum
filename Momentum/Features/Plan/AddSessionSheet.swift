import SwiftUI
import SwiftData

/// Plan your own session: pick a day, a discipline, and (for cardio) a distance goal. Inserts a
/// `PlannedSession` into the plan so it shows up on Plan and Today like any AI-prescribed one.
///
/// Redesigned 2026-09-07 to speak the house sheet grammar instead of its own: the lowercase
/// display masthead with the X-circle close (the inbox's, fuel's, progress's), raised white cards
/// with an ink hairline for the pick (the retired lavender fill is gone), the Plan board's own
/// date language for the day (an ink pill on the chosen day), a two-week calendar instead of a
/// horizontal strip (the app is vertical-only), and the pinned `OversizedButton` with its receipt.
struct AddSessionSheet: View {
    let plan: TrainingPlan
    var defaultDate: Date = Date()
    var onDone: () -> Void
    /// Present the workout library instead (the host swaps sheets). nil hides the row.
    var onOpenLibrary: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]

    @State private var date: Date
    @State private var sport: WorkoutType = .run
    @State private var goalKind: GoalKind = .open
    @State private var goalValue = 5.0          // km/mi for distance
    @State private var goalMinutes = 30.0       // minutes for timed sports
    @State private var showSportPicker = false
    @State private var saveFailed = false
    @ReducedMotionPreference private var reduceMotion

    enum GoalKind: Hashable { case open, distance }
    /// The athlete's chosen unit. This was pinned to `.auto`, which resolves off LOCALE — so a US
    /// athlete who had explicitly chosen metric typed "5" meaning 5 km and got 5 miles (8047 m)
    /// stored, then saw it rendered back as "8 km". Wrong data, not just a wrong label.
    private var distanceUnit: DistanceUnit {
        DistanceUnit(rawValue: profiles.first?.distanceUnit ?? "auto") ?? .auto
    }
    private var isGPS: Bool { sport.isGPS }
    private var unitLabel: String { distanceUnit.resolved() == .imperial ? "mi" : "km" }

    init(plan: TrainingPlan, defaultDate: Date = Date(), onDone: @escaping () -> Void,
         onOpenLibrary: (() -> Void)? = nil) {
        self.plan = plan
        self.defaultDate = defaultDate
        self.onDone = onDone
        self.onOpenLibrary = onOpenLibrary
        _date = State(initialValue: Calendar.current.startOfDay(for: defaultDate))
    }

    var body: some View {
        VStack(spacing: 0) {
            masthead
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if onOpenLibrary != nil { libraryRow }
                    section("Day") { dayCard }
                    section("Activity") { activityGrid }
                    section("Goal") { goalBlock }
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.top, Theme.Space.xs)
                .padding(.bottom, Theme.Space.xl)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) { addBar }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
        .alert("Couldn't add the session", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Something went wrong writing to storage. Your choices are still here. Try Add again.")
        }
        .sheet(isPresented: $showSportPicker) {
            SportPicker(selection: $sport) { showSportPicker = false }
        }
        .trackScreen(.addSession)
    }

    // MARK: Masthead — the house sheet grammar: the lowercase title centered in the display face,
    // the X-circle close flanking. Exactly how the inbox, fuel and progress read.

    private var masthead: some View {
        ZStack {
            // "Add a session", not "Plan a session": the sheet lives ON the plan page, where
            // "plan" is already the page's name, and everything around it speaks add: the + that
            // opened it, the rest rows' "tap to add", the CTA "Add to plan". One verb throughout.
            Text("add a session")
                .font(.display(20, weight: .bold))
                .foregroundStyle(Theme.ink)
                .accessibilityLabel("Add a session")
                .accessibilityAddTraits(.isHeader)
            HStack {
                Spacer()
                Button { onDone() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.surface))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.lg)
        .padding(.bottom, Theme.Space.md)
    }

    /// A section: the tracked uppercase label the session sheet uses, then its content.
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title.uppercased())
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.leading, Theme.Space.xs)
            content()
        }
    }

    // MARK: The workout library door — guided classics, one row above the form

    private var libraryRow: some View {
        Button { Haptics.light(); onOpenLibrary?() } label: {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "text.book.closed.fill")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 36, height: 36)
                    .background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("From the library")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("Classic workouts, guided step by step.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.inkTertiary.opacity(0.7))
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 12)
            .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(RaisedPressStyle())
        .accessibilityLabel("Workout library")
        .accessibilityHint("Pick a guided running workout")
    }

    // MARK: Day — two calendar weeks in one card, the board's own date language

    private var calendar: Calendar { Calendar.current }

    /// The two weeks on show: the week holding the earlier of {today, the pre-selected day} and
    /// the one after it, so a pre-selected day (a future Pro week, an earlier-this-week rest day)
    /// is always on the grid and never silently applied off-screen. A day further out than that
    /// anchors the grid on its own week instead.
    private var weeks: [[Date]] {
        let today = calendar.startOfDay(for: Date())
        let def = calendar.startOfDay(for: defaultDate)
        let anchor: Date = {
            let first = min(today, def)
            let firstWeek = calendar.dateInterval(of: .weekOfYear, for: first)?.start ?? first
            let secondWeekEnd = calendar.date(byAdding: .day, value: 14, to: firstWeek) ?? first
            return def < secondWeekEnd ? first : def
        }()
        let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
        return (0..<2).map { week in
            (0..<7).compactMap { calendar.date(byAdding: .day, value: week * 7 + $0, to: start) }
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(first + $0) % 7] }
    }

    private var dayCard: some View {
        VStack(spacing: Theme.Space.sm) {
            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(0.6)
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        dayCell(day).frame(maxWidth: .infinity)
                    }
                }
            }
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
                .padding(.top, Theme.Space.xs)
            // The chosen day in full, so the grid never has to be counted.
            Text(chosenDayLine)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: chosenDayLine)
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.top, Theme.Space.md)
        .padding(.bottom, Theme.Space.sm + 2)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private var chosenDayLine: String {
        calendar.isDateInToday(date)
            ? "Today, \(date.formatted(.dateTime.month(.wide).day()))"
            : date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    /// The board's date badge: the numeral in the display face, the chosen day an ink pill, today
    /// marked by a dot beneath, days already behind us receding (still tappable when the sheet
    /// opened on one, never otherwise).
    private func dayCell(_ day: Date) -> some View {
        let on = calendar.isDate(day, inSameDayAs: date)
        let isToday = calendar.isDateInToday(day)
        let past = day < calendar.startOfDay(for: Date())
        let allowed = !past || calendar.isDate(day, inSameDayAs: defaultDate)
        return Button {
            guard allowed else { return }
            Haptics.selection()
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75)) { date = day }
        } label: {
            VStack(spacing: 3) {
                Text(day.formatted(.dateTime.day()))
                    .font(.display(18, weight: .heavy)).monospacedDigit()
                    .foregroundStyle(on ? Theme.background : (allowed ? Theme.ink : Theme.inkTertiary.opacity(0.5)))
                Circle()
                    .fill(isToday && !on ? Theme.ink : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(width: 40, height: 46)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.ink)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!allowed)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day()) + (isToday ? ", today" : ""))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Activity — the sports people actually plan, the full picker one tap away

    /// The four sports that cover nearly every hand-planned session. A sport picked through
    /// "More" joins the grid as its own selected chip, so the choice is always visible in place.
    private static let quickSports: [WorkoutType] = [.run, .strength, .ride, .walk]

    private var activityGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.sm), count: 3),
                  spacing: Theme.Space.sm) {
            ForEach(Self.quickSports, id: \.self) { sportChip($0) }
            if !Self.quickSports.contains(sport) { sportChip(sport) }
            moreChip
        }
    }

    /// Chip-width titles: "Weight Training" truncated to "Weight Trai…" in a third-of-the-row
    /// chip, and the Plan board already calls that day "Strength" everywhere.
    private func chipTitle(_ t: WorkoutType) -> String {
        t == .strength ? "Strength" : t.title
    }

    /// The `SelectionCard` language at chip size: raised white at rest, the pick is the ink
    /// hairline rim and the filled check.
    private func sportChip(_ t: WorkoutType) -> some View {
        let on = sport == t
        return Button {
            Haptics.selection()
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75)) { sport = t }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: t.systemImage).font(.system(size: 13, weight: .bold))
                Text(chipTitle(t)).font(.rounded(Theme.FontSize.body - 1, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.75)
                if on {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.background, Theme.ink)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.Space.sm)
            .frame(maxWidth: .infinity).frame(height: 46)
            .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous), selected: on)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(RaisedPressStyle())
        .accessibilityLabel(chipTitle(t))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Every other sport (swim, row, yoga, tennis, the whole list) via the full picker.
    private var moreChip: some View {
        Button { Haptics.light(); showSportPicker = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold))
                Text("More").font(.rounded(Theme.FontSize.body - 1, weight: .semibold))
            }
            .foregroundStyle(Theme.inkSecondary)
            .frame(maxWidth: .infinity).frame(height: 46)
            .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(RaisedPressStyle())
        .accessibilityLabel("More activities")
        .accessibilityHint("Opens the full activity picker")
    }

    // MARK: Goal — open, or a distance (GPS sports) / a duration (everything else)

    private var goalBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            // The house segmented control for the binary choice.
            SegmentedCapsule(items: [GoalKind.open, .distance], selection: $goalKind) {
                $0 == .open ? "Open" : (isGPS ? "Distance" : "Duration")
            }
            if goalKind == .distance {
                (isGPS ? AnyView(distanceStepper) : AnyView(minutesStepper))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8), value: goalKind)
    }

    private var minutesStepper: some View {
        stepperCard(value: "\(Int(goalMinutes))", unit: "min",
                    minus: { goalMinutes = max(5, goalMinutes - 5) },
                    plus: { goalMinutes += 5 })
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: goalMinutes)
    }

    private var distanceStepper: some View {
        stepperCard(value: goalValue.formatted(.number.precision(.fractionLength(goalValue == goalValue.rounded() ? 0 : 1))),
                    unit: unitLabel,
                    minus: { goalValue = max(0.5, goalValue - 0.5) },
                    plus: { goalValue += 0.5 })
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: goalValue)
    }

    /// The session sheet's own stepper, housed: the numeral in the display face between two quiet
    /// circles, on one raised card.
    private func stepperCard(value: String, unit: String, minus: @escaping () -> Void,
                             plus: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.lg) {
            stepButton("minus", action: minus)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.display(34, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
            Spacer(minLength: 0)
            stepButton("plus", action: plus)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm + 2)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button { Haptics.light(); action() } label: {
            Image(systemName: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
                .background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "minus" ? "Decrease" : "Increase")
    }

    // MARK: Add bar

    /// The receipt-before-commit: one quiet line of exactly what Add will create ("Today · Run ·
    /// 5 mi"), so the button never asks for trust. It re-reads live as the choices above change,
    /// the whole form summarized where the thumb already is.
    private var addBar: some View {
        let receipt = receiptLine
        return VStack(spacing: Theme.Space.sm + 2) {
            Text(receipt)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1).minimumScaleFactor(0.85)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: receipt)
                .accessibilityLabel("Adding \(receipt)")
            OversizedButton(title: "Add to plan", systemImage: "plus") { add() }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.sm)
        // The page's own canvas, not a glass band: the bar reads as part of the sheet, no seam.
        // A plain background (rather than none) still matters: this is a safe-area inset over a
        // ScrollView, so on small screens/large type the form would otherwise scroll visibly
        // through the button.
        .background(Theme.background)
    }

    private var receiptLine: String {
        let day = calendar.isDateInToday(date)
            ? "Today" : date.formatted(.dateTime.weekday(.abbreviated).day())
        var parts = [day, chipTitle(sport)]
        if goalKind == .distance {
            if isGPS {
                let v = goalValue.formatted(.number.precision(.fractionLength(goalValue == goalValue.rounded() ? 0 : 1)))
                parts.append("\(v) \(unitLabel)")
            } else {
                parts.append("\(Int(goalMinutes)) min")
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Commit

    private func add() {
        let s = PlannedSession()
        s.date = calendar.startOfDay(for: date)
        s.sportType = sport.rawValue
        s.discipline = sport.discipline      // coaching bucket; sportType carries the exact sport
        s.status = .planned
        if isGPS {
            // Only a run carries a RunType. A hand-added Ride/Walk/Hike used to inherit `.easy`,
            // which then rendered a spurious "Easy" run-type chip (and a running HR-zone chip) in
            // the session detail. Ride/walk/hike leave it nil and show only their sport + goal.
            if sport == .run { s.runType = .easy }
            if goalKind == .distance {
                s.targetDistanceM = goalValue * (distanceUnit.resolved() == .imperial ? Formatters.metersPerMile : 1000)
            }
        } else if goalKind == .distance {
            // Any non-GPS sport (timed OR strength-style) sets a duration goal, so a hand-added
            // strength session reads as real work ("Strength · 45 min") instead of an empty stub.
            s.targetDurationS = goalMinutes * 60
        }
        plan.sessions.append(s)
        context.insert(s)
        // Never confirm a session that didn't land: a silent failure here means the athlete
        // watches the board and their session simply isn't there.
        do { try context.save() } catch {
            plan.sessions.removeAll { $0.id == s.id }
            context.delete(s)
            saveFailed = true
            return
        }
        AdaptiveAnalytics.emit("workout_scheduled", reason: sport.rawValue)
        Haptics.success()
        onDone()
    }
}
