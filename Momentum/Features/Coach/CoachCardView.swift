import SwiftUI

/// A coach card rendered under a chat reply — the tappable half of "propose → preview → confirm".
/// Visual DNA is the Plan page's tune card: icon in a circle, headline + concrete diff lines, an ink
/// "Apply" capsule. Iridescence appears only on the *applied* receipt (earned, not promised).
/// Never a red state: declined and expired render as quiet hairline rows.
struct CoachCardView: View {
    let message: ChatMessage
    let payload: CoachCardPayload
    /// Deterministic diff lines for the proposal (from `CoachActions.preview`).
    var previewLines: [String] = []
    /// The honest race check, shown on changeRace proposals before Apply.
    var feasibility: PlanFeasibility?
    /// Sections for the info variants (explainPlan / weekRecap / racePlan), via the view model.
    var sections: [CoachSection] = []
    /// Active memory notes for the memory variant (pinned first), with per-note forget.
    var memoryNotes: [(id: UUID, text: String, pinned: Bool)] = []
    var onApply: () -> Void = {}
    var onDecline: () -> Void = {}
    var onPickSeverity: (InjurySeverity) -> Void = { _ in }
    /// A slot picker answered the coach's question (goal / days / minutes / race distance / race
    /// day) — persist the filled payload; the card re-renders as a full proposal with diff + Apply.
    var onFill: (CoachCardPayload) -> Void = { _ in }
    /// An adjust-plan menu row was tapped — its intent goes through the chat like a typed message.
    var onSendOption: (String) -> Void = { _ in }
    var onNavigate: () -> Void = {}
    var onUndo: () -> Void = {}
    var onForget: (UUID) -> Void = { _ in }

    /// Race-day selection for the inline date picker (defaults to a sane 12-week runway).
    @State private var raceDay: Date =
        Calendar.current.date(byAdding: .weekOfYear, value: 12, to: Date()) ?? Date()

    private var state: ChatMessage.CardState { message.cardState ?? .proposed }
    private var undoable: Bool { message.undoJSON != nil }
    private var isInfo: Bool {
        [.explainPlan, .weekRecap, .racePlan, .racePredictor, .todayBriefing, .zones].contains(payload.kind)
    }

    var body: some View {
        switch state {
        case .proposed:
            if payload.kind == .nav {
                navCard
            } else if payload.kind == .adjustPlan {
                adjustMenu
            } else if isInfo {
                sectionsCard
            } else if payload.kind == .memory {
                memoryCard
            } else if payload.kind == .injuryReport, payload.injurySeverity == nil {
                severityPicker
            } else if payload.kind == .changeGoal, payload.goal == nil {
                goalPicker
            } else if payload.kind == .changeDays, payload.daysPerWeek == nil,
                      payload.preferredDays?.isEmpty ?? true {
                daysPicker
            } else if payload.kind == .changeSessionLength, payload.sessionMinutes == nil {
                minutesPicker
            } else if payload.kind == .changeRace, payload.raceName == nil, payload.raceDistanceM == nil {
                distancePicker
            } else if payload.kind == .changeRace, payload.raceName == nil, payload.raceDateISO == nil {
                raceDatePicker
            } else {
                proposalCard
            }
        case .applied where isInfo:
            sectionsCard        // informational — stays readable even after its nav row was tapped
        case .applied where payload.kind == .memory:
            memoryCard
        case .applied:
            receiptRow(icon: "checkmark.circle.fill",
                       text: payload.kind == .nav ? payload.label : "Applied — \(payload.label)",
                       iridescent: payload.kind != .nav,
                       undo: payload.kind != .nav && undoable)
        case .declined:
            receiptRow(icon: "minus.circle", text: "Not this time — no problem", iridescent: false)
        case .expired:
            receiptRow(icon: "clock.arrow.circlepath", text: "Lapsed — your plan changed since", iridescent: false)
        case .undone:
            receiptRow(icon: "arrow.uturn.left.circle", text: "Rolled back — plan restored", iridescent: false)
        }
    }

    // MARK: Proposal (the diff + Apply/Not now)

    private var proposalCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.surface))
                    .overlay(Circle().stroke(Theme.hairline))
                Text(payload.label)
                    .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
            }
            if let feasibility { verdictRow(feasibility) }
            if !previewLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(previewLines, id: \.self) { line in
                        HStack(alignment: .top, spacing: Theme.Space.xs) {
                            Circle().fill(Theme.inkTertiary).frame(width: 3, height: 3).padding(.top, 7)
                            Text(line)
                                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                                .foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack(spacing: Theme.Space.sm) {
                Button { Haptics.light(); onApply() } label: {
                    Text(applyTitle)
                        .font(.rounded(Theme.FontSize.caption, weight: .bold))
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, Theme.Space.lg).padding(.vertical, 8)
                        .raised(Capsule(), tone: .ink)
                }
                .buttonStyle(.plain)
                Button { Haptics.light(); onDecline() } label: {
                    Text("Not now")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold))
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(Theme.Space.md)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// A tight/too-short race: the Apply button is honest that it's the athlete's call.
    private var applyTitle: String {
        if payload.kind == .changeRace, feasibility?.verdict == .tooShort { return "Build it anyway" }
        return "Apply"
    }

    /// The honest feasibility read on a proposed race — headline, plus the smarter alternatives when
    /// the runway is short, so the athlete makes an explicit choice: build it anyway, or pick a
    /// better-fitting option.
    private func verdictRow(_ f: PlanFeasibility) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: Theme.Space.xs) {
                Image(systemName: f.verdict == .onTrack ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 1)
                Text(f.headline)
                    .font(.rounded(Theme.FontSize.caption, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !f.options.isEmpty {
                ForEach(f.options.prefix(3), id: \.self) { opt in
                    HStack(alignment: .top, spacing: 5) {
                        Text("or").font(.rounded(Theme.FontSize.label, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                        Text(opt)
                            .font(.rounded(Theme.FontSize.label, weight: .medium))
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 6).padding(.horizontal, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.background))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.hairline))
    }

    // MARK: Injury severity picker (completes the intent locally, then applies)

    private var severityPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ForEach(InjurySeverity.allCases) { severity in
                Button { Haptics.selection(); onPickSeverity(severity) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(severity.label)
                            .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                        Text(severity.subtitle)
                            .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.md)
                    .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Slot pickers — the coach asked a question; the answer completes the card in place.
    // Picking is free (it only fills the payload); the rebuilt proposal's Apply is the Pro moment.

    private static let goalOptions: [(goal: Goal, subtitle: String)] = [
        (.endurance, "Run stronger, farther, faster"),
        (.getStronger, "Lift heavier, move better"),
        (.buildMuscle, "Add size where it counts"),
        (.loseFat, "Lean out without losing strength"),
        (.generalFitness, "Fit for life, not one finish line"),
        (.stayConsistent, "Make showing up the win"),
    ]

    private var goalPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ForEach(Self.goalOptions, id: \.goal) { option in
                Button {
                    Haptics.selection()
                    var filled = payload
                    filled.goal = option.goal.rawValue
                    filled.label = CoachResponder.goalLabel(option.goal)
                    onFill(filled)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CoachResponder.goalLabel(option.goal))
                            .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                        Text(option.subtitle)
                            .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.md)
                    .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var daysPicker: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach([3, 4, 5, 6], id: \.self) { days in
                Button {
                    Haptics.selection()
                    var filled = payload
                    filled.daysPerWeek = days
                    filled.label = "Train \(days) days a week"
                    onFill(filled)
                } label: {
                    VStack(spacing: 2) {
                        Text("\(days)").font(.display(20, weight: .heavy)).monospacedDigit()
                        Text("days").font(.rounded(Theme.FontSize.label, weight: .bold))
                    }
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Space.sm)
                    .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var minutesPicker: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach([30, 45, 60, 90], id: \.self) { minutes in
                Button {
                    Haptics.selection()
                    var filled = payload
                    filled.sessionMinutes = minutes
                    filled.label = "\(minutes)-minute sessions"
                    onFill(filled)
                } label: {
                    VStack(spacing: 2) {
                        Text("\(minutes)").font(.display(20, weight: .heavy)).monospacedDigit()
                        Text("min").font(.rounded(Theme.FontSize.label, weight: .bold))
                    }
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Space.sm)
                    .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var distancePicker: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Theme.Space.sm) {
            ForEach(RaceDistance.allCases) { dist in
                Button {
                    Haptics.selection()
                    var filled = payload
                    filled.raceDistanceM = dist.meters
                    filled.label = "Point my plan at a \(dist.label.lowercased())"
                    onFill(filled)
                } label: {
                    Text(dist.label)
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Space.sm)
                        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Distance chosen, date missing: an inline date picker so race day is set right here in the
    /// chat — then the card re-renders with the honest feasibility read before anything applies.
    private var raceDatePicker: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.surface))
                    .overlay(Circle().stroke(Theme.hairline))
                VStack(alignment: .leading, spacing: 2) {
                    Text(RaceDistance.nearest(toMeters: payload.raceDistanceM ?? 0).label)
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("When's race day?")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: 0)
            }
            DatePicker("Race day", selection: $raceDay, in: raceDayRange, displayedComponents: .date)
                .datePickerStyle(.compact)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
            Button {
                Haptics.light()
                var filled = payload
                filled.raceDateISO = Self.isoDay(raceDay)
                onFill(filled)
            } label: {
                Text("Check the runway")
                    .font(.rounded(Theme.FontSize.caption, weight: .bold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, Theme.Space.lg).padding(.vertical, 8)
                    .raised(Capsule(), tone: .ink)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Space.md)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// Tomorrow through the intent bridge's 18-month horizon.
    private var raceDayRange: ClosedRange<Date> {
        let cal = Calendar.current
        let lo = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        let hi = cal.date(byAdding: .month, value: 18, to: lo) ?? lo
        return lo...hi
    }

    private static func isoDay(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.calendar = .current
        fmt.timeZone = Calendar.current.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    // MARK: Adjust-plan menu — conversation steering; every row happens right here in the chat.

    private static let adjustOptions: [(icon: String, title: String, sends: String)] = [
        ("calendar", "Training days", "Change my training days"),
        ("target", "My goal", "Change my goal"),
        ("flag.checkered", "My race", "Change my race"),
        ("clock", "Session length", "Change my session length"),
        ("arrow.triangle.2.circlepath", "A fresh block from today", "Start a fresh block"),
    ]

    private var adjustMenu: some View {
        VStack(spacing: 0) {
            ForEach(Array(Self.adjustOptions.enumerated()), id: \.offset) { index, option in
                Button { Haptics.selection(); onSendOption(option.sends) } label: {
                    HStack(spacing: Theme.Space.md) {
                        Image(systemName: option.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.inkSecondary)
                            .frame(width: 22)
                        Text(option.title)
                            .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                    }
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < Self.adjustOptions.count - 1 {
                    Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, Theme.Space.md + 22 + Theme.Space.md)
                }
            }
        }
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    // MARK: Info cards (explain plan / week recap / race plan — their numbers, the engine's words)

    private var sectionsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(IridescentMaterial()).opacity(0.28))
                    .overlay(Circle().stroke(Theme.hairline))
                Text(payload.label.isEmpty ? "From your coach" : payload.label)
                    .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                ForEach(sections) { section in
                    HStack(alignment: .top, spacing: Theme.Space.sm) {
                        Image(systemName: section.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.inkSecondary)
                            .frame(width: 20)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                                .font(.rounded(Theme.FontSize.caption, weight: .bold))
                                .foregroundStyle(Theme.ink)
                            Text(section.detail)
                                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                                .foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Button { Haptics.light(); onNavigate() } label: {
                HStack(spacing: 6) {
                    Text(footerTitle)
                        .font(.rounded(Theme.FontSize.caption, weight: .bold))
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(Theme.ink)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(Theme.Space.md)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private var footerTitle: String {
        switch payload.kind {
        case .weekRecap, .racePredictor, .zones: "Open Progress"
        case .racePlan: "See the plan"
        case .todayBriefing: "Start now"
        default: "See the full plan"
        }
    }

    // MARK: Memory card ("what I know about you" — every note with its own forget)

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if memoryNotes.isEmpty {
                Text("I'm still learning your patterns. Tell me anything to remember (\"remember I prefer mornings\") and it lives here.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(memoryNotes, id: \.id) { note in
                    HStack(alignment: .top, spacing: Theme.Space.sm) {
                        Image(systemName: note.pinned ? "pin.fill" : "sparkle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.inkTertiary)
                            .padding(.top, 4)
                        Text(note.text)
                            .font(.rounded(Theme.FontSize.caption, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button { Haptics.light(); onForget(note.id) } label: {
                            Text("Forget")
                                .font(.rounded(Theme.FontSize.label, weight: .bold))
                                .foregroundStyle(Theme.inkSecondary)
                                .padding(.horizontal, Theme.Space.sm).padding(.vertical, 4)
                                .background(Capsule().stroke(Theme.hairline))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Forget: \(note.text)")
                    }
                }
                Text("Pinned notes are yours — I treat them as ground truth. Forgetting is instant.")
                    .font(.rounded(Theme.FontSize.label, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.top, 2)
            }
        }
        .padding(Theme.Space.md)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    // MARK: Nav card (deep link — no mutation)

    private var navCard: some View {
        Button { Haptics.light(); onNavigate() } label: {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.surface))
                    .overlay(Circle().stroke(Theme.hairline))
                Text(payload.label)
                    .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.inkTertiary)
            }
            .padding(Theme.Space.md)
            .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Receipt / declined / expired

    private func receiptRow(icon: String, text: String, iridescent: Bool, undo: Bool = false) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 28, height: 28)
                .background {
                    if iridescent {
                        Circle().fill(IridescentMaterial()).opacity(0.32)
                    } else {
                        Circle().fill(Theme.surface)
                    }
                }
                .overlay(Circle().stroke(Theme.hairline))
            Text(text)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: 0)
            if undo {
                Button { Haptics.light(); onUndo() } label: {
                    Text("Undo")
                        .font(.rounded(Theme.FontSize.caption, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, Theme.Space.sm).padding(.vertical, 5)
                        .background(Capsule().stroke(Theme.hairline))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Undo this change")
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    private var icon: String {
        switch payload.kind {
        case .nav:
            switch payload.nav.flatMap(CoachDestination.init(rawValue:)) {
            case .startToday: "play.fill"
            case .viewPlanWeek: "calendar"
            case .viewProgress: "chart.line.uptrend.xyaxis"
            case .raceBriefing: "flag.checkered"
            case .planSettings: "slider.horizontal.3"
            case .viewHealth: "heart.fill"
            case nil: "arrow.right"
            }
        case .changeGoal: "target"
        case .changeRace: "flag.checkered"
        case .changeDays, .changeSessionLength: "calendar"
        case .moveSession: "arrow.left.arrow.right"
        case .skipSession: "xmark.circle"
        case .easeWeek, .easePaces: "arrow.down.right"
        case .bumpLoad: "arrow.up.right"
        case .changeEquipment: "dumbbell.fill"
        case .injuryReport: "bandage.fill"
        case .pausePlan: "pause.fill"
        case .resumePlan: "play.fill"
        case .explainPlan: "sparkles"
        case .weekRecap: "calendar.badge.checkmark"
        case .racePlan: "flag.checkered"
        case .memory: "brain"
        case .rememberNote: "pin"
        case .racePredictor: "gauge.with.needle"
        case .todayBriefing: "sun.max"
        case .zones: "heart.text.square"
        case .adjustPlan: "slider.horizontal.3"
        case .renewBlock: "arrow.triangle.2.circlepath"
        case .none: "wand.and.stars"
        }
    }
}
