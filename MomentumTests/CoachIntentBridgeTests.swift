import Testing
import Foundation
@testable import Momentum

/// The trust boundary between the LLM and the deterministic engines: untrusted `CoachCardPayload`s
/// are clamped/resolved into typed `CoachIntent`s, or rejected (nil ⇒ the card is dropped and the
/// reply stays plain text). Pure — no SwiftData.
struct CoachIntentBridgeTests {

    private let cal = Calendar.current
    private var today: Date { cal.startOfDay(for: Date()) }

    private func snapshot(upcoming: [(UUID, Date)] = [], isPaused: Bool = false) -> CoachIntentBridge.Snapshot {
        .init(today: today, upcomingSessions: upcoming.map { (id: $0.0, date: $0.1) }, isPaused: isPaused)
    }

    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    private func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: Wire decode (the exact shape the edge function emits)

    @Test func decodesWireCardAndUnknownKindDegradesToNone() throws {
        let good = #"{"kind":"easeWeek","label":"Ease this week"}"#
        let card = try JSONDecoder().decode(CoachCardPayload.self, from: Data(good.utf8))
        #expect(card.kind == .easeWeek)
        #expect(card.label == "Ease this week")

        // A kind we don't know (schema drift) must not throw — it degrades to .none.
        let drifted = #"{"kind":"teleportAthlete","label":"Zap"}"#
        let unknown = try JSONDecoder().decode(CoachCardPayload.self, from: Data(drifted.utf8))
        #expect(unknown.kind == .none)
    }

    @Test func decodesFullMoveSessionCard() throws {
        let id = UUID()
        let json = #"{"kind":"moveSession","label":"Move it","sessionId":"\#(id.uuidString)","newDateISO":"2026-08-01"}"#
        let card = try JSONDecoder().decode(CoachCardPayload.self, from: Data(json.utf8))
        #expect(card.sessionId == id.uuidString)
        #expect(card.newDateISO == "2026-08-01")
    }

    // MARK: Clamping

    @Test func clampsDaysMinutesAndPauseDays() {
        var card = CoachCardPayload(kind: .changeDays, label: "More days")
        card.daysPerWeek = 12
        #expect(CoachIntentBridge.validate(card, snapshot: snapshot()) == .changeDays(daysPerWeek: 7, preferredDays: nil))

        var minutes = CoachCardPayload(kind: .changeSessionLength, label: "Short sessions")
        minutes.sessionMinutes = 5
        #expect(CoachIntentBridge.validate(minutes, snapshot: snapshot()) == .changeSessionLength(minutes: 20))

        var pause = CoachCardPayload(kind: .pausePlan, label: "Pause")
        pause.pauseDays = 90
        #expect(CoachIntentBridge.validate(pause, snapshot: snapshot()) == .pausePlan(days: 28))
    }

    @Test func filtersAndDedupesPreferredDays() {
        var card = CoachCardPayload(kind: .changeDays, label: "Weekends")
        card.preferredDays = [7, 1, 7, 0, 9]
        #expect(CoachIntentBridge.validate(card, snapshot: snapshot()) == .changeDays(daysPerWeek: nil, preferredDays: [1, 7]))
    }

    // MARK: Rejection — never guess

    @Test func rejectsUnknownEnumStrings() {
        var goal = CoachCardPayload(kind: .changeGoal, label: "New goal")
        goal.goal = "winOlympics"
        #expect(CoachIntentBridge.validate(goal, snapshot: snapshot()) == nil)

        var equipment = CoachCardPayload(kind: .changeEquipment, label: "Gym")
        equipment.equipment = "spaceStation"
        #expect(CoachIntentBridge.validate(equipment, snapshot: snapshot()) == nil)

        var nav = CoachCardPayload(kind: .nav, label: "Go")
        nav.nav = "settingsButActuallyNot"
        #expect(CoachIntentBridge.validate(nav, snapshot: snapshot()) == nil)
    }

    @Test func changeRaceResolvesANamedCatalogRace() {
        // The LLM (or offline responder) names a race; the bridge resolves its exact distance + date
        // from the catalog — the LLM never has to know a race's calendar.
        var chicago = CoachCardPayload(kind: .changeRace, label: "Point at Chicago")
        chicago.raceName = "the Chicago Marathon"
        guard case let .changeRace(distanceM, date, goalTime)? =
                CoachIntentBridge.validate(chicago, snapshot: snapshot()) else {
            Issue.record("named race did not resolve"); return
        }
        #expect(distanceM == RaceDistance.marathon.meters)
        #expect(date > today)
        #expect(goalTime == nil)

        // A named sub-distance resolves to that distance — "NYC half" → the half, not a marathon.
        var half = CoachCardPayload(kind: .changeRace, label: "NYC half")
        half.raceName = "I want to run the NYC half"
        if case let .changeRace(d, _, _)? = CoachIntentBridge.validate(half, snapshot: snapshot()) {
            #expect(d == RaceDistance.half.meters)
        } else { Issue.record("NYC half did not resolve") }

        // Names no real race → nil, so the coach asks instead of inventing one.
        var vague = CoachCardPayload(kind: .changeRace, label: "some race")
        vague.raceName = "a marathon someday"
        #expect(CoachIntentBridge.validate(vague, snapshot: snapshot()) == nil)

        // The explicit distance+date fallback still validates (a custom race not in the catalog).
        var custom = CoachCardPayload(kind: .changeRace, label: "Local 10K")
        custom.raceDistanceM = 10_000
        custom.raceDateISO = iso(day(90))
        #expect(CoachIntentBridge.validate(custom, snapshot: snapshot())
                == .changeRace(distanceM: 10_000, date: day(90), goalFinishTimeS: nil))
    }

    @Test func rejectsSessionIdNotInSnapshot() {
        var card = CoachCardPayload(kind: .moveSession, label: "Move it")
        card.sessionId = UUID().uuidString          // never sent to the model
        card.newDateISO = iso(day(3))
        let known = (UUID(), day(1))
        #expect(CoachIntentBridge.validate(card, snapshot: snapshot(upcoming: [known])) == nil)
    }

    @Test func rejectsMoveToSameDayAndPastDay() {
        let id = UUID()
        let sessionDay = day(2)
        var same = CoachCardPayload(kind: .moveSession, label: "Move")
        same.sessionId = id.uuidString
        same.newDateISO = iso(sessionDay)
        let snap = snapshot(upcoming: [(id, sessionDay)])
        #expect(CoachIntentBridge.validate(same, snapshot: snap) == nil)

        var past = same
        past.newDateISO = iso(day(-2))
        #expect(CoachIntentBridge.validate(past, snapshot: snap) == nil)
    }

    @Test func rejectsRaceBeyondHorizonOrInPast() {
        var far = CoachCardPayload(kind: .changeRace, label: "Marathon")
        far.raceDistanceM = 42_195
        far.raceDateISO = iso(cal.date(byAdding: .month, value: 24, to: today)!)
        #expect(CoachIntentBridge.validate(far, snapshot: snapshot()) == nil)

        var past = far
        past.raceDateISO = iso(day(-30))
        #expect(CoachIntentBridge.validate(past, snapshot: snapshot()) == nil)

        var silly = far
        silly.raceDateISO = iso(day(60))
        silly.raceDistanceM = 500                    // below the 1 km floor
        #expect(CoachIntentBridge.validate(silly, snapshot: snapshot()) == nil)
    }

    @Test func nonsenseGoalTimeIsDroppedButRaceKept() {
        var card = CoachCardPayload(kind: .changeRace, label: "10K")
        card.raceDistanceM = 10_000
        card.raceDateISO = iso(day(70))
        card.goalFinishTimeS = 10                    // 10-second 10K — dropped, race kept
        let intent = CoachIntentBridge.validate(card, snapshot: snapshot())
        #expect(intent == .changeRace(distanceM: 10_000, date: day(70), goalFinishTimeS: nil))
    }

    @Test func rejectsMalformedDates() {
        var card = CoachCardPayload(kind: .changeRace, label: "Race")
        card.raceDistanceM = 5_000
        card.raceDateISO = "next Tuesday"
        #expect(CoachIntentBridge.validate(card, snapshot: snapshot()) == nil)
    }

    @Test func pauseResumeRespectPausedState() {
        let pause = CoachCardPayload(kind: .pausePlan, label: "Pause")
        #expect(CoachIntentBridge.validate(pause, snapshot: snapshot(isPaused: true)) == nil)

        let resume = CoachCardPayload(kind: .resumePlan, label: "Resume")
        #expect(CoachIntentBridge.validate(resume, snapshot: snapshot()) == nil)
        #expect(CoachIntentBridge.validate(resume, snapshot: snapshot(isPaused: true)) == .resumePlan)
    }

    @Test func injuryReportRequiresBothAreaAndSeverity() {
        var card = CoachCardPayload(kind: .injuryReport, label: "Adjust my plan")
        card.injuryArea = InjuryArea.shins.rawValue
        #expect(CoachIntentBridge.validate(card, snapshot: snapshot()) == nil)   // picker not answered yet
        card.injurySeverity = InjurySeverity.moderate.rawValue
        #expect(CoachIntentBridge.validate(card, snapshot: snapshot()) == .injuryReport(area: .shins, severity: .moderate))
    }

    @Test func changeDaysNeedsAtLeastOneParameter() {
        let empty = CoachCardPayload(kind: .changeDays, label: "Change days")
        #expect(CoachIntentBridge.validate(empty, snapshot: snapshot()) == nil)
    }

    @Test func validMoveResolves() {
        let id = UUID()
        var card = CoachCardPayload(kind: .moveSession, label: "Move it")
        card.sessionId = id.uuidString
        card.newDateISO = iso(day(4))
        let intent = CoachIntentBridge.validate(card, snapshot: snapshot(upcoming: [(id, day(2))]))
        #expect(intent == .moveSession(id: id, to: day(4)))
    }
}
