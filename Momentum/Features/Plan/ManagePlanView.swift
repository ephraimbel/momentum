import SwiftUI
import SwiftData

/// Manage plan (2026-09-07, docs/PLAN-AND-FUEL-UPGRADE.md §2.3): every adjustment the coach can
/// make, organised by what the athlete means. My schedule · My training · Something changed ·
/// My goal. Each row leads to one proposal (`PlanAdjustmentService`) with the affected dates,
/// the before and after, one explanation and Apply / Cancel; an applied change shows its receipt
/// with Undo. Nothing here computes a plan; it asks the same engine the coach chat asks.
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
    @Environment(PaywallController.self) private var paywall
    @Query(sort: \Workout.startedAt, order: .reverse) private var workouts: [Workout]

    @State private var proposal: PlanAdjustmentService.Proposal?
    @State private var picker: Picker?
    @State private var showInjury = false
    @State private var applied: Applied?
    @State private var failure: String?

    private enum Picker: String, Identifiable {
        case days, sessionLength, move, pause, equipment
        var id: String { rawValue }
    }

    private struct Applied: Equatable {
        var receipt: CoachActions.Receipt
        var undo: String?
        var signature: Int
        static func == (a: Applied, b: Applied) -> Bool { a.signature == b.signature && a.undo == b.undo }
    }

    private var plan: TrainingPlan? { profile.plan }
    private var today: Date { Date() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if let applied { receiptCard(applied) }
                    if plan == nil {
                        quiet("There is no current plan to adjust.")
                        row("square.stack", "Your plans", "Create a plan, or start a draft") { onOpenYourPlans() }
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
            .sheet(item: $proposal) { p in
                PlanProposalSheet(proposal: p, profile: profile, workouts: workouts, distanceUnit: distanceUnit) { result in
                    switch result {
                    case .applied(let receipt, let undo):
                        applied = Applied(receipt: receipt, undo: undo,
                                          signature: PlanAdjustmentService.signature(of: profile.plan))
                        onPlanChanged()
                    case .declined:
                        break
                    }
                }
            }
            .sheet(item: $picker) { which in
                switch which {
                case .days: DaysPickerSheet(days: profile.daysPerWeek, preferred: profile.preferredDays) { days, preferred in
                    propose(.changeDays(daysPerWeek: days, preferredDays: preferred),
                            title: "Change my training days", request: daysRequest(days, preferred))
                }
                case .sessionLength: SessionLengthSheet(minutes: profile.sessionMinutes) { minutes in
                    propose(.changeSessionLength(minutes: minutes), title: "Change session time",
                            request: "I have about \(minutes) minutes per session")
                }
                case .move: MoveSessionSheet(plan: plan, distanceUnit: distanceUnit) { session, day in
                    propose(.moveSession(id: session.id, to: day), title: "Move a session",
                            request: "Move \(PlanCoaching.brief(for: session, distanceUnit: distanceUnit)) to \(day.formatted(.dateTime.weekday(.wide)))")
                }
                case .pause: PausePickerSheet { days in
                    propose(.pausePlan(days: days), title: "Pause my plan",
                            request: "I need \(days) day\(days == 1 ? "" : "s") off")
                }
                case .equipment: EquipmentPickerSheet(equipment: profile.equipment) { equipment in
                    propose(.changeEquipment(equipment), title: "Change my equipment",
                            request: "I now train with \(equipmentLabel(equipment).lowercased())")
                }
                }
            }
            .sheet(isPresented: $showInjury, onDismiss: onPlanChanged) { InjuryReportSheet(profile: profile) }
            .alert("That didn’t work", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "Please try again.") }
        }
        .presentationDetents([.large])
    }

    // MARK: - Sections

    private var scheduleSection: some View {
        section("My schedule") {
            row("calendar", "Training days", "\(profile.daysPerWeek) days a week\(preferredLine)") { picker = .days }
            row("clock", "Time per session", "About \(profile.sessionMinutes) minutes") { picker = .sessionLength }
            row("arrow.left.arrow.right", "Move a session", "Pick a session and its new day") { picker = .move }
            row("airplane", "I'm away some days", "Mark the days; the week moves around them") { onAwayDays() }
        }
    }

    private var trainingSection: some View {
        section("My training") {
            let easeBlocked = PlanAdjustmentService.blocked(.easeWeek, profile: profile, workouts: workouts, today: today)
            row("arrow.down.right", "Ease the coming sessions", easeBlocked == nil ? "About 15% lighter, hard days soften" : "Not available this week") {
                propose(.easeWeek, title: "Ease the coming sessions", request: "Make the coming sessions lighter")
            }
            let bumpBlocked = PlanAdjustmentService.blocked(.bumpLoad, profile: profile, workouts: workouts, today: today)
            row("arrow.up.right", "Raise the load", bumpBlocked == nil ? "About 10% more, when your training has earned it" : "Not earned yet, or used this week") {
                propose(.bumpLoad, title: "Raise the load", request: "I can handle more")
            }
            row("speedometer", "Ease my paces", "Target paces about 2% easier on future runs") {
                propose(.easePaces, title: "Ease my paces", request: "The paces feel too hard")
            }
            row("dumbbell", "Strength & equipment", "\(profile.disciplines.contains(Discipline.strength.rawValue) ? "Strength on · " : "")\(equipmentLabel(profile.equipment))") { picker = .equipment }
            row("books.vertical", "Swap in a library session", "Guided sessions priced to your paces") { onOpenLibrary() }
        }
    }

    private var somethingChangedSection: some View {
        section("Something changed") {
            if let until = plan?.pausedUntil, Calendar.current.startOfDay(for: until) > Calendar.current.startOfDay(for: today) {
                row("play.fill", "Resume my plan", "Paused until \(until.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))") {
                    propose(.resumePlan, title: "Resume my plan", request: "I'm back")
                }
            } else {
                row("pause.circle", "Pause and come back", "Travel, life. Everything shifts later") { picker = .pause }
            }
            row("thermometer.variable", "I'm not feeling well", "Pause three days, nothing is lost") {
                propose(.pausePlan(days: 3), title: "I'm not feeling well", request: "I'm unwell and need a few days")
            }
            row("bandage", "Something hurts", "Train around it, with a gated way back") { showInjury = true }
            row("calendar.badge.minus", "I missed some training", missedLine) {
                propose(.renewBlock, title: "Rebuild from today", request: "I missed training; rebuild from where I am")
            }
        }
    }

    private var goalSection: some View {
        section("My goal") {
            row("flag.checkered", "Race, date and goal time", PlanBlueprint(profile: profile).goalLine()) { onOpenSettings() }
            row("square.stack", "Switch to another plan", "Drafts, upcoming and previous plans") { onOpenYourPlans() }
        }
    }

    private var preferredLine: String {
        guard !profile.preferredDays.isEmpty else { return "" }
        let symbols = Calendar.current.shortWeekdaySymbols
        let days = profile.preferredDays.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { symbols[$0 - 1] }
        return " · " + days.joined(separator: " ")
    }

    private var missedLine: String {
        guard let plan else { return "" }
        let cal = Calendar.current
        let missed = plan.sessions.filter {
            $0.status == .missed || ($0.status == .moved && cal.startOfDay(for: $0.date) < cal.startOfDay(for: today))
        }.count
        if missed == 0 { return "Missed sessions roll forward on their own" }
        return "\(missed) rolled forward. Rebuild the block from what you actually ran"
    }

    private func daysRequest(_ days: Int?, _ preferred: [Int]?) -> String {
        var parts: [String] = []
        if let days { parts.append("\(days) days a week") }
        if let preferred, !preferred.isEmpty {
            let symbols = Calendar.current.shortWeekdaySymbols
            parts.append(preferred.map { symbols[$0 - 1] }.joined(separator: ", "))
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

    private func propose(_ intent: CoachIntent, title: String, request: String) {
        guard paywall.isEntitled(to: .aiCoach) else { paywall.present(for: .aiCoach); return }
        picker = nil
        proposal = PlanAdjustmentService.proposal(intent, title: title, request: request, profile: profile,
                                                  workouts: workouts, today: today, distanceUnit: distanceUnit,
                                                  in: context)
    }

    private func receiptCard(_ applied: Applied) -> some View {
        let canUndo = applied.undo != nil && PlanAdjustmentService.signature(of: profile.plan) == applied.signature
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
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
                        .padding(.horizontal, 14).padding(.vertical, 8)
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

    private func undo(_ applied: Applied) {
        guard let json = applied.undo else { return }
        if PlanAdjustmentService.undo(json, profile: profile, workouts: workouts,
                                      notifications: services.notifications, in: context) {
            Haptics.light()
            self.applied = nil
            onPlanChanged()
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

    private func row(_ icon: String, _ title: String, _ subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(subtitle).font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            }
            .padding(Theme.Space.md)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 56)
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

/// One change, decided with the facts in front of the athlete. Apply goes through the same engine
/// and throttle the coach chat uses; a plan that changed underneath is recomputed, never applied stale.
struct PlanProposalSheet: View {
    enum Result { case applied(CoachActions.Receipt, undo: String?), declined }

    @State var proposal: PlanAdjustmentService.Proposal
    let profile: UserProfile
    let workouts: [Workout]
    let distanceUnit: DistanceUnit
    var onResult: (Result) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @State private var declined: String?
    @State private var recomputed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(proposal.title).font(.display(Theme.FontSize.headline, weight: .heavy)).foregroundStyle(Theme.ink)
                        Text("“\(proposal.request)”")
                            .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                    if let declined {
                        Text(declined).font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Theme.Space.lg)
                .padding(.bottom, 100)
            }
            .background(Theme.background)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: Theme.Space.sm) {
                    Button { onResult(.declined); dismiss() } label: {
                        Text("Cancel").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(Capsule().stroke(Theme.ink, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    Button { apply() } label: {
                        Text("Apply").font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .raised(Capsule(), tone: .ink)
                    }
                    .buttonStyle(RaisedPressStyle())
                    .disabled(!proposal.isAvailable)
                    .opacity(proposal.isAvailable ? 1 : 0.45)
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
        }
        .presentationDetents([.large])
    }

    private func apply() {
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
                proposal = fresh
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
                    .padding(Theme.Space.lg).padding(.bottom, 100)
            }
            .background(Theme.background)
            .safeAreaInset(edge: .bottom) {
                Button { onConfirm() } label: {
                    Text(confirm).font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity).frame(height: 52)
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

private func choiceRow(_ values: [Int], current: Int, label: @escaping (Int) -> String, _ set: @escaping (Int) -> Void) -> some View {
    HStack(spacing: Theme.Space.sm) {
        ForEach(values, id: \.self) { v in
            let on = current == v
            Button { Haptics.selection(); set(v) } label: {
                Text(label(v))
                    .font(.rounded(Theme.FontSize.body, weight: .bold)).monospacedDigit()
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .foregroundStyle(on ? Theme.background : Theme.ink)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.Radius.card).fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                        if !on { RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline) }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
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

    var body: some View {
        PickerFrame(title: "Training days", confirm: "See the change", enabled: changed, onConfirm: {
            onPick(days == initialDays ? nil : days, Set(preferred) == Set(initialPreferred) ? nil : preferred)
            dismiss()
        }) {
            Text("DAYS A WEEK").font(.rounded(10, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            choiceRow([2, 3, 4, 5, 6], current: days, label: { "\($0)" }) { days = $0 }
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
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background { if on { Capsule().fill(Theme.ink) } else { Capsule().stroke(Theme.hairline) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbols[weekday - 1])
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Text(preferred.isEmpty ? "No fixed days: the coach spreads the week." : "The long run takes the last chosen day of the week.")
                .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
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
            choiceRow([30, 45, 60, 75, 90], current: minutes, label: { "\($0)m" }) { minutes = $0 }
            Text("Long runs keep their place; what does not fit moves to the days that can hold it.")
                .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
    }
}

private struct PausePickerSheet: View {
    @State private var days = 3
    var onPick: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PickerFrame(title: "Pause", confirm: "See the change", onConfirm: { onPick(days); dismiss() }) {
            choiceRow([2, 3, 5, 7, 10, 14], current: days, label: { "\($0)" }) { days = $0 }
            Text("Days. Everything upcoming shifts later; race day never moves.")
                .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
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
            Text("Strength days are rebuilt with exercises you can do. Running is untouched.")
                .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
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
                      && $0.date >= today && $0.date <= horizon && $0.runType != .race }
            .sorted { $0.date < $1.date }
    }

    private var days: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<14).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

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
                        withAnimation(Motion.standard) { chosen = s }
                    }
                }
                if let chosen {
                    Text("TO WHICH DAY").font(.rounded(10, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
                    FlowLayout(spacing: Theme.Space.sm) {
                        ForEach(days, id: \.self) { d in
                            let same = Calendar.current.isDate(d, inSameDayAs: chosen.date)
                            let on = day.map { Calendar.current.isDate($0, inSameDayAs: d) } ?? false
                            Button { Haptics.selection(); day = d } label: {
                                Text(d.formatted(.dateTime.weekday(.abbreviated).day()))
                                    .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(on ? Theme.background : (same ? Theme.inkTertiary : Theme.ink))
                                    .padding(.horizontal, 12).padding(.vertical, 9)
                                    .background { if on { Capsule().fill(Theme.ink) } else { Capsule().stroke(Theme.hairline) } }
                            }
                            .buttonStyle(.plain)
                            .disabled(same)
                        }
                    }
                }
            }
        }
    }
}
