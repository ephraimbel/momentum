import Foundation
import SwiftData
import Observation

/// Drives the coach chat. Persists every turn as a `ChatMessage` (the view renders them via @Query)
/// and replies via the `coach-chat` Edge Function when configured, falling back to the deterministic
/// `CoachResponder` — the moment never blocks (PRD §8.8). Replies may carry ONE typed card
/// (`CoachCardPayload`); a card is only ever a *proposal* — `applyCard` re-validates it against the
/// live plan and routes it through `CoachActions`, so the deterministic engines execute every change.
@MainActor
@Observable
final class CoachChatViewModel {
    private(set) var isResponding = false
    /// A streamed reply is landing in a live bubble — the thinking dots yield, but the chat stays
    /// busy (`canSend` keys off `isResponding`) so a second send can't interleave two replies.
    private(set) var isStreamingReply = false
    var input = ""
    /// A contextual entry point set this ("ask about THIS workout") — the debrief grounds in it.
    var focusWorkoutID: UUID?

    private let context: ModelContext
    private let service: CoachChatService
    private let athleteModel: any AthleteModelServing
    /// Optional — lets readiness answers ground in live HRV/resting-HR/sleep. The chat works
    /// without it (signals read as `.empty`), so tests and previews need no Health stub.
    private let health: (any HealthServing)?

    init(context: ModelContext, service: CoachChatService = CoachChatService(),
         athleteModel: any AthleteModelServing = AthleteModelService(),
         health: (any HealthServing)? = nil) {
        self.context = context
        self.service = service
        self.athleteModel = athleteModel
        self.health = health
        seedGreetingIfEmpty()
    }

    var canSend: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isResponding }

    /// Starter chips that read the athlete's situation: a fresh workout, a race on the horizon, an
    /// active injury — then the evergreen questions fill the rest. Always exactly four.
    var suggestions: [String] {
        var out: [String] = []
        let cal = Calendar.current
        let profile = fetchProfile()
        let workouts = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        if !PlanCoaching.todaySessions(profile?.plan, on: Date()).filter({ $0.status != .completed }).isEmpty {
            out.append("Brief me on today")
        }
        if let last = workouts.max(by: { $0.startedAt < $1.startedAt }),
           cal.isDateInToday(last.startedAt) || cal.isDateInYesterday(last.startedAt) {
            out.append("How did my last workout go?")
        }
        if let race = profile?.raceDate {
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                          to: cal.startOfDay(for: race)).day ?? .max
            if (0...14).contains(days) { out.append("How should I run my race?") }
        }
        if profile?.activeInjuryArea != nil { out.append("How's my recovery looking?") }
        // A long run on the horizon makes fueling the question worth asking.
        if let sessions = profile?.plan?.sessions,
           sessions.contains(where: { $0.runType == .long && $0.status != .completed
               && $0.date >= cal.startOfDay(for: Date()) }) {
            out.append("What should I eat before my long run?")
        }
        for base in ["What could I race right now?", "How am I doing?", "Why is my plan built this way?", "How was my week?"]
            where out.count < 4 && !out.contains(base) { out.append(base) }
        return Array(out.prefix(4))
    }

    /// Follow-up chips under the latest coach reply — the conversation keeps going instead of
    /// ending. Deterministic, keyed off the last card's kind; empty mid-response.
    var followUps: [String] {
        guard !isResponding,
              let last = (try? context.fetch(FetchDescriptor<ChatMessage>(
                  sortBy: [SortDescriptor(\.createdAt, order: .reverse)])))?.first,
              last.role == .coach else { return [] }
        switch (last.card?.kind, last.cardState) {
        case (.explainPlan, _): return ["How should I run my race?", "What could I race right now?"]
        case (.weekRecap, _): return ["Why is my plan built this way?", "Brief me on today"]
        case (.racePlan, _): return ["What could I race right now?", "How's my recovery looking?"]
        case (.racePredictor, _): return ["How should I run my race?", "Why is my plan built this way?"]
        case (.todayBriefing, _): return ["Can I move today's session?", "What are my zones?"]
        case (.zones, _): return ["Brief me on today", "How am I doing?"]
        case (.memory, _): return ["How am I doing?"]
        case (_, .applied): return ["Why is my plan built this way?"]
        default: return []
        }
    }

    func send(_ raw: String? = nil) {
        let text = (raw ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        input = ""
        insert(.user, text)
        isResponding = true

        let history = recentTurns()
        let started = ContinuousClock.now   // the thinking beat is measured from the send tap
        Task {
            // Recovery signals are async (HealthKit) — fetch first, then build the full context.
            let signals = await health?.recoverySignals() ?? .empty
            await respond(to: text, history: history, context: buildContext(recovery: signals),
                          startedAt: started)
        }
    }

    /// The coach visibly thinks before every answer. A reply that lands the same instant the
    /// question was sent reads as a lookup, not a conversation — so non-streamed replies always
    /// hold the typing dots for a beat, scaled gently with how much the coach has to "say"
    /// (0.9s for a one-liner up to ~2s for a long briefing). Time already spent computing or on
    /// the network counts toward the beat, so slow paths never get slower.
    private func settleThinkingBeat(since started: ContinuousClock.Instant, for reply: String) async {
        let target = min(2.0, 0.9 + Double(reply.count) / 600.0)
        let remaining = Duration.seconds(target) - started.duration(to: .now)
        if remaining > .zero { try? await Task.sleep(for: remaining) }
    }

    /// Overlapping narrations (rapid Apply taps) each hold the dots; only the last one releases.
    private var narrationCount = 0

    /// A coach confirmation behind the same beat — the card flips instantly (that's the ack of
    /// YOUR tap), then the coach visibly composes its words instead of stamping them.
    private func narrate(_ text: String) {
        let started = ContinuousClock.now
        narrationCount += 1
        isResponding = true
        Task {
            await settleThinkingBeat(since: started, for: text)
            insert(.coach, text)
            narrationCount -= 1
            if narrationCount == 0 { isResponding = false }
        }
    }

    /// Offline-first routing (keeps the AI cheap — the model runs only for what we can't answer):
    /// 1. The deterministic `CoachResponder` answers first. When it's CONFIDENT — a card intent or a
    ///    grounded answer — we render that immediately, free, no network. Most turns land here.
    /// 2. Only when the responder falls through (a question outside what we know: fueling nuance,
    ///    the science of training, researching an upcoming race) AND a backend is configured do we
    ///    escalate to the Claude-backed coach — STREAMED token by token, one-shot JSON as a fallback.
    /// 3. If that AI call is slow/down/unconfigured, the responder's safe generic line is shown.
    /// The chat never blocks, partial streamed text survives a dropped connection, all de-dashed.
    private func respond(to latest: String, history: [CoachChatService.Turn],
                         context ctx: CoachResponder.Context,
                         startedAt started: ContinuousClock.Instant = .now) async {
        defer {
            isResponding = false; isStreamingReply = false   // busy until finalize, whatever path
            Haptics.light()                                  // the reply landed — one soft tick
        }
        // Tier 1 — answer locally where we're confident (and always when there's no AI to escalate to).
        let local = CoachResponder.resolve(to: latest, context: ctx)
        if local.confident || !service.isConfigured {
            await settleThinkingBeat(since: started, for: local.turn.text)
            insert(.coach, local.turn.text, card: validatedCard(local.turn.card, context: ctx))
            return
        }

        // Tier 2 — we don't have a solid answer and the AI is available: hand this one to Claude.
        var live: ChatMessage?
        let streamed = await service.stream(history: history, context: ctx) { [weak self] delta in
            guard let self else { return }
            if live == nil {
                let msg = ChatMessage(role: .coach, text: "")
                self.context.insert(msg)
                live = msg
                self.isStreamingReply = true   // dots out, words in — but still busy
            }
            live?.text += delta
        }
        if let live {
            // Streamed replies animate themselves — no artificial beat on top.
            live.text = CoachResponder.deDash(streamed?.text ?? live.text)
            if let streamed { live.card = validatedCard(streamed.card, context: ctx) }
            try? context.save()
            return
        }
        if let streamed {   // stream returned whole but emitted no deltas — render one-shot
            await settleThinkingBeat(since: started, for: streamed.text)
            insert(.coach, CoachResponder.deDash(streamed.text), card: validatedCard(streamed.card, context: ctx))
            return
        }
        if let llm = await service.reply(history: history, context: ctx) {
            await settleThinkingBeat(since: started, for: llm.text)
            insert(.coach, CoachResponder.deDash(llm.text), card: validatedCard(llm.card, context: ctx))
            return
        }

        // Tier 3 — the AI didn't answer either: fall back to the responder's safe generic line.
        await settleThinkingBeat(since: started, for: local.turn.text)
        insert(.coach, local.turn.text, card: validatedCard(local.turn.card, context: ctx))
    }

    /// Drop any card that doesn't survive validation right now — a reply with a broken card is still
    /// a good reply. (Injury cards missing severity are kept: the card renders a severity picker.)
    private func validatedCard(_ card: CoachCardPayload?, context ctx: CoachResponder.Context) -> CoachCardPayload? {
        guard let card, card.kind != .none else { return nil }
        if card.kind == .injuryReport, card.injuryArea != nil, card.injurySeverity == nil {
            return CoachIntentBridge.validate(pickerCompleted(card, severity: .twinge), snapshot: snapshot()) != nil
                ? card : nil
        }
        return CoachIntentBridge.validate(card, snapshot: snapshot()) != nil ? card : nil
    }

    // MARK: - Card actions

    /// Tap "Apply": re-validate against the live plan (stale ⇒ expire, never execute), gate on Pro,
    /// then run the deterministic apply path. The receipt is narrated as a fresh coach message.
    func applyCard(on message: ChatMessage, paywall: PaywallController, presenter: CoachPresenter) {
        guard message.cardState == .proposed, let payload = message.card else { return }

        // Nav + explain cards are free and don't mutate anything.
        if payload.kind == .nav {
            if let intent = CoachIntentBridge.validate(payload, snapshot: snapshot()),
               case .navigate(let dest) = intent {
                message.cardState = .applied
                try? context.save()
                presenter.navigate(dest)
            }
            return
        }
        switch payload.kind {
        case .explainPlan, .racePlan:
            message.cardState = .applied
            try? context.save()
            presenter.navigate(.viewPlanWeek)
            return
        case .weekRecap, .racePredictor, .zones:
            message.cardState = .applied
            try? context.save()
            presenter.navigate(.viewProgress)
            return
        case .todayBriefing:
            message.cardState = .applied
            try? context.save()
            presenter.navigate(.startToday)
            return
        case .memory:
            return   // the memory card stays live — forget buttons are its interaction
        default:
            break
        }

        guard let intent = CoachIntentBridge.validate(payload, snapshot: snapshot()) else {
            expire(message)
            return
        }

        // Free to talk, Pro to apply — the plan-changing tap is the Pro moment.
        guard paywall.isEntitled(to: .aiCoach) else {
            paywall.present(for: .aiCoach)
            return
        }

        guard let profile = fetchProfile() else {
            expire(message)
            return
        }
        let workouts = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        // Capture the full plan state first, so an applied change is always one tap from undone.
        // (Memory writes aren't plan state — the memory card's forget is their undo.)
        let undoSnapshot = payload.kind == .rememberNote ? nil : CoachUndo.capture(profile)
        switch CoachActions.apply(intent, profile: profile, workouts: workouts, in: context) {
        case .applied(let receipt):
            message.cardState = .applied
            makeSoleUndoPoint(message, snapshot: undoSnapshot)
            try? context.save()
            Haptics.success()
            narrate(CoachResponder.deDash(receipt.detail))
        case .declined(let reason):
            message.cardState = .declined
            try? context.save()
            narrate(CoachResponder.deDash(reason))
        case .navigate(let dest):
            message.cardState = .applied
            try? context.save()
            presenter.navigate(dest)
        }
    }

    /// Roll back the most recent applied change (state restore via `CoachUndo`). Free — undoing a
    /// change should never cost more trust than making it.
    func undoCard(on message: ChatMessage) {
        guard message.cardState == .applied, let json = message.undoJSON,
              let profile = fetchProfile() else { return }
        guard CoachUndo.restore(json, profile: profile, in: context) else {
            message.undoJSON = nil
            try? context.save()
            narrate("I couldn't roll that back cleanly. Your plan is safe, just tell me what you'd like it to look like and I'll set it.")
            return
        }
        message.cardState = .undone
        message.undoJSON = nil
        try? context.save()
        Haptics.light()
        narrate("Done, rolled back. Your plan is exactly as it was before, including your weekly change budget. Nothing lost.")
    }

    /// Only the single most recent applied change is undoable — a newer change invalidates every
    /// older snapshot (they describe a world that no longer exists).
    private func makeSoleUndoPoint(_ message: ChatMessage, snapshot: String?) {
        let all = (try? context.fetch(FetchDescriptor<ChatMessage>())) ?? []
        for m in all where m.undoJSON != nil { m.undoJSON = nil }
        message.undoJSON = snapshot
    }

    /// The personalized "why your plan looks like this" sections for an explainPlan card.
    func explainerSections() -> [CoachSection] {
        guard let profile = fetchProfile() else { return [] }
        let workouts = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        return CoachPlanExplainer.sections(profile: profile, workouts: workouts)
    }

    /// Info-card sections by kind (weekRecap / racePlan / explainPlan share the same renderer).
    func sections(for kind: CoachCardPayload.Kind) -> [CoachSection] {
        guard let profile = fetchProfile() else { return [] }
        switch kind {
        case .explainPlan:
            return explainerSections()
        case .weekRecap:
            let workouts = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
            let events = (try? context.fetch(FetchDescriptor<CoachingEvent>())) ?? []
            return CoachWeekRecap.sections(profile: profile, workouts: workouts, events: events)
        case .racePlan:
            return CoachRacePlan.sections(profile: profile)
        case .racePredictor:
            return CoachRacePredictor.sections(profile: profile)
        case .todayBriefing:
            return CoachTodayBriefing.sections(profile: profile)
        case .zones:
            return CoachZones.sections(profile: profile)
        default:
            return []
        }
    }

    /// "Forget this" from the memory card — soft-retires the note (kept for audit, never surfaced).
    func forgetNote(id: UUID) {
        athleteModel.forget(noteID: id, in: context)
        Haptics.light()
    }

    func declineCard(on message: ChatMessage) {
        guard message.cardState == .proposed else { return }
        message.cardState = .declined
        try? context.save()
    }

    /// An injury card's severity picker completed — fill the payload and run the normal apply path.
    func completeInjuryCard(on message: ChatMessage, severity: InjurySeverity,
                            paywall: PaywallController, presenter: CoachPresenter) {
        guard var payload = message.card, payload.kind == .injuryReport else { return }
        payload.injurySeverity = severity.rawValue
        message.card = payload
        try? context.save()
        applyCard(on: message, paywall: paywall, presenter: presenter)
    }

    /// Diff lines for a proposal card (deterministic preview — computed, never narrated).
    func previewLines(for payload: CoachCardPayload) -> [String] {
        guard let profile = fetchProfile(),
              let intent = CoachIntentBridge.validate(payload, snapshot: snapshot()) else { return [] }
        return CoachActions.preview(intent, profile: profile)
    }

    /// The honest race check rendered on a changeRace proposal — computed fresh at render time.
    func feasibilityPreview(for payload: CoachCardPayload) -> PlanFeasibility? {
        guard payload.kind == .changeRace, let profile = fetchProfile(),
              case .changeRace(let distanceM, let date, let goalTime)? =
                CoachIntentBridge.validate(payload, snapshot: snapshot()) else { return nil }
        return CoachActions.feasibility(for: profile, distanceM: distanceM, date: date,
                                        goalFinishTimeS: goalTime)
    }

    private func expire(_ message: ChatMessage) {
        message.cardState = .expired
        try? context.save()
        narrate("Your plan changed since I suggested that, so I let it lapse. Ask me again and I'll take a fresh look.")
    }

    private func pickerCompleted(_ card: CoachCardPayload, severity: InjurySeverity) -> CoachCardPayload {
        var filled = card
        filled.injurySeverity = severity.rawValue
        return filled
    }

    /// The recent thread as wire turns (bounded), for the Edge Function. Includes the just-sent
    /// user message since it's already persisted.
    private func recentTurns(limit: Int = 12) -> [CoachChatService.Turn] {
        let all = (try? context.fetch(FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]))) ?? []
        return all.suffix(limit).map {
            .init(role: $0.role == .coach ? "assistant" : "user", text: $0.text)
        }
    }

    /// Wipe the thread and start fresh with the greeting.
    func clear() {
        for m in (try? context.fetch(FetchDescriptor<ChatMessage>())) ?? [] { context.delete(m) }
        try? context.save()
        seedGreetingIfEmpty()
    }

    // MARK: - Persistence

    private func insert(_ role: ChatMessage.Role, _ text: String, card: CoachCardPayload? = nil) {
        context.insert(ChatMessage(role: role, text: text, card: card))
        try? context.save()
    }

    private func seedGreetingIfEmpty() {
        let count = (try? context.fetchCount(FetchDescriptor<ChatMessage>())) ?? 0
        guard count == 0 else { return }
        // No plan yet? The greeting opens the door instead of declining later.
        if fetchProfile()?.plan == nil {
            var card = CoachCardPayload(kind: .nav, label: "Set up your plan")
            card.nav = CoachDestination.planSettings.rawValue
            insert(.coach, "Hey, I'm your coach. You don't have a training plan yet, and that's the single best thing we can fix. Set one up and everything I do gets sharper.",
                   card: card)
            return
        }
        insert(.coach, "Hey, I'm your coach. Ask me how you're trending, what to do today, or to change up your plan. I'll always show you the change before it happens.")
    }

    private func fetchProfile() -> UserProfile? {
        (try? context.fetch(FetchDescriptor<UserProfile>()))?.first
    }

    // MARK: - Context

    /// The validation snapshot — the same upcoming-session whitelist the LLM was shown.
    private func snapshot(today: Date = Date()) -> CoachIntentBridge.Snapshot {
        let plan = fetchProfile()?.plan
        return CoachIntentBridge.Snapshot(
            today: today,
            upcomingSessions: upcoming(in: plan, today: today).map { ($0.id, $0.date) },
            isPaused: plan?.pausedUntil != nil)
    }

    /// Future, still-open sessions in the next 14 days (cap 20) — the only sessions the coach may
    /// reference, offline or on the wire.
    private func upcoming(in plan: TrainingPlan?, today: Date = Date()) -> [PlannedSession] {
        guard let plan else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: today)
        guard let end = cal.date(byAdding: .day, value: 14, to: start) else { return [] }
        return plan.sessions
            .filter { $0.status != .completed && $0.completedWorkout == nil
                      && cal.startOfDay(for: $0.date) >= start && $0.date < end }
            .sorted { $0.date < $1.date }
            .prefix(20).map { $0 }
    }

    private func buildContext(recovery: RecoverySignals = .empty) -> CoachResponder.Context {
        let workouts = (try? context.fetch(FetchDescriptor<Workout>())) ?? []
        let profile = fetchProfile()
        let plan = profile?.plan
        let today = PlanCoaching.todaySessions(plan, on: Date()).first { $0.status != .completed }
        let cal = Calendar.current
        let now = Date()

        let upcomingList = upcoming(in: plan, today: now).map {
            CoachResponder.UpcomingSession(
                id: $0.id, date: $0.date,
                brief: PlanCoaching.brief(for: $0, distanceUnit: .auto),
                discipline: $0.discipline.rawValue,
                status: $0.status.rawValue,
                estimatedDurationS: FuelingGuide.estimatedDurationS(
                    distanceM: $0.targetDistanceM, paceSPerKm: $0.targetPaceSPerKm,
                    durationS: $0.targetDurationS))
        }
        // Distance this week vs last — grounds "how far have I run this week" honestly.
        var weekM = 0.0, prevWeekM = 0.0
        if let week = cal.dateInterval(of: .weekOfYear, for: now),
           let prev = cal.dateInterval(of: .weekOfYear, for: week.start.addingTimeInterval(-1)) {
            for w in workouts {
                let d = w.gps?.distanceM ?? 0
                if w.startedAt >= week.start && w.startedAt < week.end { weekM += d }
                else if w.startedAt >= prev.start && w.startedAt < prev.end { prevWeekM += d }
            }
        }
        // The latest coach turn's card, only while still proposed — lets short follow-ups
        // ("Thursday instead") retarget it. Older cards never resurrect: most-recent-only.
        let lastCard = (try? context.fetch(FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])))?
            .first { $0.role == .coach }
            .flatMap { $0.cardState == .proposed ? $0.card : nil }
        let race: CoachResponder.RaceInfo? = profile?.raceDate.map {
            CoachResponder.RaceInfo(
                date: $0, distanceM: profile?.raceDistanceM,
                goalFinishTimeS: profile?.goalFinishTimeS,
                weeksOut: max(0, cal.dateComponents([.weekOfYear], from: now, to: $0).weekOfYear ?? 0))
        }
        var settings = CoachResponder.PlanSettings()
        if let profile {
            settings = CoachResponder.PlanSettings(
                daysPerWeek: profile.daysPerWeek,
                sessionMinutes: profile.sessionMinutes,
                equipment: profile.equipment.rawValue,
                preferredDays: profile.preferredDays,
                planIntensity: profile.planIntensity)
        }
        return CoachResponder.Context(
            insights: ProgressInsights(workouts: workouts),
            stats: ProfileStats(workouts: workouts, plan: plan),
            todaySession: today,
            goal: profile?.goal ?? .generalFitness,
            disciplines: profile?.disciplines ?? [],
            distanceUnit: .auto,
            athlete: athleteSummary(profile),
            upcoming: upcomingList,
            race: race,
            settings: settings,
            feasibility: profile.map { CoachActions.feasibility(for: $0, today: now) },
            lastAdaptedAt: plan?.lastAdaptedAt,
            canAdaptLoad: CoachActions.canAdaptLoad(plan, today: now),
            isPaused: plan?.pausedUntil != nil,
            activeInjuryArea: profile?.activeInjuryArea,
            lastWorkout: lastWorkout(in: workouts),
            recovery: recovery,
            p5kSPerKm: plan?.p5kSPerKm,
            weekDistanceM: weekM,
            prevWeekDistanceM: prevWeekM,
            lastCard: lastCard)
    }

    /// The workout to debrief, digested (splits read, structured-rep verdicts). A contextual entry
    /// ("ask about this workout") pins a specific one; otherwise the most recent.
    private func lastWorkout(in workouts: [Workout]) -> CoachResponder.LastWorkout? {
        let focused = focusWorkoutID.flatMap { id in workouts.first { $0.id == id } }
        guard let w = focused ?? workouts.max(by: { $0.startedAt < $1.startedAt }) else { return nil }

        var splitNote: String?
        if let splits = w.gps?.splits.filter({ !$0.isPartial }).sorted(by: { $0.index < $1.index }),
           splits.count >= 4 {
            func pace(_ list: ArraySlice<Split>) -> Double {
                let d = list.reduce(0.0) { $0 + $1.distanceM }, t = list.reduce(0.0) { $0 + $1.durationS }
                return d > 0 ? t / (d / 1000) : 0
            }
            let half = splits.count / 2
            let first = pace(splits.prefix(half)), second = pace(splits.suffix(splits.count - half))
            let delta = Int((first - second).rounded())
            if abs(delta) >= 3 {
                splitNote = delta > 0 ? "negative split, second half \(delta) s/km quicker"
                                      : "positive split, second half \(abs(delta)) s/km slower"
            } else {
                splitNote = "metronome-even splits"
            }
        }

        var repsNote: String?
        if let reps = w.gps?.structuredReps, !reps.isEmpty {
            let targeted = reps.filter { $0.targetPaceSPerKm != nil }
            if !targeted.isEmpty {
                let on = targeted.filter { $0.verdict == .onPace }.count
                repsNote = "\(on) of \(targeted.count) reps on pace"
            }
        }

        return CoachResponder.LastWorkout(
            date: w.startedAt,
            typeTitle: w.type.title,
            distanceM: w.gps?.distanceM,
            durationS: w.durationS,
            avgPaceSPerKm: w.gps?.avgPaceSPerKm,
            avgHR: w.gps?.avgHR,
            perceivedEffort: w.perceivedEffort,
            plannedBrief: w.plannedSession.map { PlanCoaching.brief(for: $0, distanceUnit: .auto) },
            splitNote: splitNote,
            repsNote: repsNote)
    }

    /// Decoupled projection of the Athlete Model (the coach's long-term memory) for the responder.
    /// Reads only stable fields so it won't break as that model evolves.
    private func athleteSummary(_ profile: UserProfile?) -> CoachResponder.AthleteSummary? {
        guard let m = profile?.athlete else { return nil }
        let active = m.notes.filter(\.isActive)
        let ordered = active.filter(\.pinned) + active.filter { !$0.pinned }
        let topShare = m.disciplineShare.max { $0.value < $1.value }?.key
        return .init(
            notes: ordered.prefix(5).map(\.text),
            preferredSessionMinutes: Int(m.preferredSessionMinutes.rounded()),
            topDiscipline: topShare.flatMap { WorkoutType(rawValue: $0)?.title },
            overreachACWR: m.overreachThresholdACWR,
            paceTrendPct: m.paceAtEffortTrendPct
        )
    }
}
