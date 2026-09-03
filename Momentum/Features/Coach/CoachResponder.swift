import Foundation

/// Deterministic coach replies grounded in the athlete's real data and long-term memory (PRD §4.7/§9
/// — rules compute, AI narrates). This is the always-available fallback that runs with no backend,
/// and the safety net when the `coach-chat` Edge Function is slow or down. No medical claims;
/// no-shame tone; never uses em dashes (they read as generic AI slop).
@MainActor
enum CoachResponder {
    /// A decoupled projection of the Athlete Model, so the responder never depends on its schema.
    struct AthleteSummary {
        var notes: [String] = []                 // active memory, pinned first
        var preferredSessionMinutes: Int = 0
        var topDiscipline: String? = nil          // most-trained discipline (display name)
        var priorHighStrainLoadRatio: Double = 0  // low-confidence observation, never a safety limit
        var paceTrendPct: Double = 0              // easy-pace change at matched effort; negative = fitter
    }

    /// A future planned session the coach may reference (and the LLM whitelist — see the service DTO).
    struct UpcomingSession: Sendable {
        let id: UUID
        let date: Date
        let brief: String
        let discipline: String
        let status: String
        /// Estimated duration (explicit target, else distance × pace) — grounds fueling answers.
        let estimatedDurationS: Double?

        init(id: UUID, date: Date, brief: String, discipline: String, status: String,
             estimatedDurationS: Double? = nil) {
            self.id = id
            self.date = date
            self.brief = brief
            self.discipline = discipline
            self.status = status
            self.estimatedDurationS = estimatedDurationS
        }
    }

    struct RaceInfo: Sendable {
        let date: Date
        let distanceM: Double?
        let goalFinishTimeS: Double?
        let weeksOut: Int
    }

    struct PlanSettings: Sendable {
        var daysPerWeek: Int = 3
        var sessionMinutes: Int = 45
        var equipment: String = Equipment.fullGym.rawValue
        var preferredDays: [Int] = []
        var planIntensity: String? = nil
    }

    /// The athlete's most recent workout, in enough detail for a real debrief.
    struct LastWorkout: Sendable {
        let date: Date
        let typeTitle: String
        let distanceM: Double?
        let durationS: Double
        let avgPaceSPerKm: Double?
        let avgHR: Int?
        let perceivedEffort: Int?
        let plannedBrief: String?       // what was prescribed, if it credited a session
        let splitNote: String?          // e.g. "negative split by 6 s/km"
        let repsNote: String?           // e.g. "5 of 6 reps on pace"
    }

    struct Context {
        let insights: ProgressInsights
        let stats: ProfileStats
        let todaySession: PlannedSession?
        let goal: Goal
        let disciplines: [String]
        let distanceUnit: DistanceUnit
        var athlete: AthleteSummary? = nil
        // v2 — grounding for typed proposals (defaults keep older call sites compiling).
        var upcoming: [UpcomingSession] = []
        var race: RaceInfo? = nil
        var settings: PlanSettings = PlanSettings()
        var feasibility: PlanFeasibility? = nil
        var lastAdaptedAt: Date? = nil
        var canAdaptLoad: Bool = true
        var isPaused: Bool = false
        var activeInjuryArea: String? = nil
        var lastWorkout: LastWorkout? = nil
        var calendar: Calendar = .current
        // v3 — the "answer anything" grounding (defaults keep older call sites compiling).
        var recovery: RecoverySignals = .empty
        var p5kSPerKm: Double? = nil
        var weekDistanceM: Double = 0
        var prevWeekDistanceM: Double = 0
        /// The last coach card in the thread — lets short follow-ups ("Thursday instead") resolve.
        var lastCard: CoachCardPayload? = nil
        /// Today's fueling digest (`FuelReadoutBuilder.coachLine`) — nil until a meal is logged,
        /// so "should I eat more before tomorrow?" gets a personal answer, never a nag.
        var fueling: String? = nil
    }

    /// A local reply: text plus at most one typed card (same shape the Edge Function returns).
    struct LocalTurn: Sendable {
        let text: String
        let card: CoachCardPayload?
    }

    static let suggestions = ["How am I doing?", "What should I do today?", "Why is my plan built this way?", "Can I move a session?"]

    static func reply(to message: String, context ctx: Context) -> String {
        deDash(rawReply(to: message, context: ctx))
    }

    /// The card-capable entry point (offline mirror of the Edge Function): deterministic keyword
    /// intents where they're safe, plain grounded text everywhere else. The chat never blocks.
    static func respond(to message: String, context ctx: Context) -> LocalTurn {
        resolve(to: message, context: ctx).turn
    }

    /// Offline-first routing decision. Returns the local turn AND whether we're `confident` in it:
    /// - a matched card intent, or a grounded answer → confident (use it, no AI, free)
    /// - fell through to the generic capability line → NOT confident (`turn` is the safe fallback;
    ///   the app escalates to the Claude-backed coach and uses this only if that's unavailable).
    /// This is the gate that keeps the AI cheap: it runs only for questions we can't answer well.
    static func resolve(to message: String, context ctx: Context) -> (turn: LocalTurn, confident: Bool) {
        if let turn = cardTurn(for: message, context: ctx) {
            return (LocalTurn(text: deDash(turn.text), card: turn.card), true)
        }
        if let answer = groundedAnswer(to: message, context: ctx) {
            return (LocalTurn(text: deDash(answer), card: nil), true)
        }
        return (LocalTurn(text: deDash(genericFallback(to: message, context: ctx)), card: nil), false)
    }

    // MARK: - Keyword → card intents (deterministic, conservative)

    private static func cardTurn(for message: String, context ctx: Context) -> LocalTurn? {
        let q = message.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { q.contains($0) } }
        let hasUpcoming = !ctx.upcoming.isEmpty

        // "Remember that I…" — distill the fact and propose keeping it (confirm before writing).
        if let note = rememberedNote(from: message) {
            var card = CoachCardPayload(kind: .rememberNote, label: "Remember this")
            card.note = note
            card.noteCategory = MemoryCategory.preference.rawValue
            return LocalTurn(text: "Got it. Want me to keep that in mind from now on?", card: card)
        }

        // What do I know about you — the memory card (with forget controls).
        if has(["know about me", "remember about me", "what do you remember", "your notes on me", "my memory"]) {
            let card = CoachCardPayload(kind: .memory, label: "What I know about you")
            return LocalTurn(text: "Here's everything I'm keeping in mind when I coach you. Forget anything, anytime.", card: card)
        }

        // The week in review (before the generic "how was" debrief matcher).
        if has(["how was my week", "how's my week", "hows my week", "week recap", "weekly review", "week in review", "how did my week"]) {
            let card = CoachCardPayload(kind: .weekRecap, label: "Your week")
            return LocalTurn(text: "Here's your week, straight from the log.", card: card)
        }

        // Race pacing / strategy.
        if has(["race pace", "race plan", "race strategy", "pace my race", "how should i run my race",
                "how should i pace", "approach race week", "race week", "pacing plan"]) {
            if ctx.race != nil {
                let card = CoachCardPayload(kind: .racePlan, label: "Your race plan")
                return LocalTurn(text: "Here's the race, planned from your current fitness.", card: card)
            }
            var card = CoachCardPayload(kind: .nav, label: "Set up a race")
            card.nav = CoachDestination.planSettings.rawValue
            return LocalTurn(text: "No race on your calendar yet. Point your plan at one and I'll build the pacing.", card: card)
        }

        // Equipment changed ("only have dumbbells now", "joined a gym", "bodyweight only") → rebuild
        // the strength work around what they actually have. Before the pause branch: an athlete
        // traveling WITH equipment constraints wants to keep training, not stop.
        if ctx.disciplines.contains(Discipline.strength.rawValue),
           has(["only have", "just have", "i have", "joined", "no gym", "no equipment", "bodyweight",
                "at home now", "hotel gym", "equipment", "switch to dumbbell", "got a gym"]),
           let equipment = equipmentFromText(q), equipment.rawValue != ctx.settings.equipment {
            var card = CoachCardPayload(kind: .changeEquipment, label: equipmentLabel(equipment))
            card.equipment = equipment.rawValue
            return LocalTurn(text: "Noted. I can rebuild your strength work around \(equipmentLabel(equipment).lowercased()) so every session is actually doable where you are.",
                             card: card)
        }

        // Pause / resume (check resume first — "back from vacation" contains "vacation").
        if ctx.isPaused, has(["i'm back", "im back", "resume", "unpause", "back home", "ready to train"]) {
            let card = CoachCardPayload(kind: .resumePlan, label: "Resume plan")
            return LocalTurn(text: "Good to have you back. Want me to pull your plan back to today?", card: card)
        }
        if !ctx.isPaused, hasUpcoming, has(["vacation", "traveling", "travelling", "pause my plan", "pause the plan", "need a break", "going away", "out of town"]) {
            var card = CoachCardPayload(kind: .pausePlan, label: "Pause 7 days")
            card.pauseDays = 7
            return LocalTurn(text: "Life happens. I can pause your plan and shift everything upcoming a week later. Nothing is lost.", card: card)
        }

        // Why is my plan like this — the personalized breakdown card, computed from their data.
        if has(["why is my plan", "explain my plan", "why am i doing", "why this plan", "how is my plan built", "plan built this way", "reasoning behind my plan"]) {
            let card = CoachCardPayload(kind: .explainPlan, label: "Your plan, explained")
            return LocalTurn(text: "Fair question. Here's exactly why your plan looks the way it does, from your own numbers.",
                             card: card)
        }

        // Injury — a body area + a pain word opens the gated injury flow (severity picked on the card).
        if has(["hurt", "hurts", "pain", "sore", "injur", "ache", "aching", "twinge"]) {
            let area = InjuryArea.allCases.first { q.contains($0.label.lowercased()) }
                ?? (q.contains("shin") ? .shins : nil)
            if let area {
                var card = CoachCardPayload(kind: .injuryReport, label: "Adjust my plan")
                card.injuryArea = area.rawValue
                return LocalTurn(text: "Thanks for telling me. How bad is your \(area.label.lowercased()) right now? Pick what fits and I'll train around it. If there's sharp pain, swelling, or numbness, see a professional first.",
                                 card: card)
            }
        }

        // Preferred training days named outright ("train on monday, wednesday and friday", "switch
        // my days to tue/thu/sat") → anchor the week to those days. Runs BEFORE the move matcher:
        // naming two weekdays would otherwise read as a session move. Needs an explicit days
        // phrasing, at least two weekdays, and a real change.
        if has(["train on", "run on", "my days to", "preferred days", "my training days on"]) {
            let days = mentionedWeekdays(q, calendar: ctx.calendar)
            if days.count >= 2, Set(days) != Set(ctx.settings.preferredDays) {
                var card = CoachCardPayload(kind: .changeDays, label: "Anchor my week")
                card.preferredDays = days.sorted()
                let names = days.sorted().map { ctx.calendar.weekdaySymbols[$0 - 1] }.joined(separator: ", ")
                return LocalTurn(text: "Done deal if you want it. I can anchor your week to \(names) and rebuild the schedule so the hard days still land on fresh legs.",
                                 card: card)
            }
        }

        // Move a session: a move verb + a target weekday we can resolve against the upcoming list.
        // Unresolvable but clearly a move ask → a clarifying question, never a subject change.
        if has(["move", "push", "swap", "reschedule", "shift"]), hasUpcoming {
            if let proposal = moveProposal(q, context: ctx) { return proposal }
            if let followUp = moveFollowUp(q, context: ctx) { return followUp }
            if has(["session", "run", "workout", "intervals", "tempo", "long", "strength", "today", "tomorrow"])
                || mentionedWeekdays(q, calendar: ctx.calendar).count == 1,
               let clarify = moveClarification(q, context: ctx) { return clarify }
        }
        // A bare follow-up after a move proposal ("Thursday instead", "what about Friday?").
        if let followUp = moveFollowUp(q, context: ctx) { return followUp }

        // Skip a session: a can't-make-it phrase + a resolvable day. One candidate → the card;
        // several → ask which; none → say so. Warmups/stretches aren't sessions.
        if hasUpcoming,
           has(["skip", "can't make", "cant make", "can't train", "cant train", "can't run", "cant run",
                "going to miss", "gonna miss", "have to miss", "not going to make", "can't do today", "cant do today"]),
           !has(["warmup", "warm up", "warm-up", "cooldown", "cool down", "stretch", "breakfast"]) {
            if let turn = skipProposal(q, context: ctx) { return turn }
        }

        // Ease the week (consent-gated protective direction). Natural ease phrasings included —
        // "ease it off" must not fall through to the "this week" schedule branch below.
        if has(["too hard", "too much this week", "way too much", "ease this week", "ease my week",
                "easier week", "ease it off", "ease off", "ease it up", "back it off", "cut back",
                "dial it back", "lighten", "brutal", "overwhelming"]) {
            guard hasUpcoming else { return nil }
            if ctx.canAdaptLoad {
                let card = CoachCardPayload(kind: .easeWeek, label: "Ease this week")
                return LocalTurn(text: "Heard. I can trim your upcoming sessions about 15% and soften the hard work to easy, so you absorb the block instead of fighting it.",
                                 card: card)
            }
            return LocalTurn(text: throttleText(ctx), card: nil)
        }

        // Bump the load (explicit review + consent — mirrors proposeAdjustment's gate).
        if has(["bump", "increase my", "more volume", "add volume", "train more", "harder week", "step it up", "ramp up"]) {
            guard hasUpcoming else { return nil }
            guard ctx.canAdaptLoad else { return LocalTurn(text: throttleText(ctx), card: nil) }
            if ctx.insights.recommendation == .increase {
                let card = CoachCardPayload(kind: .bumpLoad, label: "Raise ~10%")
                return LocalTurn(text: "This week was lighter than your recent pattern. If that was intentional and the sessions felt good, want me to nudge the upcoming sessions up about 10%?",
                                 card: card)
            }
            return LocalTurn(text: "I'd hold the plan. Your recent pattern doesn't support a bump review right now, and no single ratio can declare an increase safe.",
                             card: nil)
        }

        // Paces feel wrong (slower direction is the consent one).
        if has(["paces are too fast", "pace is too fast", "can't hit the paces", "cant hit the paces", "targets are too fast", "ease my paces", "paces too hard"]) {
            guard hasUpcoming else { return nil }
            let card = CoachCardPayload(kind: .easePaces, label: "Ease paces ~2%")
            return LocalTurn(text: "Honest targets beat heroic ones. I can ease your target paces about 2% so the sessions land the way they're meant to.",
                             card: card)
        }

        // What could I race right now — the predictor card.
        if has(["what could i run", "what could i race", "how fast could i", "race predictor", "predict my", "what's my 5k time", "whats my 5k time", "equivalent times"]) {
            let card = CoachCardPayload(kind: .racePredictor, label: "What you could race today")
            return LocalTurn(text: "From your calibrated fitness, right now. These sharpen every time you show real speed.", card: card)
        }

        // Zones and training paces.
        if has(["my zones", "heart rate zone", "hr zones", "training paces", "what are my paces", "which zone",
                "what pace should", "which pace", "pace for my"]) {
            let card = CoachCardPayload(kind: .zones, label: "Your zones and paces")
            return LocalTurn(text: "Here's where your effort should live, zone by zone.", card: card)
        }

        // Today's briefing — the pre-run ritual as one card (only when something's actually planned).
        if ctx.todaySession != nil,
           has(["brief me", "what's on today", "whats on today", "today's session", "todays session", "what should i do today", "what do i do today", "plan for today"]) {
            let card = CoachCardPayload(kind: .todayBriefing, label: "Today's session")
            return LocalTurn(text: "Here's today, step by step. I'll be there when you start.", card: card)
        }

        // A tune-up (2026-09-03): "add the Turkey Trot as a tune-up", "tune-up 10K in 4 weeks".
        // A B/C race on the season, never a change of goal — the card says which week bends.
        if has(["tune-up", "tune up", "tuneup", "b race", "c race", "train through"]) {
            let racesIt = !has(["train through", "c race"])
            if let m = RaceCatalog.match(freeText: message, calendar: ctx.calendar) {
                var card = CoachCardPayload(kind: .addTuneUp, label: "Add \(m.race.name) as a tune-up")
                card.raceName = message
                card.tuneUpPriority = racesIt ? "b" : "c"
                let dateStr = m.date.formatted(.dateTime.month(.wide).day())
                return LocalTurn(
                    text: "\(m.race.name), \(dateStr). I can add it as a tune-up: \(racesIt ? "you race it, with easy days either side" : "you train through it as that week's hard session"). Your goal race and the block toward it stay exactly as they are. Want me to?",
                    card: card)
            }
            if let dist = raceDistanceFromText(q) {
                var card = CoachCardPayload(kind: .addTuneUp, label: "Add a \(dist.label.lowercased()) tune-up")
                card.raceDistanceM = dist.meters
                card.tuneUpPriority = racesIt ? "b" : "c"
                if let date = relativeFutureDate(q, calendar: ctx.calendar) {
                    card.raceDateISO = isoDay(date, calendar: ctx.calendar)
                    return LocalTurn(text: "A \(dist.label.lowercased()) tune-up on \(date.formatted(.dateTime.month(.wide).day())). Say go and that week bends around it; the block keeps building toward your goal.",
                                     card: card)
                }
                return LocalTurn(text: "A \(dist.label.lowercased()) tune-up. Tell me the date (\"in 4 weeks\", or the day) and I will add it. Only that week bends; the block keeps pointing at your goal race.",
                                 card: nil)
            }
        }

        // A named race from our catalog → resolve it and offer to point the whole plan at it, the
        // same deterministic catalog onboarding uses. Gated on a race/plan intent word so a passing
        // mention of a city ("Boston is a great town") never triggers a plan change.
        if has(["race", "marathon", "half", "10k", "5k", "50k", "ultra", "run", "train", "plan", "sign up", "prep", "set up", "point my", "do the"]),
           let m = RaceCatalog.match(freeText: message, calendar: ctx.calendar) {
            var card = CoachCardPayload(kind: .changeRace, label: "Point my plan at \(m.race.name)")
            card.raceName = message   // the bridge re-resolves via the catalog (preserves any named sub-distance)
            let dateStr = m.date.formatted(.dateTime.month(.wide).day().year())
            return LocalTurn(
                text: "\(m.race.name) — \(m.race.city), \(dateStr). I can point your whole plan at that \(m.distance.label.lowercased()) and build the best block your timeline allows — I'll be honest about the runway on the card. Want me to?",
                card: card)
        }

        // A race distance without a catalog match ("I want to run a marathon", "new plan for a
        // half") → the in-chat race flow: distance now, date on the card (inline picker), the honest
        // feasibility read before anything applies. Parses "in N weeks/months"; real dates are
        // picked on the card, where a date picker beats fragile parsing.
        // Intent words are deliberately tight: questions ("how should I prep for the marathon?",
        // "am I ready for a half?") must stay questions, never mutate into proposals. A NAMED race
        // our catalog doesn't know ("the Comrades Marathon") is research, not a settings change —
        // skip the card so the ask escalates to the AI, which can actually look it up.
        if has(["train for", "sign up", "signed up", "want to run", "want to race", "want to do",
                "race a", "doing a", "aiming for", "targeting", "point my plan", "new plan for"]),
           !mentionsUnknownNamedRace(message),
           let dist = raceDistanceFromText(q) {
            var card = CoachCardPayload(kind: .changeRace, label: "Point my plan at a \(dist.label.lowercased())")
            card.raceDistanceM = dist.meters
            if let date = relativeFutureDate(q, calendar: ctx.calendar) {
                card.raceDateISO = isoDay(date, calendar: ctx.calendar)
                return LocalTurn(text: "A \(dist.label.lowercased()) it is. Here's the honest read on that runway. Say go and I'll rebuild your whole plan to point at it.",
                                 card: card)
            }
            return LocalTurn(text: "A \(dist.label.lowercased()). When's race day? Set the date on the card and I'll give you the honest read on the runway before anything changes.",
                             card: card)
        }

        // "Change my race" with nothing else → ask which distance, right on the card.
        if has(["change my race", "different race", "switch my race", "new race", "another race"]) {
            let card = CoachCardPayload(kind: .changeRace, label: "Change my race")
            return LocalTurn(text: "Let's re-point the plan. Which distance are we chasing? Pick one, then give me the date. If you mean a specific event, just name it and I'll look it up.",
                             card: card)
        }

        // A specific weekly day count ("train 5 days a week", "switch to 4 days") → a direct changeDays
        // card the athlete can apply, not just a nudge to settings.
        if has(["days a week", "train", "switch", "instead", "cut to", "go to", "move to", "bump"]),
           let days = weeklyDayCount(in: q), days != ctx.settings.daysPerWeek {
            var card = CoachCardPayload(kind: .changeDays, label: "Train \(days) days a week")
            card.daysPerWeek = days
            return LocalTurn(
                text: "\(days) days a week — I can rebuild your plan around that and keep the hard days spaced so nothing stacks. Want me to?",
                card: card)
        }

        // "Change my training days" without a count → ask how many, right on the card.
        if has(["change my days", "change my training days", "different days", "train on different days",
                "switch my days", "adjust my days", "my training days"]) {
            let card = CoachCardPayload(kind: .changeDays, label: "Training days")
            return LocalTurn(text: "How many days a week can you honestly give me? The plan's only as good as the days you'll actually show up for.",
                             card: card)
        }

        // A named goal with change intent ("I want to get stronger", "switch my focus to endurance")
        // → a direct proposal. Racing routes through the race flow above, never here.
        if has(["want to", "focus on", "switch", "change my goal", "new goal", "goal to",
                "let's work on", "lets work on", "make my goal", "instead"]),
           let goal = goalFromText(q) {
            if goal == ctx.goal {
                return LocalTurn(text: "That's already what we're building for. If it doesn't feel like it, tell me what's off and I'll tune the plan.", card: nil)
            }
            var card = CoachCardPayload(kind: .changeGoal, label: goalLabel(goal))
            card.goal = goal.rawValue
            return LocalTurn(text: "Good call. I can re-point your whole plan at \(goalLabel(goal).lowercased()) and rebuild the upcoming weeks around it.",
                             card: card)
        }

        // "Change my goal" with no goal named → ask what we're chasing, options on the card.
        if has(["change my goal", "new goal", "different goal", "change my focus", "switch my goal"]) {
            let card = CoachCardPayload(kind: .changeGoal, label: "Change my goal")
            return LocalTurn(text: "Happy to re-point everything. What are we chasing? If it's a race, just name it or tell me the distance.",
                             card: card)
        }

        // Session length: an explicit minutes ask → a direct proposal. The change verb matters —
        // "my last workout was 45 minutes" is a report, not a request.
        if has(["session", "workout"]),
           has(["make", "change", "set", "cut", "want", "switch", "give me", "cap", "size", "keep them"]),
           let minutes = minutesFromText(q),
           minutes != ctx.settings.sessionMinutes, (20...120).contains(minutes) {
            var card = CoachCardPayload(kind: .changeSessionLength, label: "\(minutes)-minute sessions")
            card.sessionMinutes = minutes
            return LocalTurn(text: "I can size every session to about \(minutes) minutes and rebuild the upcoming weeks to fit.",
                             card: card)
        }

        // "Shorter/longer sessions" without a number → propose the next sensible step, invite a number.
        if has(["shorter session", "shorter workout", "shorten my session", "sessions are too long",
                "workouts are too long", "less time per session"]) {
            let current = ctx.settings.sessionMinutes
            if let stepped = sessionSteps.last(where: { $0 < current }) {
                var card = CoachCardPayload(kind: .changeSessionLength, label: "\(stepped)-minute sessions")
                card.sessionMinutes = stepped
                return LocalTurn(text: "Let's make them fit your life. I can size sessions to about \(stepped) minutes instead of \(current). If a different number works better, just say it.",
                                 card: card)
            }
            return LocalTurn(text: "You're already at \(current) minutes, my shortest honest session. If time's the squeeze, we could drop a training day instead. Want that?", card: nil)
        }
        if has(["longer session", "longer workout", "more time per session", "sessions are too short",
                "extend my session"]) {
            let current = ctx.settings.sessionMinutes
            if let stepped = sessionSteps.first(where: { $0 > current }) {
                var card = CoachCardPayload(kind: .changeSessionLength, label: "\(stepped)-minute sessions")
                card.sessionMinutes = stepped
                return LocalTurn(text: "More time, more training. I can size sessions to about \(stepped) minutes instead of \(current). Name any number if you'd rather.",
                                 card: card)
            }
            return LocalTurn(text: "You're already at \(current) minutes, the longest I prescribe. Past that, an extra training day beats a marathon session. Want one?", card: nil)
        }

        // Vague "change my session length" → ask on the card.
        if has(["session length", "workout length", "length of my sessions", "how long my sessions"]) {
            let card = CoachCardPayload(kind: .changeSessionLength, label: "Session length")
            return LocalTurn(text: "How much time can you give each session? Pick what actually fits your day.",
                             card: card)
        }

        // A fresh start ("next block", "start over", "new plan") → the renewal: rolling plans
        // reassess and build the next block; race plans rebuild from today toward the race.
        if has(["next block", "new block", "renew my", "start fresh", "fresh block", "fresh start",
                "start over", "new plan", "rebuild my plan", "create a new plan", "reset my plan"]) {
            let rolling = ctx.race == nil
            let card = CoachCardPayload(kind: .renewBlock, label: rolling ? "Build my next block" : "Rebuild my plan")
            let text = rolling
                ? "Fresh start, smart start. I'll look at what you've actually been running, then build your next block from today. If you want different days, a new goal, or a race in the picture, tell me that first and I'll fold it in."
                : "I can rebuild your plan from today, still pointed at your race. If you'd rather change the race or the goal too, tell me that first."
            return LocalTurn(text: text, card: card)
        }

        // Vague "change/adjust my plan" → the menu. Every row happens right here in the chat.
        if has(["change my plan", "adjust my plan", "adjust the plan", "change the plan", "modify my plan",
                "tweak my plan", "update my plan", "edit my plan", "customize my plan", "customise my plan",
                "make changes to my plan", "change up my plan", "switch up my plan", "change something"]) {
            let card = CoachCardPayload(kind: .adjustPlan, label: "What should we change?")
            return LocalTurn(text: "Happy to. Everything here happens right in the chat, and you'll see the exact change before it lands. What should we adjust?",
                             card: card)
        }

        // Browsing for a race is genuinely better in settings — the catalog search lives there.
        if has(["find me a race", "find a race", "pick a race", "browse races", "what races",
                "look up a race", "search races"]) {
            var card = CoachCardPayload(kind: .nav, label: "Find your race")
            card.nav = CoachDestination.planSettings.rawValue
            return LocalTurn(text: "Let's find it properly. Open plan settings and tap \u{201C}Find your race\u{201D} to search the majors and hundreds more. Pick one and your plan re-points at it.",
                             card: card)
        }

        return nil
    }

    /// A non-race goal named in the text, else nil. Racing is NOT detected here — race asks route
    /// through the race flow (distance + date + feasibility), never a bare goal swap.
    private static func goalFromText(_ q: String) -> Goal? {
        if q.contains("stronger") || q.contains("strength goal") { return .getStronger }
        if q.contains("build muscle") || q.contains("muscle") || q.contains("hypertrophy") { return .buildMuscle }
        if q.contains("endurance") || q.contains("get faster") || q.contains("getting faster")
            || q.contains("run longer") || q.contains("aerobic") { return .endurance }
        if q.contains("lose fat") || q.contains("lose weight") || q.contains("lean out") || q.contains("fat loss") { return .loseFat }
        if q.contains("general fitness") || q.contains("get fit") || q.contains("overall fitness") || q.contains("stay fit") { return .generalFitness }
        if q.contains("consisten") || q.contains("build the habit") { return .stayConsistent }
        return nil
    }

    /// Display names for goals (mirrors the plan-settings labels).
    static func goalLabel(_ goal: Goal) -> String {
        goal.planLabel
    }

    /// A capitalized word right before a distance token ("the Comrades Marathon") names a specific
    /// race we didn't resolve from the catalog — that's research for the AI, not a distance swap.
    /// Sentence-common words stay exempt so "a Marathon" or "The half" never read as names.
    private static func mentionsUnknownNamedRace(_ message: String) -> Bool {
        let words = message.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let distances: Set<String> = ["marathon", "half", "10k", "5k", "50k", "ultra"]
        let common: Set<String> = ["a", "an", "the", "my", "that", "this", "i", "another", "first", "next"]
        for (i, word) in words.enumerated() where distances.contains(word.lowercased()) && i > 0 {
            let prev = words[i - 1]
            let prevLower = prev.lowercased()
            // Another distance token ("Half Marathon" in title case) is never a name.
            if prev.first?.isUppercase == true, !common.contains(prevLower), !distances.contains(prevLower) {
                return true
            }
        }
        return false
    }

    /// A race distance named in the text. Order matters: "50k ultramarathon" contains "marathon",
    /// and "half marathon" does too — check the more specific shapes first.
    private static func raceDistanceFromText(_ q: String) -> RaceDistance? {
        if q.contains("ultra") || q.contains("50k") || q.contains("fifty k") { return .fiftyK }
        if q.contains("half marathon") || q.contains("half-marathon") || q.contains(" half") || q.hasPrefix("half") { return .half }
        if q.contains("marathon") { return .marathon }
        if q.contains("10k") || q.contains("ten k") { return .tenK }
        if q.contains("5k") || q.contains("five k") { return .fiveK }
        return nil
    }

    /// "in N weeks" / "in N months" → a concrete future day. The only date shapes parsed offline;
    /// anything else is set on the card, where a real date picker beats fragile parsing.
    private static func relativeFutureDate(_ q: String, calendar: Calendar) -> Date? {
        let shapes: [(word: String, component: Calendar.Component, max: Int)] =
            [("week", .weekOfYear, 78), ("month", .month, 18)]
        for shape in shapes {
            guard let r = q.range(of: "in ([0-9]+) \(shape.word)", options: .regularExpression) else { continue }
            let digits = q[r].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            guard let n = Int(digits), (1...shape.max).contains(n) else { continue }
            return calendar.date(byAdding: shape.component, value: n, to: calendar.startOfDay(for: Date()))
        }
        return nil
    }

    /// A day as the strict "yyyy-MM-dd" the intent bridge expects.
    private static func isoDay(_ date: Date, calendar: Calendar) -> String {
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    /// A session length named in minutes ("45 minute sessions", "an hour"), else nil.
    private static func minutesFromText(_ q: String) -> Int? {
        if q.contains("hour and a half") { return 90 }
        if q.contains("half an hour") || q.contains("half hour") { return 30 }
        if q.contains("an hour") || q.contains("one hour") || q.contains("1 hour") { return 60 }
        guard let r = q.range(of: "([0-9]{2,3})[- ]?min", options: .regularExpression) else { return nil }
        let digits = q[r].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int(digits)
    }

    /// The honest session lengths the coach offers (bridge clamps 20…120 regardless).
    static let sessionSteps = [20, 30, 45, 60, 75, 90]

    /// The equipment situation named in the text, else nil.
    private static func equipmentFromText(_ q: String) -> Equipment? {
        if q.contains("bodyweight") || q.contains("no equipment") { return .bodyweight }
        if q.contains("dumbbell") { return .dumbbellsOnly }
        if q.contains("full gym") || q.contains("joined a gym") || q.contains("gym membership")
            || q.contains("back at the gym") || q.contains("got a gym") { return .fullGym }
        if q.contains("home gym") || q.contains("train at home") || q.contains("training at home")
            || q.contains("work out at home") || q.contains("working out at home") { return .homeMinimal }
        return nil
    }

    /// Display names for equipment (mirrors the plan-settings labels).
    static func equipmentLabel(_ equipment: Equipment) -> String {
        switch equipment {
        case .fullGym: "Full gym"
        case .dumbbellsOnly: "Dumbbells only"
        case .homeMinimal: "Home minimal"
        case .bodyweight: "Bodyweight"
        }
    }

    /// A weekly day count named in the message ("5 days a week", "train four days", "3-day week"),
    /// 1…7, else nil. Requires a "day" mention so other numbers (miles, dates) don't misread.
    private static func weeklyDayCount(in q: String) -> Int? {
        guard q.contains("day") else { return nil }
        let words: [(String, Int)] = [("one", 1), ("two", 2), ("three", 3), ("four", 4),
                                      ("five", 5), ("six", 6), ("seven", 7)]
        for (w, n) in words where q.contains("\(w) day") || q.contains("\(w)-day") { return n }
        for n in 1...7 where q.contains("\(n) day") || q.contains("\(n)-day") { return n }
        return nil
    }

    /// Parse "move <weekday|today|tomorrow>('s) <anything> to <weekday>" against the upcoming list.
    /// Conservative: exactly one resolvable source session and one target day, else no card (the
    /// text path will ask). Never guesses between two candidates.
    private static func moveProposal(_ q: String, context ctx: Context) -> LocalTurn? {
        let cal = ctx.calendar
        let symbols = cal.weekdaySymbols.map { $0.lowercased() }   // ["sunday", ...]

        // Which weekday names appear, in order of appearance?
        var mentioned: [(name: String, index: Int, pos: String.Index)] = []
        for (i, name) in symbols.enumerated() {
            var search = q.startIndex
            while let r = q.range(of: name, range: search..<q.endIndex) {
                mentioned.append((name, i + 1, r.lowerBound))
                search = r.upperBound
            }
        }
        mentioned.sort { $0.pos < $1.pos }

        // Source: "today"/"tomorrow" or the first mentioned weekday that has exactly one session.
        var source: UpcomingSession?
        if q.contains("today") {
            let todays = ctx.upcoming.filter { cal.isDate($0.date, inSameDayAs: Date()) }
            guard todays.count == 1 else { return nil }
            source = todays.first
        } else if q.contains("tomorrow") {
            guard let tm = cal.date(byAdding: .day, value: 1, to: Date()) else { return nil }
            let list = ctx.upcoming.filter { cal.isDate($0.date, inSameDayAs: tm) }
            guard list.count == 1 else { return nil }
            source = list.first
        }

        var targetWeekday: Int?
        if source != nil {
            // Source resolved by relative day — the first mentioned weekday is the target.
            targetWeekday = mentioned.first?.index
        } else {
            // Need two distinct weekday mentions: first = source day, last = target day.
            guard mentioned.count >= 2, mentioned.first!.index != mentioned.last!.index else { return nil }
            let sourceCandidates = ctx.upcoming.filter {
                cal.component(.weekday, from: $0.date) == mentioned.first!.index
            }
            guard sourceCandidates.count == 1 else { return nil }
            source = sourceCandidates.first
            targetWeekday = mentioned.last!.index
        }

        guard let session = source, let weekday = targetWeekday else { return nil }
        // The next occurrence of the target weekday, from tomorrow onward.
        guard let start = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())),
              let target = cal.nextDate(after: start - 1, matching: DateComponents(weekday: weekday),
                                        matchingPolicy: .nextTime) else { return nil }
        guard !cal.isDate(target, inSameDayAs: session.date) else { return nil }

        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"
        var card = CoachCardPayload(kind: .moveSession, label: "Move it")
        card.sessionId = session.id.uuidString
        card.newDateISO = dayFmt.string(from: target)
        let targetName = target.formatted(.dateTime.weekday(.wide))
        return LocalTurn(text: "Sure. I can move \(session.brief) to \(targetName). The rest of your week stands.",
                         card: card)
    }

    /// Distinct weekdays mentioned, in order of first appearance (1 = Sunday in Gregorian).
    private static func mentionedWeekdays(_ q: String, calendar: Calendar) -> [Int] {
        let symbols = calendar.weekdaySymbols.map { $0.lowercased() }
        var found: [(index: Int, pos: String.Index)] = []
        for (i, name) in symbols.enumerated() {
            if let r = q.range(of: name) { found.append((i + 1, r.lowerBound)) }
        }
        return found.sorted { $0.pos < $1.pos }.map(\.index)
    }

    /// The next date matching a weekday, today included.
    private static func nextDate(weekday: Int, from today: Date, calendar cal: Calendar) -> Date? {
        cal.nextDate(after: cal.startOfDay(for: today) - 1,
                     matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime)
    }

    /// After a move proposal, a short follow-up naming one other day retargets the SAME session:
    /// "Thursday instead", "what about Friday?", "make it Saturday". Conservative — needs the last
    /// coach card to be an open move, exactly one weekday, and a follow-up shape (marker or short).
    private static func moveFollowUp(_ q: String, context ctx: Context) -> LocalTurn? {
        guard let last = ctx.lastCard, last.kind == .moveSession, let sid = last.sessionId,
              let session = ctx.upcoming.first(where: { $0.id.uuidString == sid }) else { return nil }
        let days = mentionedWeekdays(q, calendar: ctx.calendar)
        guard days.count == 1, let weekday = days.first else { return nil }
        let isFollowUpShape = q.contains("instead") || q.contains("what about") || q.contains("make it")
            || q.contains("actually") || q.contains("rather") || q.count <= 16
            || ["move", "push", "swap", "reschedule", "shift"].contains(where: q.contains)
        guard isFollowUpShape else { return nil }
        guard let target = nextDate(weekday: weekday, from: Date(), calendar: ctx.calendar),
              !ctx.calendar.isDate(target, inSameDayAs: session.date),
              target > ctx.calendar.startOfDay(for: Date()) else { return nil }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        var card = CoachCardPayload(kind: .moveSession, label: "Move it")
        card.sessionId = session.id.uuidString
        card.newDateISO = fmt.string(from: target)
        return LocalTurn(text: "Even better. \(session.brief) lands on \(target.formatted(.dateTime.weekday(.wide))) then.",
                         card: card)
    }

    /// The move ask was clear but unresolvable — ask a smart question instead of changing the subject.
    private static func moveClarification(_ q: String, context ctx: Context) -> LocalTurn? {
        let cal = ctx.calendar
        let days = mentionedWeekdays(q, calendar: cal)
        if let first = days.first {
            let name = cal.weekdaySymbols[first - 1]
            let candidates = ctx.upcoming.filter { cal.component(.weekday, from: $0.date) == first }
            if candidates.count > 1 {
                let briefs = candidates.map(\.brief).joined(separator: " or ")
                return LocalTurn(text: "You've got more than one session on \(name): \(briefs). Which one am I moving, and to which day?", card: nil)
            }
            if candidates.count == 1, days.count == 1 {
                return LocalTurn(text: "I can move \(name)'s \(candidates[0].brief). Which day should it land on?", card: nil)
            }
            if candidates.isEmpty {
                return LocalTurn(text: "I don't see a session on \(name) in your next two weeks. Tell me which session you mean and where it should go, like \"move Tuesday's run to Thursday\".", card: nil)
            }
        }
        return LocalTurn(text: "Happy to shuffle the week. Which session, and which day should it land on? Something like \"move Tuesday's run to Thursday\" and I'll set it up.", card: nil)
    }

    /// "Can't make it" → the skip card when exactly one session resolves; a clarifying question when
    /// several do; the honest answer when none do. No-shame throughout — life wins some days.
    private static func skipProposal(_ q: String, context ctx: Context) -> LocalTurn? {
        let cal = ctx.calendar
        var candidates: [UpcomingSession] = []
        var dayName = "today"
        if q.contains("tomorrow") {
            guard let tm = cal.date(byAdding: .day, value: 1, to: Date()) else { return nil }
            candidates = ctx.upcoming.filter { cal.isDate($0.date, inSameDayAs: tm) }
            dayName = "tomorrow"
        } else if let wd = mentionedWeekdays(q, calendar: cal).first,
                  let target = nextDate(weekday: wd, from: Date(), calendar: cal) {
            candidates = ctx.upcoming.filter { cal.isDate($0.date, inSameDayAs: target) }
            dayName = target.formatted(.dateTime.weekday(.wide))
        } else {
            candidates = ctx.upcoming.filter { cal.isDateInToday($0.date) }
        }

        switch candidates.count {
        case 1:
            var card = CoachCardPayload(kind: .skipSession, label: "Clear it")
            card.sessionId = candidates[0].id.uuidString
            return LocalTurn(text: "Life wins some days, and that's fine. I can clear \(dayName)'s \(candidates[0].brief). No penalty, no makeup session, the plan flows on.",
                             card: card)
        case 0:
            return LocalTurn(text: "Nothing's planned \(dayName), so there's nothing to skip. If you meant another day, tell me which and I'll sort it.", card: nil)
        default:
            let briefs = candidates.map(\.brief).joined(separator: " or ")
            return LocalTurn(text: "You've got more than one session \(dayName): \(briefs). Which one should I clear?", card: nil)
        }
    }

    /// Extract the fact from "remember (that) …" phrasings; nil when it's not a remember ask.
    private static func rememberedNote(from message: String) -> String? {
        let lower = message.lowercased()
        guard let range = lower.range(of: "remember ") else { return nil }
        // Don't hijack questions ABOUT memory ("do you remember what I said?").
        guard !lower.contains("what do you remember"), !lower.hasPrefix("do you remember") else { return nil }
        var fact = String(message[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["that ", "this: ", "this — ", "please "] where fact.lowercased().hasPrefix(prefix) {
            fact = String(fact.dropFirst(prefix.count))
        }
        fact = fact.trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
        guard fact.count >= 3 else { return nil }
        return String(fact.prefix(160))
    }

    private static func throttleText(_ ctx: Context) -> String {
        let when = ctx.lastAdaptedAt.map { $0.formatted(.dateTime.weekday(.wide)) } ?? "recently"
        return "I already adjusted your plan \(when). One structural change a week keeps adaptation honest, so let's hold here for now. Ask me again in a few days."
    }

    /// The full offline reply — a confident grounded answer where we have one, else the generic
    /// capability fallback. Kept for callers that just want text no matter what.
    private static func rawReply(to message: String, context ctx: Context) -> String {
        groundedAnswer(to: message, context: ctx) ?? genericFallback(to: message, context: ctx)
    }

    /// A CONFIDENT, grounded answer — or `nil` when the question falls past everything we actually
    /// know (the point where we'd otherwise deflect with a generic capability line). That `nil` is
    /// the escalation signal: the app hands those questions to the Claude-backed coach, and only
    /// those, so the AI is used where it adds value and nowhere else (keeps it cheap).
    private static func groundedAnswer(to message: String, context ctx: Context) -> String? {
        let q = message.lowercased()
        let i = ctx.insights
        let s = ctx.stats
        let a = ctx.athlete

        func has(_ words: [String]) -> Bool { words.contains { q.contains($0) } }

        // What do you know about me / memory
        if has(["know about me", "remember", "who am i to you", "my profile", "what do you know"]) {
            let notes = a?.notes ?? []
            if notes.isEmpty {
                return "I'm still learning your patterns. The more you log, the sharper my read on how you train and recover."
            }
            return "Here's what I'm tracking: " + notes.prefix(3).joined(separator: "; ") + "."
        }

        // Post-workout debrief — grounded in the most recent workout's actual numbers.
        if let w = ctx.lastWorkout,
           has(["how did", "how was", "debrief", "review my"]),
           has(["run", "workout", "session", "ride", "walk", "lift", "that go", "it go"]) {
            var lines: [String] = []
            var head = "Your \(w.typeTitle.lowercased())"
            if Calendar.current.isDateInToday(w.date) { head += " today" }
            else if Calendar.current.isDateInYesterday(w.date) { head += " yesterday" }
            if let d = w.distanceM, d > 0 {
                head += ": \(Formatters.distance(meters: d, unit: ctx.distanceUnit)) in \(Formatters.duration(s: w.durationS))"
                if let pace = w.avgPaceSPerKm, pace > 0 { head += " (\(Formatters.pace(secPerKm: pace, unit: ctx.distanceUnit)))" }
            } else {
                head += ": \(Formatters.duration(s: w.durationS)) of work"
            }
            head += "."
            lines.append(head)
            if let reps = w.repsNote { lines.append(reps + ".") }
            else if let split = w.splitNote { lines.append(split.prefix(1).capitalized + split.dropFirst() + ".") }
            if let planned = w.plannedBrief { lines.append("That checked off \(planned).") }
            if let hr = w.avgHR { lines.append("Average heart rate \(hr) bpm.") }
            if let rpe = w.perceivedEffort {
                lines.append(rpe >= 8 ? "You rated it \(rpe)/10, so it cost something. Recovery earns the next one."
                                      : "You rated it \(rpe)/10. That's the right kind of sustainable.")
            } else {
                lines.append("Solid work. Rest well and the fitness lands.")
            }
            return lines.joined(separator: " ")
        }

        // The grounded Q&A pass — every answer from the athlete's own data, most specific first.
        // These sit ABOVE the broad catch-alls (today / overtraining / more) on purpose: "what
        // should I eat" must reach fueling, not the today branch.
        if let t = readinessAnswer(q, ctx) { return t }
        if let t = volumeAnswer(q, ctx) { return t }      // "how many km this week" beats the
        if let t = scheduleAnswer(q, ctx) { return t }    // schedule branch's broad "this week"
        if let t = fuelingAnswer(q, ctx) { return t }
        if let t = goalAnswer(q, ctx) { return t }
        if let t = paceTrendAnswer(q, ctx) { return t }
        // The curated knowledge library — the running questions every athlete asks, personalized
        // with their numbers where they exist. After the data branches so live data always wins.
        if let t = CoachKnowledge.answer(for: q, facts: facts(ctx)) { return t }

        // Today / what to do. "what should i" is spelled out to the real intents — bare "what should
        // i" also swallows "what should I look for / wear / buy", which belong in the library or to AI.
        if has(["today", "what should i do", "what should i run", "what do i do", "workout now", "should i train", "next session"]) {
            if let session = ctx.todaySession {
                let brief = PlanCoaching.brief(for: session, distanceUnit: ctx.distanceUnit)
                let why = session.rationale.map { " \($0)" } ?? ""
                return "Today's plan is \(brief).\(why) Tap Today's Plan when you're ready and I'll walk you in."
            }
            switch i.recommendation {
            case .rest, .ease:
                return "Nothing's scheduled, and your load is on the higher side. I'd keep it easy today: a short recovery walk or a rest day will pay off."
            default:
                let disc = a?.topDiscipline?.lowercased()
                    ?? (ctx.disciplines.contains("strength") && !ctx.disciplines.contains("running") ? "strength session" : "easy run")
                let mins = (a?.preferredSessionMinutes ?? 0) > 0 ? "\(a!.preferredSessionMinutes)-minute " : ""
                return "Nothing's on the calendar. If you're feeling good, a \(mins)\(disc) fits your goal nicely. Start one from the map."
            }
        }

        // Overtraining / recovery
        if has(["overtrain", "overdoing", "too much", "rest", "recover", "tired", "sore", "burn"]) {
            if i.recommendation == .rest {
                return TrainingLoadContext.summary(ratio: i.acwr)
                    + " Your recent response also supports easing off, so take a rest or recovery day. Rest is where the gains land."
            }
            if i.recommendation == .ease {
                return TrainingLoadContext.summary(ratio: i.acwr)
                    + " I’d pull the next session back about 15% so you can absorb the work."
            }
            return TrainingLoadContext.summary(ratio: i.acwr)
                + " No single ratio can say you are or aren’t overdoing it, so let pain, illness, and how you feel lead."
        }

        // Push harder / increase
        if has(["more", "harder", "increase", "push", "add", "ramp", "build"]) {
            switch i.recommendation {
            case .increase, .hold, .start:
                return "Your recent load does not call for a protective cutback. If the sessions are also landing well, we can consider one small, bounded progression next week. Open Progress to review it first."
            case .ease, .rest:
                return "I'd hold off on more right now, your load's already high at \(acwrText(i)). Let's absorb this block first, then ramp."
            }
        }

        // Streak
        if has(["streak", "consistent", "consistency", "days in a row"]) {
            let d = s.currentStreak
            if d <= 0 { return "No active streak yet. Knock out any session today and you're rolling. Rest days count, and one slipped day is always forgiven." }
            return "\(d) day\(d == 1 ? "" : "s") and counting. Rest days count and a single slipped day is forgiven, so just keep moving. You won't lose it easily."
        }

        // PRs / records. The short tokens ("pr", "max") must match as whole WORDS — a bare substring
        // check fires on "prevent", "prep", "approach", "maximum", stealing those questions from the
        // knowledge library (and from AI escalation) with a nonsense records reply.
        let words = Set(q.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if has(["record", "strongest", "best lift", "1rm", "e1rm", "personal best"])
            || !words.isDisjoint(with: ["pr", "prs", "max", "maxes"]) {
            if let pr = s.strengthPRs.first {
                return "Your standout is \(pr.name) at an estimated \(Formatters.weight(kg: pr.e1RMKg, unit: .default())) one-rep max. Keep the working sets honest and that'll climb."
            }
            return "No strength PRs on the board yet. Log a few lifting sessions and I'll start tracking your estimated maxes."
        }

        // How am I doing / progress / trending
        if has(["how am i", "progress", "trend", "doing", "improv", "getting better", "fitness"]) {
            var line = ProgressNarrator.coach(i, streak: s.currentStreak)
            if let p = a?.paceTrendPct, p <= -2 {
                line += " Your easy pace at the same effort is about \(Int(abs(p)))% quicker than two months ago, so the engine's growing."
            }
            return line
        }

        // Greeting
        if has(["hi", "hey", "hello", "yo", "sup"]) && q.count < 12 {
            return "Hey, I'm your coach. I can talk through how you're trending, what to do today, recovery, or your records. What's on your mind?"
        }

        // Fell past everything we confidently answer — signal the caller to escalate (or, offline,
        // fall back to the generic capability line below).
        return nil
    }

    /// The last-resort offline reply when no grounded answer matched and the AI coach is unavailable:
    /// a near-miss nudge toward the closest real capability, then a varied grounded capability line.
    private static func genericFallback(to message: String, context ctx: Context) -> String {
        let q = message.lowercased()
        let i = ctx.insights
        if let nudge = capabilityNudge(q) { return nudge }
        let lead = i.hasData
            ? "Your recent load is \(acwrText(i)) — \(TrainingLoadContext.band(ratio: i.acwr).displayName.lowercased())."
            : "We're just getting started. Log a few sessions and I'll have a lot more to say."
        let tails = [
            "I can help with how you're trending, what to do today, recovery, or your records. Just ask.",
            "Ask me about your week ahead, your paces and zones, fueling a long run, or whether you're on track for your goal.",
            "I'm best with questions about your plan, your training, and how running works. Try me on any of those."
        ]
        let seed = q.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return "\(lead) \(tails[seed % tails.count])"
    }

    // MARK: - Grounded Q&A (v3 — the offline coach that answers, not deflects)

    private static let noPlanLine = "Your plan doesn't have upcoming sessions right now. Set one up in plan settings and I'll have real answers here."

    private static func facts(_ ctx: Context) -> CoachKnowledge.Facts {
        CoachKnowledge.Facts(p5kSPerKm: ctx.p5kSPerKm,
                             raceDistanceM: ctx.race?.distanceM,
                             weeksToRace: ctx.race?.weeksOut,
                             daysPerWeek: ctx.settings.daysPerWeek,
                             distanceUnit: ctx.distanceUnit)
    }

    /// "I'm tired, should I still train?" — the wearable-grade answer, from their actual signals.
    private static func readinessAnswer(_ q: String, _ ctx: Context) -> String? {
        let triggers = ["tired", "exhausted", "slept", "rough night", "no sleep", "low energy",
                        "feeling flat", "feel flat", "wiped", "worn out", "drained", "run down",
                        "am i recovered", "how recovered", "readiness", "ready to train",
                        "should i rest", "fatigued", "no sleep last"]
        guard triggers.contains(where: q.contains) else { return nil }
        let r = ctx.recovery
        let tier = PlanIntensity(rawValue: ctx.settings.planIntensity ?? "") ?? .balanced

        if let decision = RecoveryAdaptation.decide(signals: r, intensity: tier) {
            let todayBit = ctx.todaySession != nil
                ? "I'd downshift today to genuinely easy instead of pushing through"
                : "keep today genuinely easy"
            return "Listen to that feeling, because your body agrees: \(decision.reason). So \(todayBit). One soft day now beats three forced ones later, and the plan absorbs it without drama."
        }
        if r.hasPhysio {
            var bits: [String] = []
            if let n = r.hrvNote { bits.append("HRV \(n)") }
            if let n = r.restingHRNote { bits.append("resting HR \(n)") }
            if let n = r.sleepNote { bits.append("sleep \(n)") }
            return "Tired and under-recovered aren't the same thing, so I checked your signals: \(bits.joined(separator: ", ")). No recovery signal is calling for an automatic ease, but that is not a clearance test. Start the warmup, and if it still feels like concrete after ten minutes, downshift to easy."
        }
        // No wearable data — answer from load, and say how to get the better answer.
        let i = ctx.insights
        switch i.recommendation {
        case .rest, .ease:
            return "Your last 7 days are high relative to your recent norm (\(acwrText(i))). That supports a conservative easy or rest day, especially because you feel tired. Connect Apple Health and I'll add HRV, resting HR, and sleep context from the day you connect."
        default:
            return "Your load is \(acwrText(i)) versus your recent norm, but that does not clear you to push. Start easy, and if it doesn't come around in ten minutes, call it. Connect Apple Health and I'll read HRV, resting HR, and sleep to add recovery context."
        }
    }

    /// Schedule questions answered straight from the upcoming list the plan already computed.
    private static func scheduleAnswer(_ q: String, _ ctx: Context) -> String? {
        let cal = ctx.calendar
        func daySessions(_ date: Date) -> [UpcomingSession] {
            ctx.upcoming.filter { cal.isDate($0.date, inSameDayAs: date) }
        }
        func dayLine(_ s: UpcomingSession) -> String {
            "\(s.date.formatted(.dateTime.weekday(.wide))): \(s.brief)"
        }

        // When's my race?
        if ["when is my race", "when's my race", "whens my race", "how long until my race",
            "how far out is my race", "days until my race", "how many weeks until my race"].contains(where: q.contains) {
            guard let race = ctx.race else {
                return "There's no race on your calendar yet. Point your plan at one in plan settings and every week here gets a job."
            }
            let dist = race.distanceM.map { " (\(Formatters.distance(meters: $0, unit: ctx.distanceUnit)))" } ?? ""
            return "Your race\(dist) is \(race.date.formatted(date: .abbreviated, time: .omitted)), \(race.weeksOut) week\(race.weeksOut == 1 ? "" : "s") out. Everything between now and then is building toward it."
        }
        // When's my long run?
        if ["when's my long run", "when is my long run", "whens my long run", "next long run",
            "long run this week", "which day is my long run", "do i have a long run"].contains(where: q.contains) {
            if let long = ctx.upcoming.first(where: { $0.brief.lowercased().contains("long") }) {
                return "Your long run is \(dayLine(long)). Keep it unhurried, that's where the engine grows."
            }
            return ctx.upcoming.isEmpty ? noPlanLine
                : "No long run in your next two weeks. That's usually deliberate (a recovery or rebuild stretch), and if it feels off, ask me why your plan is built this way."
        }
        // Next hard session?
        if ["next hard session", "next quality", "next workout", "next intervals", "next tempo",
            "when are my intervals", "when's my intervals", "when is my tempo", "when's my tempo"].contains(where: q.contains) {
            if let hard = ctx.upcoming.first(where: {
                let b = $0.brief.lowercased()
                return b.contains("interval") || b.contains("tempo") || b.contains("fartlek")
                    || b.contains("hill") || b.contains("progression") || b.contains("race")
            }) {
                return "Your next hard one is \(dayLine(hard)). Protect the easy days around it and it counts double."
            }
            return ctx.upcoming.isEmpty ? noPlanLine
                : "Nothing hard is on the schedule in the next two weeks. That's usually a recovery or base stretch doing its quiet work."
        }
        // Next run / next session?
        if ["next run", "when do i run next", "when do i train next", "my next session", "when's my next session"].contains(where: q.contains) {
            guard let next = ctx.upcoming.first else { return noPlanLine }
            let day = cal.isDateInToday(next.date) ? "today"
                : cal.isDateInTomorrow(next.date) ? "tomorrow"
                : next.date.formatted(.dateTime.weekday(.wide))
            return "Next up is \(day): \(next.brief)."
        }
        // Tomorrow?
        if q.contains("tomorrow") {
            guard let tm = cal.date(byAdding: .day, value: 1, to: Date()) else { return nil }
            let list = daySessions(tm)
            if list.isEmpty {
                if let next = ctx.upcoming.first(where: { $0.date > tm }) {
                    return "Tomorrow's a rest day, and it counts. Next up is \(dayLine(next))."
                }
                return "Tomorrow's clear. Rest is training too."
            }
            return "Tomorrow: \(list.map(\.brief).joined(separator: ", plus ")). I'll brief you properly when the day comes."
        }
        // This week?
        if ["this week", "week ahead", "rest of the week", "week look", "week going to look", "my week coming"].contains(where: q.contains) {
            guard let week = cal.dateInterval(of: .weekOfYear, for: Date()) else { return nil }
            let remaining = ctx.upcoming.filter { $0.date >= cal.startOfDay(for: Date()) && $0.date < week.end }
            guard !remaining.isEmpty else {
                return ctx.upcoming.isEmpty ? noPlanLine
                    : "The rest of this week is clear, on purpose. Next up is \(ctx.upcoming.first.map(dayLine) ?? "next week")."
            }
            let lines = remaining.map(dayLine).joined(separator: ". ")
            return "The rest of your week: \(lines). \(remaining.count == 1 ? "One session, and it has a job." : "\(remaining.count) sessions, each with a job.")"
        }
        // A specific weekday?
        if ["what's on", "whats on", "do i have", "am i running", "am i training", "anything on", "what do i have"].contains(where: q.contains),
           let wd = mentionedWeekdays(q, calendar: cal).first,
           let target = nextDate(weekday: wd, from: Date(), calendar: cal) {
            let list = daySessions(target)
            let name = target.formatted(.dateTime.weekday(.wide))
            guard !list.isEmpty else {
                return "\(name)'s a rest day as it stands. That's on purpose: the quiet days are where the work lands."
            }
            return "\(name): \(list.map(\.brief).joined(separator: ", plus "))."
        }
        return nil
    }

    /// Fueling grounded in the actual session in question (their race, their long run, today).
    private static func fuelingAnswer(_ q: String, _ ctx: Context) -> String? {
        let triggers = ["what should i eat", "what to eat", "eat before", "eat during", "eat after",
                        "should i eat", "fueling", "fuel for", "fuel my", "gel", "gels",
                        "how much water", "should i drink", "drink during", "drink on", "hydrat",
                        "nutrition for"]
        guard triggers.contains(where: q.contains) else { return nil }
        func compose(_ g: FuelingGuide.Guidance, lead: String) -> String {
            let body = "\(lead) Before: \(g.before) During: \(g.during) After: \(g.after)"
            // FuelingGuide copy uses en-dash ranges ("30–60 g") — read them as "to", never mangle.
            return body.replacingOccurrences(of: "–", with: " to ")
        }
        if q.contains("race"), let race = ctx.race, let d = race.distanceM, d > 0,
           let p5k = ctx.p5kSPerKm, p5k > 0 {
            let dur = PlanFeasibility.predictedFinishS(distanceM: d, p5kSPerKm: p5k)
            return compose(FuelingGuide.guidance(durationS: dur, isRace: true),
                           lead: "Your race should take you about \(Formatters.duration(s: dur)), so here's the fueling.")
        }
        if q.contains("long"),
           let long = ctx.upcoming.first(where: { $0.brief.lowercased().contains("long") }),
           let dur = long.estimatedDurationS {
            return compose(FuelingGuide.guidance(durationS: dur),
                           lead: "Your \(long.date.formatted(.dateTime.weekday(.wide))) long run is around \(Formatters.duration(s: dur)).")
        }
        if let today = ctx.todaySession,
           let dur = FuelingGuide.estimatedDurationS(distanceM: today.targetDistanceM,
                                                     paceSPerKm: today.targetPaceSPerKm,
                                                     durationS: today.targetDurationS) {
            return compose(FuelingGuide.guidance(durationS: dur),
                           lead: "Today's session runs about \(Formatters.duration(s: dur)).")
        }
        return "The simple rule: under an hour, water covers it. Between 1 and 2.5 hours, take 30 to 60 g of carbs per hour, starting early. Beyond that, work up to 60 to 90 g per hour and train your gut on long runs. Drink to thirst throughout. \(FuelingGuide.Guidance.disclaimer)"
    }

    /// "Am I on track?" — the honest feasibility verdict, on demand. This is the moat: a coach that
    /// tells the truth about the goal instead of cheering.
    private static func goalAnswer(_ q: String, _ ctx: Context) -> String? {
        let triggers = ["on track", "am i ready for", "will i be ready", "realistic", "hit my goal",
                        "reach my goal", "make my goal", "achievable", "can i break",
                        "going to hit", "gonna hit", "am i going to make", "ready for my race"]
        guard triggers.contains(where: q.contains) else { return nil }
        guard let f = ctx.feasibility else {
            return "I don't have a plan to measure against yet. Set one up in plan settings and I'll give you the honest read, on track or not."
        }
        var out: String
        switch f.verdict {
        case .noRace:
            return "There's no dated race on your plan, so there's no clock to beat, just fitness to build. \(f.detail) Point the plan at a race whenever you're ready and I'll tell you straight whether the goal is reachable."
        case .onTrack:
            out = "Yes, you're on track. \(f.detail)"
        case .tight:
            out = "It's tight, but it's live. \(f.detail) The difference will be made by not missing weeks, not by hero sessions."
        case .tooShort:
            out = "Honest answer: not by race day as it stands. \(f.detail)"
            if !f.options.isEmpty {
                out += " Your real options: \(f.options.joined(separator: "; "))."
            }
        }
        if let t = f.realisticFinishS, f.verdict != .noRace {
            out += " A realistic finish by then is around \(Formatters.duration(s: t))."
        }
        return out
    }

    /// Volume lookups from the log — this week, all time, the longest.
    private static func volumeAnswer(_ q: String, _ ctx: Context) -> String? {
        let triggers = ["how far have i", "how many miles", "how many km", "how many kilometers",
                        "mileage", "weekly volume", "total distance", "how much have i run",
                        "how much did i run", "longest run", "distance this week", "distance this month"]
        guard triggers.contains(where: q.contains) else { return nil }
        let unit = ctx.distanceUnit
        if q.contains("longest") {
            guard ctx.stats.longestRunM > 0 else {
                return "No runs on the books yet, so the longest is still ahead of you. I like that better anyway."
            }
            return "Your longest run on record is \(Formatters.distance(meters: ctx.stats.longestRunM, unit: unit)). The long run is where that number quietly grows."
        }
        if q.contains("week") {
            guard ctx.weekDistanceM > 0 || ctx.prevWeekDistanceM > 0 else {
                return "Nothing logged this week yet. The week's young, or it's a planned quiet one, either way the streak rules are on your side."
            }
            var out = "You've covered \(Formatters.distance(meters: ctx.weekDistanceM, unit: unit)) so far this week."
            if ctx.prevWeekDistanceM > 0 {
                let pct = Int(((ctx.weekDistanceM - ctx.prevWeekDistanceM) / ctx.prevWeekDistanceM * 100).rounded())
                if pct <= -15 { out += " That's \(abs(pct))% down on last week's \(Formatters.distance(meters: ctx.prevWeekDistanceM, unit: unit)), which is fine if it's planned recovery." }
                else if pct >= 15 { out += " That's \(pct)% up on last week, so let the easy days stay easy while it absorbs." }
                else { out += " Right in line with last week's \(Formatters.distance(meters: ctx.prevWeekDistanceM, unit: unit)). Consistency is the whole trick." }
            }
            return out
        }
        guard ctx.stats.totalDistanceM > 0 else {
            return "The odometer's at zero so far, which just means everything counts double for a while. Log a run and we're rolling."
        }
        return "All time you've logged \(Formatters.distance(meters: ctx.stats.totalDistanceM, unit: unit)) across \(ctx.stats.totalWorkouts) workouts. Every one of them is in the bank."
    }

    /// "Am I getting faster?" — the matched-effort pace trend, told straight.
    private static func paceTrendAnswer(_ q: String, _ ctx: Context) -> String? {
        let triggers = ["getting faster", "am i faster", "faster than last", "pace improving",
                        "has my pace", "pace trend", "pace getting"]
        guard triggers.contains(where: q.contains) else { return nil }
        guard let p = ctx.athlete?.paceTrendPct, p != 0 else {
            return "I compare your pace at matched effort over time, and I don't have enough matched runs yet to say honestly. A few more easy runs with heart rate and I'll have your answer."
        }
        if p <= -2 {
            return "Yes. Your easy pace at the same effort is about \(Int(abs(p)))% quicker than two months ago. That's the engine growing, and it's the trend that matters most."
        }
        if p >= 2 {
            return "At matched effort you're about \(Int(p))% slower than two months ago, and before that worries you: heat, life stress, and a heavy training block all do this temporarily. If your load is high, it's fitness being built, not lost. I'm watching it."
        }
        return "Your pace at matched effort is holding steady. Flat stretches are where the adaptation consolidates, and the jumps tend to arrive after them."
    }

    /// The near-miss nudge: point at the closest real capability instead of a generic shrug.
    private static func capabilityNudge(_ q: String) -> String? {
        let table: [(keys: [String], nudge: String)] = [
            (["pace", "zone", "speed"], "I keep your zones and training paces computed from your own fitness. Ask \"what are my zones\" and I'll lay them out."),
            (["plan", "schedule"], "I can walk you through exactly why your plan looks the way it does, number by number. Ask \"why is my plan built this way\"."),
            (["race", "5k", "10k", "marathon"], "I can tell you what you could race today, or build your race pacing. Try \"what could I race right now\" or \"how should I run my race\"."),
            (["hurt", "pain", "injur", "sore"], "If something's bothering you, tell me where (like \"my knee hurts\") and I'll adjust the plan around it, no drama."),
            (["eat", "food", "fuel", "drink"], "I can plan your fueling from your actual session lengths. Ask \"what should I eat before my long run\"."),
            (["tired", "sleep", "recover"], "Ask me \"should I train today?\" and I'll answer from your recovery signals, not a guess.")
        ]
        return table.first { $0.keys.contains(where: q.contains) }?.nudge
    }

    private static func acwrText(_ i: ProgressInsights) -> String {
        i.acwr > 0 ? String(format: "%.2f", i.acwr) : "still building"
    }

    /// Belt-and-suspenders: turn any em/en dash (the AI-slop tell) into clean sentence punctuation.
    /// Hyphens in compound words (3-day, well-absorbed) are left alone.
    static func deDash(_ s: String) -> String {
        guard s.contains("—") || s.contains("–") else { return s }
        let pieces = s.replacingOccurrences(of: "–", with: "—")
            .components(separatedBy: "—")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return pieces.enumerated().reduce(into: "") { acc, e in
            let (idx, piece) = e
            let capped = idx == 0 ? piece : piece.prefix(1).uppercased() + piece.dropFirst()
            if idx == 0 { acc = capped } else { acc += ". " + capped }
        }
    }
}
