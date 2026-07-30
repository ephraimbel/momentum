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

    enum GoalKind: Hashable { case open, distance }
    /// The athlete's chosen unit. This was pinned to `.auto`, which resolves off LOCALE — so a US
    /// athlete who had explicitly chosen metric typed "5" meaning 5 km and got 5 miles (8047 m)
    /// stored, then saw it rendered back as "8 km". Wrong data, not just a wrong label.
    private var distanceUnit: DistanceUnit {
        DistanceUnit(rawValue: profiles.first?.distanceUnit ?? "auto") ?? .auto
    }
    private var isGPS: Bool { sport.isGPS }
    private var isTimed: Bool { sport.isTimed }
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
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    if onOpenLibrary != nil {
                        libraryRow
                        orDivider
                    }
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
        .alert("Couldn't add the session", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Something went wrong writing to storage. Your choices are still here — try Add again.")
        }
        .sheet(isPresented: $showSportPicker) {
            SportPicker(selection: $sport) { showSportPicker = false }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            // "Add a session", not "Plan a session": the sheet lives ON the plan page, where
            // "plan" is already the page's name (circular), and everything around it speaks
            // add — the + that opened it, the rest rows' "tap to add", the CTA "Add to plan".
            // One verb from tap to commit.
            Text("Add a session")
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

    // MARK: The workout library door — guided classics, one tap away from the manual form

    private var libraryRow: some View {
        Button { Haptics.light(); onOpenLibrary?() } label: {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "text.book.closed.fill")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.background)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.ink))
                VStack(alignment: .leading, spacing: 1) {
                    Text("From the library")
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("Fartlek, tempo, hills — classic workouts, guided step by step.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            }
            .padding(Theme.Space.md)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Workout library")
        .accessibilityHint("Pick a guided running workout")
    }

    /// The typographic seam between the two ways in: the guided library above, the manual form
    /// below. Without it the library card read as just another form field.
    private var orDivider: some View {
        HStack(spacing: Theme.Space.md) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            Text("OR BUILD YOUR OWN")
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize()
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
        .accessibilityHidden(true)
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
    /// shown and selectable, never silently applied on a hidden day. Capped so it can't run away —
    /// and when the cap would cut the pre-selected day off (a rest day in week 11+ of a long plan),
    /// that day is appended anyway, because the guarantee above is the whole point of this strip.
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

    private func dayBadge(_ day: Date) -> some View {
        let on = Calendar.current.isDate(day, inSameDayAs: date)
        let isToday = Calendar.current.isDateInToday(day)
        return Button { Haptics.selection(); date = day } label: {
            VStack(spacing: 3) {
                // Today says so — a strip of interchangeable weekday names made the athlete
                // count badges to find "now", the one date the sheet opens on.
                Text(isToday ? "TODAY" : day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.rounded(Theme.FontSize.label, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.7)
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

    // MARK: Activity — quick picks for the sports people actually plan, the full picker one tap away

    /// The four sports that cover nearly every hand-planned session. The old design was a single
    /// "Run · Tap to change" card that cost a full sheet hop to pick *strength* — the second most
    /// common choice. A sport picked through "More" joins the grid as its own selected chip, so
    /// the choice is always visible in place.
    private static let quickSports: [WorkoutType] = [.run, .strength, .ride, .walk]

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            label("Activity")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.sm), count: 3),
                      spacing: Theme.Space.sm) {
                ForEach(Self.quickSports, id: \.self) { sportChip($0) }
                if !Self.quickSports.contains(sport) { sportChip(sport) }
                moreChip
            }
        }
    }

    /// Chip-width titles: "Weight Training" truncated to "Weight Trai…" in a third-of-the-row
    /// chip, and the Plan board already calls that day "Strength" everywhere.
    private func chipTitle(_ t: WorkoutType) -> String {
        t == .strength ? "Strength" : t.title
    }

    private func sportChip(_ t: WorkoutType) -> some View {
        let on = sport == t
        return Button { Haptics.selection(); sport = t } label: {
            HStack(spacing: 6) {
                Image(systemName: t.systemImage).font(.system(size: 13, weight: .bold))
                Text(chipTitle(t)).font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(on ? Theme.background : Theme.ink)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? Theme.ink : Theme.surface)
                if !on { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline) }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
        .accessibilityLabel(chipTitle(t))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Every other sport — swim, row, yoga, tennis, the whole Strava-style list — via the full picker.
    private var moreChip: some View {
        Button { Haptics.light(); showSportPicker = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold))
                Text("More").font(.rounded(Theme.FontSize.body, weight: .semibold))
            }
            .foregroundStyle(Theme.inkSecondary)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More activities")
        .accessibilityHint("Opens the full activity picker")
    }

    // MARK: Goal — distance for GPS sports

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            label("Goal")
            // The house segmented control — two full-width 52 pt slabs for a binary choice was
            // this sheet inventing its own grammar (and out-shouting the day strip above it).
            SegmentedCapsule(items: [GoalKind.open, .distance], selection: $goalKind) {
                $0 == .open ? "Open" : "Distance"
            }
            if goalKind == .distance { distanceStepper }
        }
    }

    // MARK: Goal — duration for timed sports (swim, row, yoga, tennis…)

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            label("Goal")
            SegmentedCapsule(items: [GoalKind.open, .distance], selection: $goalKind) {
                $0 == .open ? "Open" : "Duration"
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

    /// The receipt-before-commit: one quiet line of exactly what Add will create ("Today · Run ·
    /// 5 mi"), so the button never asks for trust. It re-reads live as the choices above change —
    /// the whole form summarized where the thumb already is.
    private var addBar: some View {
        // Built once per pass — the eager accessibility argument + animation key re-ran the whole
        // formatter chain three times over.
        let receipt = receiptLine
        return VStack(spacing: Theme.Space.sm + 2) {
            Text(receipt)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1).minimumScaleFactor(0.85)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.15), value: receipt)
                .accessibilityLabel("Adding \(receipt)")
            OversizedButton(title: "Add to plan", systemImage: "plus") { add() }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.sm)
        // The page's own canvas, not a glass band — the bar reads as part of the sheet, no seam.
        // A plain background (rather than none) still matters: this is a safe-area inset over a
        // ScrollView, so on small screens/large type the form would otherwise scroll visibly
        // through the button.
        .background(Theme.background)
    }

    private var receiptLine: String {
        let day = Calendar.current.isDateInToday(date)
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
            // Only a run carries a RunType — a hand-added Ride/Walk/Hike used to inherit `.easy`,
            // which then rendered a spurious "Easy" run-type chip (and a running HR-zone chip) in the
            // session detail. Ride/walk/hike leave it nil and show only their sport + goal.
            if sport == .run { s.runType = .easy }
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
        // Never confirm a session that didn't land — a silent failure here means the athlete
        // watches the board and their session simply isn't there.
        do { try context.save() } catch {
            plan.sessions.removeAll { $0.id == s.id }
            context.delete(s)
            saveFailed = true
            return
        }
        Haptics.success()
        onDone()
    }
}
