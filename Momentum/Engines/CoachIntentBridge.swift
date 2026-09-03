import Foundation

/// Where a coach nav card can send the athlete (deep links the chat can offer).
/// `viewHealth` lands on Progress → Health (the readiness hub) via `AppRouter` — the shell sets
/// `pendingTab = .progress` + `pendingProgressSegment` (docs/RECOVERY-HUB-PLAN.md §2).
enum CoachDestination: String, Codable, Sendable, Equatable {
    case startToday, viewPlanWeek, viewProgress, raceBriefing, planSettings, viewHealth
}

/// A coach card as it arrives off the wire (the `coach-chat` Edge Function's structured output, or
/// the offline `CoachResponder`). A flat parameter bag + `kind` — deliberately NOT a typed union,
/// because nothing in it is trusted: every field is re-validated into a `CoachIntent` before the app
/// will render an Apply button, and a flat bag can't fail to decode on a variant mismatch.
struct CoachCardPayload: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case none, nav
        case changeGoal, changeRace, changeDays, changeSessionLength
        /// A tune-up race added to the season (2026-09-03): raced (B) or trained through (C). The
        /// goal race and the block are untouched; only the week it lands in bends.
        case addTuneUp
        case moveSession, skipSession
        case easeWeek, bumpLoad, easePaces
        case changeEquipment, injuryReport, pausePlan, resumePlan
        /// A fresh block from today: rolling plans renew (reassess + next block), race plans rebuild
        /// toward their race. The chat's "start over / next block" move.
        case renewBlock
        /// The "what should we change?" menu — pure conversation steering, never applies anything.
        /// Each row sends its intent back through the chat, where the specific flow takes over.
        case adjustPlan
        // Informational cards (no plan mutation): the personalized breakdowns.
        case explainPlan, weekRecap, racePlan, memory
        case racePredictor, todayBriefing, zones
        case rememberNote  // writes ONE pinned note to the athlete's memory, on confirm
    }

    var kind: Kind
    var label: String
    // Parameter bag — a card fills only what its kind needs. Ids/enum values must be echoed from
    // the context we sent; anything else fails validation and the card is silently dropped.
    var nav: String?
    var goal: String?
    var raceDistanceM: Double?
    var raceDateISO: String?
    /// A race named from our catalog ("Chicago Marathon", "NYC Half") — the app resolves the exact
    /// distance + date via `RaceCatalog`, so the LLM never has to know a race's calendar. Preferred
    /// over raceDistanceM/raceDateISO for any race the catalog knows.
    var raceName: String?
    var goalFinishTimeS: Double?
    /// addTuneUp: "b" (race it) or "c" (train through). Missing = race it.
    var tuneUpPriority: String?
    var daysPerWeek: Int?
    var preferredDays: [Int]?
    var sessionMinutes: Int?
    var equipment: String?
    var sessionId: String?
    var newDateISO: String?
    var injuryArea: String?
    var injurySeverity: String?
    var pauseDays: Int?
    var note: String?              // rememberNote: the distilled fact to keep
    var noteCategory: String?      // rememberNote: MemoryCategory raw value (optional)

    init(kind: Kind, label: String) {
        self.kind = kind
        self.label = label
    }

    /// Decoding an unknown `kind` string must not throw away the reply — map it to `.none`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .none
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        nav = try? c.decodeIfPresent(String.self, forKey: .nav)
        goal = try? c.decodeIfPresent(String.self, forKey: .goal)
        raceDistanceM = try? c.decodeIfPresent(Double.self, forKey: .raceDistanceM)
        raceDateISO = try? c.decodeIfPresent(String.self, forKey: .raceDateISO)
        raceName = try? c.decodeIfPresent(String.self, forKey: .raceName)
        goalFinishTimeS = try? c.decodeIfPresent(Double.self, forKey: .goalFinishTimeS)
        daysPerWeek = try? c.decodeIfPresent(Int.self, forKey: .daysPerWeek)
        preferredDays = try? c.decodeIfPresent([Int].self, forKey: .preferredDays)
        sessionMinutes = try? c.decodeIfPresent(Int.self, forKey: .sessionMinutes)
        equipment = try? c.decodeIfPresent(String.self, forKey: .equipment)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        newDateISO = try? c.decodeIfPresent(String.self, forKey: .newDateISO)
        injuryArea = try? c.decodeIfPresent(String.self, forKey: .injuryArea)
        injurySeverity = try? c.decodeIfPresent(String.self, forKey: .injurySeverity)
        pauseDays = try? c.decodeIfPresent(Int.self, forKey: .pauseDays)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        noteCategory = try? c.decodeIfPresent(String.self, forKey: .noteCategory)
    }
}

/// A validated, typed coach intent — the only thing `CoachActions` will ever execute. Every case's
/// parameters have been clamped/resolved against the athlete's actual plan.
enum CoachIntent: Equatable, Sendable {
    case navigate(CoachDestination)
    case changeGoal(Goal)
    case changeRace(distanceM: Double, date: Date, goalFinishTimeS: Double?)
    case addTuneUp(name: String, distanceM: Double, date: Date, racesIt: Bool, goalFinishTimeS: Double?)
    case changeDays(daysPerWeek: Int?, preferredDays: [Int]?)   // at least one is non-nil
    case changeSessionLength(minutes: Int)
    case moveSession(id: UUID, to: Date)
    case skipSession(id: UUID)
    case easeWeek
    case bumpLoad
    case easePaces
    case changeEquipment(Equipment)
    case injuryReport(area: InjuryArea, severity: InjurySeverity)
    case pausePlan(days: Int)
    case resumePlan
    case renewBlock
    case explainPlan
    case weekRecap
    case racePlan
    case showMemory
    case racePredictor
    case todayBriefing
    case showZones
    case rememberNote(text: String, category: MemoryCategory)
}

/// Pure validation of an untrusted `CoachCardPayload` into a typed `CoachIntent` — the trust
/// boundary between the LLM and the deterministic engines ("rules compute, AI narrates"). Clamps
/// where a nearby value is obviously meant; rejects (returns nil ⇒ card dropped, reply text kept)
/// where guessing would be unsafe. No SwiftData — fixture-testable like every other engine.
enum CoachIntentBridge {

    /// Everything validation needs, as plain values.
    struct Snapshot: Sendable {
        var today: Date
        /// Future, still-planned sessions the LLM was told about — the ONLY sessions it may reference.
        var upcomingSessions: [(id: UUID, date: Date)]
        var isPaused: Bool
        var calendar: Calendar

        init(today: Date, upcomingSessions: [(id: UUID, date: Date)] = [],
             isPaused: Bool = false, calendar: Calendar = .current) {
            self.today = today
            self.upcomingSessions = upcomingSessions
            self.isPaused = isPaused
            self.calendar = calendar
        }
    }

    static func validate(_ payload: CoachCardPayload, snapshot: Snapshot) -> CoachIntent? {
        switch payload.kind {
        case .none:
            return nil

        case .nav:
            guard let raw = payload.nav, let dest = CoachDestination(rawValue: raw) else { return nil }
            return .navigate(dest)

        case .changeGoal:
            guard let raw = payload.goal, let goal = Goal(rawValue: raw) else { return nil }
            return .changeGoal(goal)

        case .changeRace:
            var goalTime = payload.goalFinishTimeS
            if let t = goalTime, !(8 * 60...24 * 3600).contains(t) { goalTime = nil }   // nonsense target → drop, keep the race
            // Preferred: a named catalog race resolves to its exact distance + date deterministically
            // (the same catalog onboarding and plan settings use). Resolved fresh against `today`.
            if let name = payload.raceName,
               let m = RaceCatalog.match(freeText: name, after: snapshot.today, calendar: snapshot.calendar),
               m.date > snapshot.today, withinHorizon(m.date, snapshot: snapshot) {
                return .changeRace(distanceM: m.distance.meters, date: m.date, goalFinishTimeS: goalTime)
            }
            // Fallback: an explicit distance + date (a custom race not in the catalog).
            guard let distance = payload.raceDistanceM, (1_000...100_000).contains(distance),
                  let date = parseDay(payload.raceDateISO, snapshot: snapshot),
                  date > snapshot.today, withinHorizon(date, snapshot: snapshot) else { return nil }
            return .changeRace(distanceM: distance, date: date, goalFinishTimeS: goalTime)

        case .addTuneUp:
            var goalTime = payload.goalFinishTimeS
            if let t = goalTime, !(8 * 60...24 * 3600).contains(t) { goalTime = nil }
            let racesIt = (payload.tuneUpPriority ?? "b").lowercased() != "c"
            // A week can bend around a race only when there is a week to bend: seven days out at least.
            let earliest = snapshot.calendar.date(byAdding: .day, value: 7,
                                                  to: snapshot.calendar.startOfDay(for: snapshot.today)) ?? snapshot.today
            if let name = payload.raceName,
               let m = RaceCatalog.match(freeText: name, after: snapshot.today, calendar: snapshot.calendar),
               m.date >= earliest, withinHorizon(m.date, snapshot: snapshot) {
                return .addTuneUp(name: m.race.name, distanceM: m.distance.meters, date: m.date,
                                  racesIt: racesIt, goalFinishTimeS: goalTime)
            }
            guard let distance = payload.raceDistanceM, (1_000...100_000).contains(distance),
                  let date = parseDay(payload.raceDateISO, snapshot: snapshot),
                  date >= earliest, withinHorizon(date, snapshot: snapshot) else { return nil }
            return .addTuneUp(name: payload.raceName ?? "", distanceM: distance, date: date,
                              racesIt: racesIt, goalFinishTimeS: goalTime)

        case .changeDays:
            let days = payload.daysPerWeek.map { min(7, max(1, $0)) }
            let preferred = payload.preferredDays.map { Array(Set($0.filter { (1...7).contains($0) })).sorted() }
            guard days != nil || !(preferred ?? []).isEmpty else { return nil }
            return .changeDays(daysPerWeek: days, preferredDays: (preferred?.isEmpty ?? true) ? nil : preferred)

        case .changeSessionLength:
            guard let minutes = payload.sessionMinutes else { return nil }
            return .changeSessionLength(minutes: min(120, max(20, minutes)))

        case .moveSession:
            guard let session = resolveSession(payload.sessionId, snapshot: snapshot),
                  let target = parseDay(payload.newDateISO, snapshot: snapshot),
                  target >= snapshot.calendar.startOfDay(for: snapshot.today),
                  withinHorizon(target, snapshot: snapshot),
                  !snapshot.calendar.isDate(target, inSameDayAs: session.date) else { return nil }
            return .moveSession(id: session.id, to: target)

        case .skipSession:
            guard let session = resolveSession(payload.sessionId, snapshot: snapshot) else { return nil }
            return .skipSession(id: session.id)

        case .easeWeek: return .easeWeek
        case .bumpLoad: return .bumpLoad
        case .easePaces: return .easePaces

        case .changeEquipment:
            guard let raw = payload.equipment, let equipment = Equipment(rawValue: raw) else { return nil }
            return .changeEquipment(equipment)

        case .injuryReport:
            // Severity intentionally strict: without it there is no safe default — the card UI
            // renders a severity picker and re-validates once the athlete answers.
            guard let areaRaw = payload.injuryArea, let area = InjuryArea(rawValue: areaRaw),
                  let sevRaw = payload.injurySeverity, let severity = InjurySeverity(rawValue: sevRaw)
            else { return nil }
            return .injuryReport(area: area, severity: severity)

        case .pausePlan:
            guard !snapshot.isPaused else { return nil }
            return .pausePlan(days: min(28, max(1, payload.pauseDays ?? 7)))

        case .resumePlan:
            guard snapshot.isPaused else { return nil }
            return .resumePlan

        case .renewBlock:
            return .renewBlock   // parameterless; apply resolves rolling-vs-race honestly

        case .adjustPlan:
            // The menu card steers conversation only — it has no executable intent. Returning nil
            // keeps it out of the apply path; the chat UI renders its rows and keeps it alive.
            return nil

        case .explainPlan:
            return .explainPlan

        case .weekRecap:
            return .weekRecap

        case .racePlan:
            return .racePlan

        case .memory:
            return .showMemory

        case .racePredictor:
            return .racePredictor

        case .todayBriefing:
            return .todayBriefing

        case .zones:
            return .showZones

        case .rememberNote:
            // The note is a fact about the athlete, kept verbatim after hygiene: 3–160 chars,
            // single line. Category defaults to preference when absent/unknown.
            guard let raw = payload.note?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            let flattened = raw.replacingOccurrences(of: "\n", with: " ")
            guard flattened.count >= 3 else { return nil }
            let text = String(flattened.prefix(160))
            let category = payload.noteCategory.flatMap(MemoryCategory.init(rawValue:)) ?? .preference
            return .rememberNote(text: text, category: category)
        }
    }

    // MARK: - Helpers

    /// Strict "yyyy-MM-dd" in the athlete's calendar/timezone, normalized to start of day.
    private static func parseDay(_ iso: String?, snapshot: Snapshot) -> Date? {
        guard let iso else { return nil }
        let fmt = DateFormatter()
        fmt.calendar = snapshot.calendar
        fmt.timeZone = snapshot.calendar.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: iso) else { return nil }
        return snapshot.calendar.startOfDay(for: date)
    }

    /// Sanity horizon: nothing the coach proposes may land more than 18 months out.
    private static func withinHorizon(_ date: Date, snapshot: Snapshot) -> Bool {
        guard let limit = snapshot.calendar.date(byAdding: .month, value: 18, to: snapshot.today) else { return false }
        return date <= limit
    }

    /// The LLM may only reference sessions we told it about (`Snapshot.upcomingSessions`).
    private static func resolveSession(_ idString: String?, snapshot: Snapshot) -> (id: UUID, date: Date)? {
        guard let idString, let id = UUID(uuidString: idString) else { return nil }
        return snapshot.upcomingSessions.first { $0.id == id }
    }
}
