import SwiftUI
import SwiftData

/// Your plans (2026-09-07, docs/PLAN-AND-FUEL-UPGRADE.md §2.1): the current plan, the plans waiting
/// for their day, the drafts, and the plans that came before, on one page behind the Plan masthead.
/// The Plan tab itself stays the current week; this is where a plan is created, scheduled,
/// switched, or looked back on. Every write goes through `PlanLifecycleService`.
struct YourPlansView: View {
    let profile: UserProfile
    let distanceUnit: DistanceUnit
    /// The board's own workout query, for the downstream mirror after an activation. Passed in so
    /// opening the shelf never materialises the workout table a second time.
    let workouts: [Workout]
    /// Open the current plan's adjuster (the caller owns that sheet).
    var onManageCurrent: () -> Void
    /// Open the plan builder on a blueprint (nil = a fresh plan; a record = editing that draft).
    var onCompose: (PlanShelfRecord?) -> Void
    /// The caller re-reads the plan after an activation (the board repopulates).
    var onPlanChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @Query private var records: [PlanShelfRecord]

    @State private var reviewing: ReviewTarget?
    @State private var currentReview: CurrentReview?
    @State private var scheduling: PlanShelfRecord?
    @State private var overlapDecision: OverlapDecision?
    @State private var deleting: PlanShelfRecord?
    @State private var failure: String?
    /// What the sheet on its way out asked for; runs from that sheet's `onDismiss`, never in the
    /// same tick as the dismissal (two presentations in one transaction can leave a flag stuck).
    @State private var pending: Pending?

    private enum Pending {
        case manage
        case compose(PlanShelfRecord?)
        case startNow(PlanShelfRecord)
        case schedule(PlanShelfRecord)
        case scheduleDay(PlanShelfRecord, Date)
        case startAgain(PlanShelfRecord)
        case replace(OverlapDecision)
        case startAfter(OverlapDecision)
    }

    private struct ReviewTarget: Identifiable {
        enum Kind { case current, shelved(PlanShelfRecord) }
        let kind: Kind
        var id: String {
            switch kind {
            case .current: "current"
            case .shelved(let r): r.id.uuidString
            }
        }
    }

    /// A start or schedule that would cut into the current plan: the athlete decides with the
    /// affected dates in front of them.
    private struct OverlapDecision: Identifiable {
        let record: PlanShelfRecord
        let overlap: PlanLifecycle.Overlap
        /// The day the plan would start: activation's real start for Start now (tomorrow in the
        /// evening), or the scheduled day.
        let startDay: Date
        let startsNow: Bool
        var id: UUID { record.id }
    }

    init(profile: UserProfile, distanceUnit: DistanceUnit, workouts: [Workout], onManageCurrent: @escaping () -> Void,
         onCompose: @escaping (PlanShelfRecord?) -> Void, onPlanChanged: @escaping () -> Void) {
        self.profile = profile
        self.distanceUnit = distanceUnit
        self.workouts = workouts
        self.onManageCurrent = onManageCurrent
        self.onCompose = onCompose
        self.onPlanChanged = onPlanChanged
        let profileID = profile.id
        _records = Query(filter: #Predicate<PlanShelfRecord> { $0.profileID == profileID },
                         sort: [SortDescriptor(\PlanShelfRecord.updatedAt, order: .reverse)])
    }

    private var upcoming: [PlanShelfRecord] {
        records.filter { $0.status == .upcoming }.sorted { ($0.scheduledStart ?? .distantFuture) < ($1.scheduledStart ?? .distantFuture) }
    }
    private var drafts: [PlanShelfRecord] { records.filter { $0.status == .draft } }
    private var previous: [PlanShelfRecord] {
        records.filter { $0.status.isPrevious }.sorted { ($0.endedAt ?? $0.updatedAt) > ($1.endedAt ?? $1.updatedAt) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    createButton
                    section("Current") {
                        if let plan = profile.plan {
                            currentCard(plan)
                        } else {
                            quietLine("No current plan. Create one, or start a draft when you are ready.")
                        }
                    }
                    if !upcoming.isEmpty {
                        section("Upcoming") { ForEach(upcoming) { shelvedCard($0) } }
                    }
                    if !drafts.isEmpty {
                        section("Drafts") { ForEach(drafts) { shelvedCard($0) } }
                    }
                    if !previous.isEmpty {
                        section("Previous") { ForEach(previous) { shelvedCard($0) } }
                    }
                    if upcoming.isEmpty, drafts.isEmpty, previous.isEmpty {
                        quietLine("Drafts never start on their own. An upcoming plan starts on its day and the plan it replaces moves here.")
                            .padding(.top, Theme.Space.sm)
                    }
                }
                .padding(Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxl)
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("your plans")
                        .font(.display(20, weight: .bold)).foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .sheet(item: $reviewing, onDismiss: runPending) { target in
                switch target.kind {
                case .current:
                    // Built once at the tap (`openCurrentReview`): a sheet's content closure runs
                    // on every parent body pass, and the snapshot walks every session.
                    if let review = currentReview {
                        PlanReviewView(title: review.title, status: nil,
                                       blueprint: review.blueprint, preview: review.preview,
                                       distanceUnit: distanceUnit) {
                            reviewActions(.current)
                        }
                    }
                case .shelved(let record):
                    PlanReviewView(title: record.name, status: record.status,
                                   blueprint: record.blueprint ?? PlanBlueprint(),
                                   preview: record.preview, distanceUnit: distanceUnit) {
                        reviewActions(.shelved(record))
                    }
                }
            }
            .sheet(item: $scheduling, onDismiss: runPending) { record in
                PlanScheduleSheet(initial: record.scheduledStart, currentEnd: currentSpan?.end,
                                  latest: record.blueprint.flatMap { $0.isRace ? $0.raceDate : nil }) { day in
                    // The sheet dismisses itself; the overlap sheet (if any) opens after it has gone.
                    pending = .scheduleDay(record, day)
                }
            }
            .sheet(item: $overlapDecision, onDismiss: runPending) { decision in
                PlanOverlapSheet(planName: decision.record.name,
                                 currentName: profile.plan.map { $0.name.isEmpty ? PlanBlueprint(profile: profile).displayName : $0.name } ?? "Your current plan",
                                 overlap: decision.overlap,
                                 startDay: decision.startDay,
                                 onReplace: { pending = .replace(decision); overlapDecision = nil },
                                 onStartAfter: { pending = .startAfter(decision); overlapDecision = nil })
            }
            .confirmationDialog(deleting?.status.isPrevious == true ? "Remove this plan?" : "Delete this draft?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { record in
                Button(record.status.isPrevious ? "Remove \(record.name)" : "Delete \(record.name)", role: .destructive) { delete(record) }
                Button("Keep it", role: .cancel) { deleting = nil }
            } message: { record in
                Text(record.status.isPrevious
                     ? "Its summary leaves your previous plans. Every workout you logged stays in History."
                     : "Nothing you have completed is affected. Drafts hold inputs, not sessions.")
            }
            .alert("That didn’t work", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "Please try again.") }
        }
        .nestedPaywallHost()
        .onAppear { PerfMark.end("your-plans-open") }
        .trackScreen(.yourPlans)
    }

    // MARK: - Sections

    private var createButton: some View {
        Button {
            Haptics.light()
            onCompose(nil)
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                Text("Create a plan")
                    .font(.rounded(Theme.FontSize.body, weight: .bold))
            }
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .raised(Capsule(), tone: .ink)
        }
        .buttonStyle(RaisedPressStyle())
        .accessibilityIdentifier("plans-create")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title.uppercased())
                .font(.rounded(10, weight: .bold)).tracking(1.4)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.leading, Theme.Space.xs)
            content()
        }
    }

    private func quietLine(_ text: String) -> some View {
        Text(text)
            .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.xs)
    }

    // MARK: - Cards

    private var currentSpan: PlanLifecycle.Span? { PlanLifecycleService.currentSpan(for: profile) }

    private func currentBlueprint(_ plan: TrainingPlan) -> PlanBlueprint {
        var b = PlanBlueprint(profile: profile)
        b.name = plan.name
        return b
    }

    /// The current plan as the review sheet shows it, snapshotted once when the sheet is asked for.
    private struct CurrentReview {
        let title: String
        let blueprint: PlanBlueprint
        let preview: PlanPreview
    }

    private func openCurrentReview() {
        guard let plan = profile.plan else { return }
        let blueprint = currentBlueprint(plan)
        currentReview = CurrentReview(
            title: plan.name.isEmpty ? blueprint.displayName : plan.name,
            blueprint: blueprint,
            preview: PlanPreview.build(snapshot: CoachUndo.planState(of: plan), blueprint: blueprint,
                                       distanceUnit: distanceUnit, anchor: PlanLifecycleService.span(of: plan).start))
        openCurrentReview()
    }

    private func currentCard(_ plan: TrainingPlan) -> some View {
        let blueprint = currentBlueprint(plan)
        let span = PlanLifecycleService.span(of: plan)
        let weeks = max(plan.weekPhases.count, 1)
        let progress = PlanLifecycle.progress(start: span.start, weeks: weeks,
                                              sessionStatuses: plan.sessions.map(\.status), today: Date())
        let title = plan.name.isEmpty ? blueprint.displayName : plan.name
        return PlanShelfCard(
            title: title,
            status: nil,
            statusLine: plan.isSelfCoached ? "Self-coached" : "Week \(progress.weekNumber) of \(progress.weeks)",
            goalLine: plan.isSelfCoached ? "Your plan, your call" : blueprint.goalLine(),
            datesLine: datesLine(start: span.start, end: span.end),
            metaLine: plan.isSelfCoached ? nil : "\(weeks) weeks · \(blueprint.frequencyLine)",
            progress: plan.isSelfCoached ? nil : progress.fraction,
            primaryAction: (plan.isSelfCoached ? "Manage" : "Manage plan", { onManageCurrent() }),
            menu: {
                Button { openCurrentReview() } label: { Label("Preview", systemImage: "eye") }
                Button { onManageCurrent() } label: { Label("Manage plan", systemImage: "slider.horizontal.3") }
            })
        .onTapGesture { openCurrentReview() }
        .accessibilityAction(named: "Preview") { openCurrentReview() }
        .accessibilityIdentifier("plans-current")
    }

    private func shelvedCard(_ record: PlanShelfRecord) -> some View {
        let blueprint = record.blueprint ?? PlanBlueprint()
        let preview = record.preview
        let statusLine: String
        switch record.status {
        case .upcoming:
            statusLine = record.scheduledStart.map { PlanLifecycle.startsLine(scheduledStart: $0, today: Date()) } ?? "Scheduled"
        case .draft:
            statusLine = "Draft"
        case .completed, .incomplete:
            if let preview, let done = preview.completedSessions {
                statusLine = "\(done) of \(preview.plannedSessions) sessions done"
            } else {
                statusLine = record.status.label
            }
        }
        let start = record.status == .upcoming ? record.scheduledStart : record.startedAt
        // An upcoming plan's preview was rebuilt for its scheduled day (and ends on race day when
        // there is one); the week arithmetic is only the fallback for a preview built elsewhere.
        let end: Date? = record.status == .upcoming
            ? start.flatMap { s in
                preview.map { p in
                    Calendar.current.isDate(p.startDate, inSameDayAs: s)
                        ? p.endDate
                        : (Calendar.current.date(byAdding: .day, value: max(0, p.weeks * 7 - 1), to: s) ?? s)
                }
            }
            : record.endedAt
        var meta: [String] = []
        if let preview { meta.append(preview.durationLine) }
        meta.append(blueprint.frequencyLine)
        return PlanShelfCard(
            title: record.name.isEmpty ? blueprint.displayName : record.name,
            status: record.status,
            statusLine: statusLine,
            goalLine: blueprint.goalLine(),
            datesLine: start.map { datesLine(start: $0, end: end) },
            metaLine: meta.joined(separator: " · "),
            progress: nil,
            primaryAction: primaryAction(for: record),
            menu: { menuItems(for: record) })
        .onTapGesture { reviewing = ReviewTarget(kind: .shelved(record)) }
        .accessibilityAction(named: "Preview") { reviewing = ReviewTarget(kind: .shelved(record)) }
        .accessibilityIdentifier("plans-\(record.status.rawValue)")
    }

    private func datesLine(start: Date, end: Date?) -> String {
        let cal = Calendar.current
        let crossesYear = end.map { !cal.isDate(start, equalTo: $0, toGranularity: .year) } ?? false
        let longAgo = (end ?? start) < (cal.date(byAdding: .month, value: -6, to: Date()) ?? Date())
        let f: Date.FormatStyle = crossesYear || longAgo
            ? Date.FormatStyle().day().month(.abbreviated).year()
            : Date.FormatStyle().day().month(.abbreviated)
        guard let end else { return start.formatted(f) }
        return "\(start.formatted(f)) to \(end.formatted(f))"
    }

    private func primaryAction(for record: PlanShelfRecord) -> (String, () -> Void) {
        switch record.status {
        case .upcoming, .draft: ("Start now", { startNow(record) })
        case .completed, .incomplete: ("Preview", { reviewing = ReviewTarget(kind: .shelved(record)) })
        }
    }

    @ViewBuilder
    private func menuItems(for record: PlanShelfRecord) -> some View {
        Button { reviewing = ReviewTarget(kind: .shelved(record)) } label: { Label("Preview", systemImage: "eye") }
        switch record.status {
        case .draft:
            Button { onCompose(record) } label: { Label("Edit", systemImage: "pencil") }
            Button { scheduling = record } label: { Label("Schedule", systemImage: "calendar.badge.plus") }
            Button { startNow(record) } label: { Label("Start now", systemImage: "play.fill") }
            Divider()
            Button(role: .destructive) { deleting = record } label: { Label("Delete draft", systemImage: "trash") }
        case .upcoming:
            Button { onCompose(record) } label: { Label("Edit", systemImage: "pencil") }
            Button { scheduling = record } label: { Label("Change start date", systemImage: "calendar") }
            Button { startNow(record) } label: { Label("Start now", systemImage: "play.fill") }
            Divider()
            Button { moveToDrafts(record) } label: { Label("Move to drafts", systemImage: "tray.and.arrow.down") }
        case .completed, .incomplete:
            Button { startAgain(record) } label: { Label("Start again as a draft", systemImage: "arrow.counterclockwise") }
            Divider()
            Button(role: .destructive) { deleting = record } label: { Label("Remove", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func reviewActions(_ kind: ReviewTarget.Kind) -> some View {
        switch kind {
        case .current:
            pill("Manage plan") { pending = .manage; reviewing = nil }
        case .shelved(let record):
            switch record.status {
            case .draft, .upcoming:
                pill("Start now") { pending = .startNow(record); reviewing = nil }
                outline(record.status == .draft ? "Schedule" : "Change start date") { pending = .schedule(record); reviewing = nil }
                outline("Edit") { pending = .compose(record); reviewing = nil }
            case .completed, .incomplete:
                pill("Start again as a draft") { pending = .startAgain(record); reviewing = nil }
            }
        }
    }

    /// The outgoing sheet has gone: do what it asked.
    private func runPending() {
        guard let next = pending else { return }
        pending = nil
        switch next {
        case .manage: onManageCurrent()
        case .compose(let record): onCompose(record)
        case .startNow(let record): startNow(record)
        case .schedule(let record): scheduling = record
        case .scheduleDay(let record, let day): schedule(record, on: day)
        case .startAgain(let record): startAgain(record)
        case .replace(let decision):
            if decision.startsNow { activate(decision.record) } else { commitSchedule(decision.record, on: decision.startDay) }
        case .startAfter(let decision):
            commitSchedule(decision.record, on: decision.overlap.nextFreeStart)
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .raised(Capsule(), tone: .ink)
        }
        .buttonStyle(RaisedPressStyle())
    }

    private func outline(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(Capsule().stroke(Theme.ink, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    /// Starting a plan is free, like "Start a new plan" on the masthead: the free tier's boundary
    /// is the board's locked future weeks, not the act of choosing a plan. Measured against the
    /// day activation really starts (tomorrow from 21:00), so the overlap never names a cut that
    /// will not happen.
    private func startNow(_ record: PlanShelfRecord) {
        let start = PlanLifecycle.activationStart(now: Date())
        if let overlap = PlanLifecycle.overlap(current: currentSpan, proposedStart: start) {
            overlapDecision = OverlapDecision(record: record, overlap: overlap, startDay: start, startsNow: true)
            return
        }
        activate(record)
    }

    private func schedule(_ record: PlanShelfRecord, on day: Date) {
        if let overlap = PlanLifecycle.overlap(current: currentSpan, proposedStart: day) {
            overlapDecision = OverlapDecision(record: record, overlap: overlap, startDay: day, startsNow: false)
            return
        }
        commitSchedule(record, on: day)
    }

    private func commitSchedule(_ record: PlanShelfRecord, on day: Date) {
        do {
            try PlanLifecycleService.schedule(record, start: day, for: profile, in: context)
            Haptics.success()
        } catch PlanLifecycleService.Failure.scheduleMustBeInTheFuture {
            failure = "Pick a day after today. To start today, use Start now."
        } catch PlanLifecycleService.Failure.startAfterRaceDay {
            failure = "That day is after the plan's race. Pick an earlier start, or edit the race date first."
        } catch {
            failure = "The schedule could not be saved. Please try again."
        }
    }

    private func activate(_ record: PlanShelfRecord) {
        guard let blueprint = record.blueprint else { failure = "This plan could not be read."; return }
        do {
            let activation = try PlanLifecycleService.activate(blueprint, from: record, for: profile, in: context)
            PlanLifecycleService.propagate(activation, profile: profile, workouts: workouts,
                                           notifications: services.notifications, in: context)
            Haptics.success()
            onPlanChanged()
            dismiss()
        } catch PlanLifecycleService.Failure.raceDateInThePast {
            failure = "This plan's race day has passed. Edit the plan and pick a new date first."
        } catch {
            failure = "The plan could not be started. Nothing was changed."
        }
    }

    private func moveToDrafts(_ record: PlanShelfRecord) {
        do { try PlanLifecycleService.moveToDrafts(record, in: context); Haptics.light() }
        catch { failure = "The plan could not be moved. Please try again." }
    }

    private func startAgain(_ record: PlanShelfRecord) {
        do {
            let draft = try PlanLifecycleService.startAgain(record, for: profile, in: context)
            Haptics.light()
            onCompose(draft)
        } catch { failure = "The plan could not be copied. Please try again." }
    }

    private func delete(_ record: PlanShelfRecord) {
        deleting = nil
        do { try PlanLifecycleService.delete(record, in: context); Haptics.medium() }
        catch { failure = "The plan could not be removed. Please try again." }
    }
}

// MARK: - The card

/// One plan on the shelf: what it is for, when, how much, and where it stands. Same raised
/// surface as every card in the app; the status chip is ink on hairline, never a colour.
struct PlanShelfCard<MenuContent: View>: View {
    let title: String
    let status: PlanShelfStatus?
    let statusLine: String
    let goalLine: String
    let datesLine: String?
    let metaLine: String?
    let progress: Double?
    let primaryAction: (String, () -> Void)
    @ViewBuilder let menu: () -> MenuContent

    private var statusChip: some View {
        Text(statusLine)
            .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().stroke(Theme.hairline))
    }

    @ViewBuilder
    private var datesText: some View {
        if let datesLine {
            Text(datesLine)
                .font(.rounded(Theme.FontSize.label, weight: .medium)).monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(goalLine)
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Menu { menu() } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("\(title) options")
            }
            VStack(alignment: .leading, spacing: 4) {
                // Side by side while they fit; stacked at larger type, never truncated.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.sm) { statusChip; datesText }
                    VStack(alignment: .leading, spacing: 4) { statusChip; datesText }
                }
                if let metaLine {
                    Text(metaLine)
                        .font(.rounded(Theme.FontSize.label, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.hairline)
                        Capsule().fill(Theme.ink).frame(width: max(4, geo.size.width * min(1, max(0, progress))))
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
            Button(action: primaryAction.1) {
                Text(primaryAction.0)
                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14).frame(minHeight: 44)
                    .background(Capsule().stroke(Theme.ink, lineWidth: 1.25))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Schedule

/// Pick the day an upcoming plan starts. Tomorrow at the earliest; today is Start now.
struct PlanScheduleSheet: View {
    var initial: Date?
    /// The current plan's last day, offered as the natural "after it ends" default.
    var currentEnd: Date?
    /// A race plan cannot start after its race: the picker stops there.
    var latest: Date?
    var onPick: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var day: Date

    init(initial: Date?, currentEnd: Date?, latest: Date? = nil, onPick: @escaping (Date) -> Void) {
        self.initial = initial
        self.currentEnd = currentEnd
        self.latest = latest
        self.onPick = onPick
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        self.earliest = tomorrow
        let afterCurrent = currentEnd.flatMap { cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: $0)) }
        var pick = initial.map { max($0, tomorrow) } ?? afterCurrent.map { max($0, tomorrow) } ?? tomorrow
        if let latest, cal.startOfDay(for: latest) >= tomorrow { pick = min(pick, cal.startOfDay(for: latest)) }
        _day = State(initialValue: pick)
    }

    /// Fixed when the sheet opens, so a sheet left up over midnight keeps one consistent range
    /// (the service re-checks the day on confirm either way).
    private let earliest: Date

    /// Up to race day when there is one (a race tomorrow leaves exactly one day), two years
    /// otherwise. Never a day after the race: the service refuses it, so the picker does too.
    private var range: ClosedRange<Date> {
        let cal = Calendar.current
        if let latest { return earliest...max(earliest, cal.startOfDay(for: latest)) }
        return earliest...(cal.date(byAdding: .year, value: 2, to: earliest) ?? earliest)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("The plan starts on this day and the week is built around it. Drafts never start on their own.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                DatePicker("Start", selection: $day, in: range, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(Theme.ink)
                    .accessibilityIdentifier("plans-schedule-day")
                if let currentEnd {
                    Text("Your current plan runs until \(currentEnd.formatted(.dateTime.day().month(.abbreviated))).")
                        .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                }
                Spacer(minLength: 0)
                Button {
                    onPick(day)
                    dismiss()
                } label: {
                    Text("Schedule for \(day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))")
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .raised(Capsule(), tone: .ink)
                }
                .buttonStyle(RaisedPressStyle())
                .accessibilityIdentifier("plans-schedule-confirm")
            }
            .padding(Theme.Space.lg)
            .background(Theme.background)
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Overlap

/// The one decision a switch needs: what happens to the plan already on the calendar. Shows the
/// cut in dates and sessions; nothing is discarded silently, the replaced plan lands in Previous.
struct PlanOverlapSheet: View {
    let planName: String
    let currentName: String
    let overlap: PlanLifecycle.Overlap
    /// The day the new plan would start.
    let startDay: Date
    var onReplace: () -> Void
    var onStartAfter: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var dayWord: String {
        let cal = Calendar.current
        if cal.isDateInToday(startDay) { return "today" }
        if cal.isDateInTomorrow(startDay) { return "tomorrow" }
        return startDay.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("\(currentName) runs until \(overlap.currentEnd.formatted(.dateTime.day().month(.abbreviated))).")
                        .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(cutLine)
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if overlap.cutsGoalRace, let race = overlap.raceDate {
                        Text("Its goal race on \(race.formatted(.dateTime.day().month(.abbreviated))) would no longer be on your plan.")
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

                VStack(spacing: Theme.Space.sm) {
                    choice("Replace it from \(dayWord)",
                           detail: "\(currentName) moves to your previous plans as incomplete. Everything you completed stays.",
                           filled: false) { onReplace(); dismiss() }
                    choice("Start after it ends, \(overlap.nextFreeStart.formatted(.dateTime.day().month(.abbreviated)))",
                           detail: "\(planName) is scheduled for the day after \(currentName) finishes.",
                           filled: true) { onStartAfter(); dismiss() }
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.lg)
            .background(Theme.background)
            .navigationTitle("Two plans overlap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    private var cutLine: String {
        let span = overlap.daysCut < 7
            ? (overlap.daysCut == 1 ? "last day" : "last \(overlap.daysCut) days")
            : (overlap.weeksCut == 1 ? "last week" : "last \(overlap.weeksCut) weeks")
        guard overlap.sessionsCut > 0 else { return "Starting \(planName) \(dayWord) cuts its \(span)." }
        let sessions = overlap.sessionsCut == 1 ? "1 session" : "\(overlap.sessionsCut) sessions"
        return "Starting \(planName) \(dayWord) cuts its \(span), \(sessions) still to do."
    }

    private func choice(_ title: String, detail: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.rounded(Theme.FontSize.body, weight: .bold))
                    .foregroundStyle(filled ? Theme.background : Theme.ink)
                Text(detail)
                    .font(.rounded(Theme.FontSize.label, weight: .medium))
                    .foregroundStyle(filled ? Theme.background.opacity(0.8) : Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md)
            .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous), tone: filled ? .ink : .white)
        }
        .buttonStyle(RaisedPressStyle())
    }
}
