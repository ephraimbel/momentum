import SwiftUI
import SwiftData

/// Manage plan (2026-09-07, docs/PLAN-AND-FUEL-UPGRADE.md §2.3): every adjustment the coach can
/// make, organised by what the athlete means. My schedule · My training · Something changed ·
/// My goal. Each row leads to one proposal (`PlanAdjustmentService`) with the affected dates,
/// the before and after, one explanation and Apply / Cancel; an applied change shows its receipt
/// with Undo. Nothing here computes a plan; it asks the same engine the coach chat asks.
///
/// Free to read, Pro to apply: the gate lives on the proposal's Apply, and the proposal sheet
/// hosts the paywall itself (a cover raised from the root would tear these sheets down).
/// A Manage-plan apply and its undo: held by the Plan tab so it outlives the sheet.
struct ManageReceipt: Equatable {
    var receipt: CoachActions.Receipt
    var undo: String?
    var signature: Int
    static func == (a: ManageReceipt, b: ManageReceipt) -> Bool { a.signature == b.signature && a.undo == b.undo }
}

struct ManagePlanView: View {
    let profile: UserProfile
    let distanceUnit: DistanceUnit
    /// The complete plan-settings form (race, date, goal time, distance, split).
    var onOpenSettings: () -> Void
    /// The shelf, for switching plans.
    var onOpenYourPlans: () -> Void
    /// Away days are a week-shaped edit the board owns.
    var onAwayDays: () -> Void
    /// The library (session alternatives) is opened by the board.
    var onOpenLibrary: () -> Void
    /// The caller re-reads the plan after an applied change.
    var onPlanChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    /// Bounded: the load-increase rule reads the trailing weeks, never the whole history.
    @Query(ManagePlanView.recentWorkouts) private var workouts: [Workout]

    private static var recentWorkouts: FetchDescriptor<Workout> {
        var d = FetchDescriptor<Workout>(sortBy: [SortDescriptor(\Workout.startedAt, order: .reverse)])
        d.fetchLimit = 300
        return d
    }

    /// The proposal on screen. Set directly by rows that need no input; set through
    /// `pendingRequest` by the pickers, which hand it over as they dismiss (two sibling sheets
    /// swapped in one tick is the presentation race the codebase documents).
    @State private var request: PlanAdjustmentService.Request? {
        didSet { if request != nil { PerfMark.start("proposal-ready") } }
    }
    @State private var pendingRequest: PlanAdjustmentService.Request?
    @State private var picker: Picker?
    @State private var showInjury = false
    /// The last applied change and its undo, held by the Plan tab so it survives Done and a
    /// reopen (the chat's undo lives on its message; this one lived and died with the sheet).
    @Binding var applied: ManageReceipt?
    @State private var failure: String?
    /// Row availability, computed off the body: the load rules walk recent workouts.
    @State private var unavailable: [Row: String] = [:]
    /// The plan's signature, refreshed with availability rather than hashed in every body pass.
    @State private var currentSignature: Int = 0
    /// Sessions the reconciler rolled forward or left missed, counted with availability.
    @State private var missedCount = 0

    private enum Picker: String, Identifiable {
        case days, sessionLength, move, pause, equipment
        var id: String { rawValue }
    }

    private enum Row: Hashable { case easePlan, bump, easePaces, easeThisWeek, pause, move, unwell, equipment }

    private var plan: TrainingPlan? { profile.plan }
    private var today: Date { Date() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if let applied { receiptCard(applied) }
                    if plan == nil {
                        quiet("There is no current plan to adjust.")
                        section("Your plans") {
                            row("square.stack", "Your plans", "Create a plan, or start a draft", last: true) { onOpenYourPlans() }
                        }
                    } else {
                        if plan?.isSelfCoached == true {
                            quiet("You are coaching this plan yourself. Schedule edits still work; the coach does not reshape the week.")
                        }
                        scheduleSection
                        trainingSection
                        somethingChangedSection
                        goalSection
                    }
                }
                .padding(Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxl)
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("manage plan").font(.display(20, weight: .bold)).foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
            .sheet(item: $request) { r in
                PlanProposalSheet(request: r, profile: profile, workouts: workouts, distanceUnit: distanceUnit) { result in
                    switch result {
                    case .applied(let receipt, let undo):
                        let signature = PlanAdjustmentService.signature(of: profile.plan)
                        applied = ManageReceipt(receipt: receipt, undo: undo, signature: signature)
                        currentSignature = signature
                        onPlanChanged()
                        refreshAvailability()
                    case .declined:
                        break
                    }
                }
            }
            .sheet(item: $picker, onDismiss: {
                if let r = pendingRequest {
                    pendingRequest = nil
                    request = r
                }
            }) { which in
                switch which {
                case .days: DaysPickerSheet(days: profile.daysPerWeek, preferred: profile.preferredDays) { days, preferred in
                    stage(.changeDays(daysPerWeek: days, preferredDays: preferred),
                          title: "Change my training days", request: daysRequest(days, preferred))
                }
                case .sessionLength: SessionLengthSheet(minutes: profile.sessionMinutes) { minutes in
                    stage(.changeSessionLength(minutes: minutes), title: "Change session time",
                          request: "I have about \(minutes) minutes per session")
                }
                case .move: MoveSessionSheet(plan: plan, distanceUnit: distanceUnit) { session, day in
                    stage(.moveSession(id: session.id, to: day), title: "Move a session",
                          request: "Move \(PlanCoaching.brief(for: session, distanceUnit: distanceUnit)) to \(day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))")
                }
                case .pause: PausePickerSheet { days in
                    stage(.pausePlan(days: days), title: "Pause my plan",
                          request: "I need \(days) day\(days == 1 ? "" : "s") off")
                }
                case .equipment: EquipmentPickerSheet(equipment: profile.equipment) { equipment in
                    stage(.changeEquipment(equipment), title: "Change my equipment",
                          request: "I now train with \(equipmentLabel(equipment).lowercased())")
                }
                }
            }
            .sheet(isPresented: $showInjury, onDismiss: {
                // The injury loop writes the plan itself; mirror it downstream and re-read the rows.
                PlanAdjustmentService.propagate(profile: profile, workouts: workouts, notifications: services.notifications)
                onPlanChanged()
                refreshAvailability()
            }) { InjuryReportSheet(profile: profile) }
            .alert("That didn’t work", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "Please try again.") }
            // After the sheet has landed: the availability pass walks the plan several times and
            // builds the load insights over 300 workouts, which under the presentation spring is
            // a visible hitch. Rows read as available until then (a tap re-checks anyway).
            .task {
                try? await Task.sleep(for: .milliseconds(350))
                refreshAvailability()
            }
        }
        .nestedPaywallHost()
        .onAppear { PerfMark.end("manage-open") }
        .presentationDetents([.large])
    }

    // MARK: - Sections

    private var scheduleSection: some View {
        section("My schedule") {
            row("calendar", "Training days", "\(profile.daysPerWeek) days a week\(preferredLine)") { picker = .days }
            row("clock", "Time per session", "About \(profile.sessionMinutes) minutes") { picker = .sessionLength }
            row("arrow.left.arrow.right", "Move a session", unavailable[.move] ?? "Pick a session and its new day") { picker = .move }
            row("airplane", "I'm away some days", "Mark the days; the week moves around them", last: true) { onAwayDays() }
        }
    }

    private var trainingSection: some View {
        section("My training") {
            row("arrow.down.right", "Ease the rest of the plan",
                unavailable[.easePlan] ?? "Every remaining session about 15% lighter; hard and long runs become easy runs") {
                request = .init(intent: .easeWeek, title: "Ease the rest of the plan", request: "Make the rest of my plan lighter")
            }
            row("arrow.up.right", "Raise the load",
                unavailable[.bump] ?? "About 10% more, now that your training has earned it") {
                request = .init(intent: .bumpLoad, title: "Raise the load", request: "I can handle more")
            }
            row("speedometer", "Ease my paces",
                unavailable[.easePaces] ?? "Target paces about 2% easier on future runs") {
                request = .init(intent: .easePaces, title: "Ease my paces", request: "The paces feel too hard")
            }
            row("dumbbell", "Strength & equipment",
                unavailable[.equipment] ?? "\(profile.disciplines.contains(Discipline.strength.rawValue) ? "Strength on · " : "")\(equipmentLabel(profile.equipment))") { picker = .equipment }
            row("books.vertical", "Swap in a library session", "Guided sessions priced to your paces", last: true) { onOpenLibrary() }
        }
    }

    private var somethingChangedSection: some View {
        section("Something changed") {
            row("calendar.badge.minus", "This week is heavy",
                unavailable[.easeThisWeek] ?? "The next seven days about 15% lighter; the long run keeps its place") {
                request = .init(intent: .easeThisWeek, title: "Lighten this week", request: "This week got away from me")
            }
            row("figure.walk.motion", "I missed some training", missedLine) {
                request = .init(intent: .easeThisWeek, title: "Lighten this week", request: "I missed training and want an easier way back")
            }
            if let until = plan?.pausedUntil, Calendar.current.startOfDay(for: until) > Calendar.current.startOfDay(for: today) {
                row("play.fill", "Resume my plan", "Paused until \(until.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))") {
                    request = .init(intent: .resumePlan, title: "Resume my plan", request: "I'm back")
                }
            } else {
                row("pause.circle", "Pause and come back", unavailable[.pause] ?? "Travel, life. Everything shifts later; race day stays") { picker = .pause }
            }
            row("thermometer.variable", "I'm not feeling well", unavailable[.unwell] ?? "Pause three days, nothing is lost") {
                request = .init(intent: .pausePlan(days: 3), title: "I'm not feeling well", request: "I'm unwell and need a few days")
            }
            row("bandage", "Something hurts", "Train around it, with a gated way back", last: true) { showInjury = true }
        }
    }

    private var goalSection: some View {
        section("My goal") {
            row("flag.checkered", "Race, date and goal time", PlanBlueprint(profile: profile).goalLine()) { onOpenSettings() }
            row("arrow.triangle.2.circlepath", plan?.raceDate == nil ? "Start the next block now" : "Rebuild from today",
                plan?.raceDate == nil ? "Closes this block and builds the next from what you actually ran" : "A fresh build toward your race from where you are") {
                request = .init(intent: .renewBlock, title: plan?.raceDate == nil ? "Start the next block" : "Rebuild from today",
                                request: "Rebuild my plan from where I am")
            }
            row("square.stack", "Switch to another plan", "Drafts, upcoming and previous plans", last: true) { onOpenYourPlans() }
        }
    }

    private var preferredLine: String {
        guard !profile.preferredDays.isEmpty else { return "" }
        let symbols = Calendar.current.shortWeekdaySymbols
        let days = profile.preferredDays
            .filter { (1...7).contains($0) }
            .sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }
            .map { symbols[$0 - 1] }
        return days.isEmpty ? "" : " · " + days.joined(separator: " ")
    }

    private var missedLine: String {
        guard plan != nil else { return "" }
        // Counted with availability, never per body pass.
        let missed = missedCount
        if missed == 0 { return "Missed sessions roll forward on their own. Lighten the week if you need a gentler way back" }
        return "\(missed) rolled forward already. Lighten the week for a gentler way back"
    }

    private func daysRequest(_ days: Int?, _ preferred: [Int]?) -> String {
        var parts: [String] = []
        if let days { parts.append("\(days) days a week") }
        if let preferred, !preferred.isEmpty {
            let symbols = Calendar.current.shortWeekdaySymbols
            parts.append(preferred.filter { (1...7).contains($0) }.map { symbols[$0 - 1] }.joined(separator: ", "))
        } else if preferred != nil {
            parts.append("any days")
        }
        return "I can train " + parts.joined(separator: " on ")
    }

    private func equipmentLabel(_ e: Equipment) -> String {
        switch e {
        case .fullGym: "Full gym"
        case .dumbbellsOnly: "Dumbbells only"
        case .homeMinimal: "Home minimal"
        case .bodyweight: "Bodyweight"
        }
    }

    // MARK: - Proposals

    /// A picker's choice becomes a proposal once the picker has gone.
    private func stage(_ intent: CoachIntent, title: String, request: String) {
        pendingRequest = .init(intent: intent, title: title, request: request)
    }

    /// The reasons a row cannot apply right now, computed once per plan change rather than in body.
    private func refreshAvailability() {
        var next: [Row: String] = [:]
        let checks: [(Row, CoachIntent)] = [(.easePlan, .easeWeek), (.bump, .bumpLoad), (.easePaces, .easePaces),
                                            (.easeThisWeek, .easeThisWeek), (.pause, .pausePlan(days: 3)),
                                            (.unwell, .pausePlan(days: 3)), (.equipment, .changeEquipment(profile.equipment))]
        for (row, intent) in checks {
            if PlanAdjustmentService.blocked(intent, profile: profile, workouts: workouts, today: today) != nil {
                next[row] = switch row {
                case .bump: "Not earned yet, or used this week"
                case .unwell: "Already paused; resume first"
                case .equipment: "No strength days on this plan"
                default: "Not available right now; tap to see why"
                }
            }
        }
        // The move picker would open on an empty list: say so on the row instead.
        if let plan, !plan.sessions.contains(where: { s in
            s.status != .completed && s.completedWorkout == nil
                && s.date >= Calendar.current.startOfDay(for: today)
                && s.date < (Calendar.current.date(byAdding: .day, value: 14, to: Calendar.current.startOfDay(for: today)) ?? today)
        }) {
            next[.move] = "Nothing open in the next two weeks"
        }
        unavailable = next
        missedCount = plan?.sessions.filter { $0.status == .missed || $0.status == .moved }.count ?? 0
        // The signature is only read by the receipt card; hashing every session for a page with
        // no receipt is waste.
        if applied != nil { currentSignature = PlanAdjustmentService.signature(of: profile.plan) }
    }

    private func receiptCard(_ applied: ManageReceipt) -> some View {
        let canUndo = applied.undo != nil && currentSignature == applied.signature
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                    .accessibilityHidden(true)
                Text(applied.receipt.headline).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
            }
            Text(applied.receipt.detail)
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if canUndo {
                Button { undo(applied) } label: {
                    Text("Undo")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .background(Capsule().stroke(Theme.ink, lineWidth: 1.25))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("manage-undo")
            } else if applied.undo != nil {
                Text("The plan changed again since, so this one can no longer be undone on its own.")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityIdentifier("manage-receipt")
    }

    private func undo(_ applied: ManageReceipt) {
        guard let json = applied.undo else { return }
        if PlanAdjustmentService.undo(json, profile: profile, workouts: workouts,
                                      notifications: services.notifications, in: context) {
            Haptics.light()
            self.applied = nil
            onPlanChanged()
            refreshAvailability()
        } else {
            failure = "That could not be rolled back cleanly. Your plan is safe; adjust it again if it is not what you want."
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title.uppercased())
                .font(.rounded(10, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
                .padding(.leading, Theme.Space.xs)
            VStack(spacing: 0) { content() }
                .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    private func row(_ icon: String, _ title: String, _ subtitle: String, last: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(subtitle).font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(Theme.Space.md)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if !last {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 56)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - The proposal

/// One change, decided with the facts in front of the athlete. The proposal is computed AFTER the
/// sheet is up (a rebuild preview runs the generator), Apply goes through the same engine and
/// throttle the coach chat uses, a plan that changed underneath is recomputed, never applied
/// stale, and the Pro gate lives here, on Apply, with the paywall hosted by this sheet.
struct PlanProposalSheet: View {
    enum Result { case applied(CoachActions.Receipt, undo: String?), declined }

    let request: PlanAdjustmentService.Request
    let profile: UserProfile
    let workouts: [Workout]
    let distanceUnit: DistanceUnit
    var onResult: (Result) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @Environment(PaywallController.self) private var paywall
    @State private var proposal: PlanAdjustmentService.Proposal?
    @State private var declined: String?
    @State private var recomputed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.title).font(.display(Theme.FontSize.headline, weight: .heavy)).foregroundStyle(Theme.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text("“\(request.request)”")
                            .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let proposal {
                        proposalContent(proposal)
                    } else {
                        HStack(spacing: Theme.Space.sm) {
                            ProgressView().tint(Theme.ink)
                            Text("Working out what changes")
                                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                        }
                        .padding(.vertical, Theme.Space.lg)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("proposal-working")
                    }
                    if let declined {
                        Text(declined).font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Theme.Space.lg)
            }
            .background(Theme.background)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: Theme.Space.sm) {
                    Button { onResult(.declined); dismiss() } label: {
                        Text("Cancel").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity).frame(minHeight: 52)
                            .background(Capsule().stroke(Theme.ink, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    Button { apply() } label: {
                        Text("Apply").font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity).frame(minHeight: 52)
                            .raised(Capsule(), tone: .ink)
                    }
                    .buttonStyle(RaisedPressStyle())
                    .disabled(!(proposal?.isAvailable ?? false) || declined != nil)
                    .opacity((proposal?.isAvailable ?? false) && declined == nil ? 1 : 0.45)
                    .accessibilityIdentifier("proposal-apply")
                }
                .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm)
                .background(Theme.background.opacity(0.96))
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("proposal").font(.display(20, weight: .bold)).foregroundStyle(Theme.ink)
                }
            }
            // After the sheet has landed: a rebuild proposal runs the full generator, and
            // "Working out what changes" is the designed state for that beat, not a freeze under
            // the presentation spring.
            .task {
                try? await Task.sleep(for: .milliseconds(150))
                compute()
            }
            // Bought from the sheet: the change they were applying applies, no second tap.
            .onChange(of: paywall.isPro) { _, pro in
                if pro, proposal?.isAvailable == true, declined == nil { apply() }
            }
        }
        .nestedPaywallHost()
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func proposalContent(_ proposal: PlanAdjustmentService.Proposal) -> some View {
        if recomputed {
            Text("Your plan changed since this was worked out, so here is the fresh read.")
                .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let blocked = proposal.blocked {
            card("NOT RIGHT NOW") {
                Text(blocked).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let affected = proposal.affected {
            card("WHAT IT TOUCHES") {
                let f = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
                let same = Calendar.current.isDate(affected.from, inSameDayAs: affected.to)
                Text("\(affected.sessions) session\(affected.sessions == 1 ? "" : "s") · \(same ? affected.from.formatted(f) : "\(affected.from.formatted(f)) to \(affected.to.formatted(f))")")
                    .font(.rounded(Theme.FontSize.body, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                Text("Completed sessions are never touched.")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
        }
        if !proposal.lines.isEmpty {
            card("BEFORE AND AFTER") {
                ForEach(Array(proposal.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if !proposal.explanation.isEmpty {
            card("WHY") {
                Text(proposal.explanation).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let change = proposal.outlookChange {
            card("YOUR RACE") {
                Text(change).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
            }
        }
    }

    private func compute() {
        let fresh = PlanAdjustmentService.proposal(for: request, profile: profile, workouts: workouts,
                                                   distanceUnit: distanceUnit, in: context)
        withAnimation(Motion.crossfade) { proposal = fresh }
        PerfMark.end("proposal-ready")
    }

    private func apply() {
        guard let proposal else { return }
        // Free to read the coach's thinking, Pro to apply it (the same line the chat draws).
        guard paywall.isEntitled(to: .aiCoach) else { paywall.present(for: .aiCoach); return }
        switch PlanAdjustmentService.apply(proposal, profile: profile, workouts: workouts,
                                           notifications: services.notifications, distanceUnit: distanceUnit,
                                           in: context) {
        case .applied(let receipt, let undo):
            Haptics.success()
            onResult(.applied(receipt, undo: undo))
            dismiss()
        case .declined(let reason):
            declined = reason
        case .stale(let fresh):
            withAnimation(Motion.crossfade) {
                self.proposal = fresh
                declined = nil
                recomputed = true
            }
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).font(.rounded(10, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            content()
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

// MARK: - Pickers

private struct PickerFrame<Content: View>: View {
    let title: String
    let confirm: String
    var enabled = true
    let onConfirm: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) { content() }
                    .padding(Theme.Space.lg)
            }
            .background(Theme.background)
            .safeAreaInset(edge: .bottom) {
                Button { onConfirm() } label: {
                    Text(confirm).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity).frame(minHeight: 52)
                        .raised(Capsule(), tone: .ink)
                }
                .buttonStyle(RaisedPressStyle())
                .disabled(!enabled).opacity(enabled ? 1 : 0.45)
                .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm)
                .background(Theme.background.opacity(0.96))
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

/// Equal cells in one row while they fit, wrapped cells at larger type (the wrap-never-scroll rule).
private func choiceRow(_ values: [Int], current: Int, label: @escaping (Int) -> String,
                       spoken: @escaping (Int) -> String, _ set: @escaping (Int) -> Void) -> some View {
    ViewThatFits(in: .horizontal) {
        HStack(spacing: Theme.Space.sm) {
            ForEach(values, id: \.self) { v in
                choiceCell(v, on: current == v, label: label, spoken: spoken, set: set)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        FlowLayout(spacing: Theme.Space.sm) {
            ForEach(values, id: \.self) { v in
                choiceCell(v, on: current == v, label: label, spoken: spoken, set: set)
            }
        }
    }
}

private func choiceCell(_ v: Int, on: Bool, label: @escaping (Int) -> String,
                        spoken: @escaping (Int) -> String, set: @escaping (Int) -> Void) -> some View {
    Button { Haptics.selection(); set(v) } label: {
        Text(label(v))
            .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity).frame(minHeight: 50)
            .foregroundStyle(on ? Theme.background : Theme.ink)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                if !on { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline) }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(spoken(v))
    .accessibilityAddTraits(on ? .isSelected : [])
}

private struct DaysPickerSheet: View {
    @State var days: Int
    @State var preferred: [Int]
    let initialDays: Int
    let initialPreferred: [Int]
    var onPick: (Int?, [Int]?) -> Void
    @Environment(\.dismiss) private var dismiss

    init(days: Int, preferred: [Int], onPick: @escaping (Int?, [Int]?) -> Void) {
        _days = State(initialValue: days)
        _preferred = State(initialValue: preferred)
        initialDays = days
        initialPreferred = preferred
        self.onPick = onPick
    }

    private var changed: Bool { days != initialDays || Set(preferred) != Set(initialPreferred) }
    /// The scheduler honours chosen days only when there are at least as many as the week has
    /// sessions; fewer and it spreads the week itself. Say so instead of storing a choice it ignores.
    private var tooFewChosen: Bool { !preferred.isEmpty && preferred.count < days }

    var body: some View {
        PickerFrame(title: "Training days", confirm: "See the change", enabled: changed && !tooFewChosen, onConfirm: {
            onPick(days == initialDays ? nil : days, Set(preferred) == Set(initialPreferred) ? nil : preferred)
            dismiss()
        }) {
            Text("DAYS A WEEK").font(.rounded(10, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            choiceRow([2, 3, 4, 5, 6], current: days, label: { "\($0)" }, spoken: { "\($0) days a week" }) { days = $0 }
            Text("WHICH DAYS").font(.rounded(10, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            let symbols = Calendar.current.shortWeekdaySymbols
            HStack(spacing: 6) {
                ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { weekday in
                    let on = preferred.contains(weekday)
                    Button {
                        Haptics.selection()
                        if on { preferred.removeAll { $0 == weekday } } else { preferred.append(weekday) }
                    } label: {
                        Text(String(symbols[weekday - 1].prefix(2)).uppercased())
                            .font(.rounded(Theme.FontSize.label, weight: .bold))
                            .foregroundStyle(on ? Theme.background : Theme.ink)
                            .frame(maxWidth: .infinity).frame(minHeight: 44)
                            .background { if on { Capsule().fill(Theme.ink) } else { Capsule().stroke(Theme.hairline) } }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbols[weekday - 1])
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Text(tooFewChosen
                 ? "Pick at least \(days) days, or leave them all off and the coach spreads the week."
                 : (preferred.isEmpty ? "No fixed days: the coach spreads the week."
                    : "The long run lands on Sunday when it is chosen, else Saturday, else the chosen day with the most rest after it."))
                .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(tooFewChosen ? Theme.ink : Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SessionLengthSheet: View {
    @State var minutes: Int
    let initial: Int
    var onPick: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    init(minutes: Int, onPick: @escaping (Int) -> Void) {
        _minutes = State(initialValue: minutes); initial = minutes; self.onPick = onPick
    }

    var body: some View {
        PickerFrame(title: "Time per session", confirm: "See the change", enabled: minutes != initial,
                    onConfirm: { onPick(minutes); dismiss() }) {
            choiceRow([30, 45, 60, 75, 90], current: minutes, label: { "\($0)m" }, spoken: { "\($0) minutes" }) { minutes = $0 }
            Text("Runs that would not fit are capped to the time; the long run keeps its place in the week.")
                .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PausePickerSheet: View {
    @State private var days = 3
    var onPick: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PickerFrame(title: "Pause", confirm: "See the change", onConfirm: { onPick(days); dismiss() }) {
            choiceRow([2, 3, 5, 7, 10, 14], current: days, label: { "\($0)" }, spoken: { "\($0) days" }) { days = $0 }
            Text("Days. Everything upcoming shifts later; race day and any tune-up stay where they are.")
                .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct EquipmentPickerSheet: View {
    @State var equipment: Equipment
    let initial: Equipment
    var onPick: (Equipment) -> Void
    @Environment(\.dismiss) private var dismiss

    init(equipment: Equipment, onPick: @escaping (Equipment) -> Void) {
        _equipment = State(initialValue: equipment); initial = equipment; self.onPick = onPick
    }

    var body: some View {
        let opts: [(Equipment, String, String)] = [
            (.fullGym, "Full gym", "building.2"), (.dumbbellsOnly, "Dumbbells only", "dumbbell"),
            (.homeMinimal, "Home minimal", "house"), (.bodyweight, "Bodyweight", "figure.cooldown")]
        PickerFrame(title: "Equipment", confirm: "See the change", enabled: equipment != initial,
                    onConfirm: { onPick(equipment); dismiss() }) {
            ForEach(opts, id: \.0) { o in
                SelectionCard(title: o.1, systemImage: o.2, isSelected: equipment == o.0) { equipment = o.0 }
            }
            Text("Strength days are rebuilt with exercises you can do. Running days are rebuilt the same way they were.")
                .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Pick one open session in the next two weeks, then its new day.
private struct MoveSessionSheet: View {
    let plan: TrainingPlan?
    let distanceUnit: DistanceUnit
    var onPick: (PlannedSession, Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: PlannedSession?
    @State private var day: Date?

    private var open: [PlannedSession] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let horizon = cal.date(byAdding: .day, value: 14, to: today) ?? today
        return (plan?.sessions ?? [])
            .filter { ($0.status == .planned || $0.status == .moved) && $0.completedWorkout == nil
                      && $0.date >= today && $0.date <= horizon && !PlanCoaching.isFixedDate($0) }
            .sorted { $0.date < $1.date }
    }

    private var days: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<14).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    @ReducedMotionPreference private var reduceMotion
    /// Days that hold a race or a tune-up: never a drop target.
    private var fixedDays: [Date] { (plan?.sessions ?? []).filter { PlanCoaching.isFixedDate($0) }.map(\.date) }

    var body: some View {
        PickerFrame(title: "Move a session", confirm: "See the change",
                    enabled: chosen != nil && day != nil,
                    onConfirm: { if let chosen, let day { onPick(chosen, day) }; dismiss() }) {
            if open.isEmpty {
                Text("Nothing open in the next two weeks.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            } else {
                Text("WHICH SESSION").font(.rounded(10, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
                ForEach(open, id: \.id) { s in
                    SelectionCard(title: PlanCoaching.brief(for: s, distanceUnit: distanceUnit),
                                  subtitle: s.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)),
                                  isSelected: chosen?.id == s.id) {
                        withAnimation(reduceMotion ? nil : Motion.standard) {
                            chosen = s
                            day = nil   // a day chosen for another session is not this one's
                        }
                    }
                }
                if let chosen {
                    Text("TO WHICH DAY").font(.rounded(10, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
                    FlowLayout(spacing: Theme.Space.sm) {
                        ForEach(days, id: \.self) { d in
                            let same = Calendar.current.isDate(d, inSameDayAs: chosen.date)
                            // Race day and a tune-up hold their own date: nothing moves onto them.
                            let fixed = fixedDays.contains { Calendar.current.isDate($0, inSameDayAs: d) }
                            let on = day.map { Calendar.current.isDate($0, inSameDayAs: d) } ?? false
                            Button { Haptics.selection(); day = d } label: {
                                Text(d.formatted(.dateTime.weekday(.abbreviated).day()))
                                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(on ? Theme.background : (same || fixed ? Theme.inkTertiary : Theme.ink))
                                    .padding(.horizontal, 12).frame(minHeight: 44)
                                    .background { if on { Capsule().fill(Theme.ink) } else { Capsule().stroke(Theme.hairline) } }
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(same || fixed)
                            .accessibilityLabel(d.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    Text("A day that already holds a session keeps both; the proposal says so.")
                        .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                }
            }
        }
    }
}
