import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Tier-1 coach features: the memory layer (remember/forget via chat) and the deterministic
/// week-recap and race-plan cards.
@MainActor
struct CoachMemoryAndCardsTests {

    func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private let cal = Calendar.current
    private var today: Date { cal.startOfDay(for: Date()) }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    // MARK: rememberNote — validation

    @Test func rememberNoteValidatesAndClamps() {
        let snap = CoachIntentBridge.Snapshot(today: today)
        var card = CoachCardPayload(kind: .rememberNote, label: "Remember this")
        card.note = "  I prefer morning runs \n before work  "
        card.noteCategory = "habit"
        let intent = CoachIntentBridge.validate(card, snapshot: snap)
        guard case .rememberNote(let text, let category)? = intent else {
            Issue.record("expected rememberNote, got \(String(describing: intent))"); return
        }
        #expect(!text.contains("\n"))
        #expect(category == .habit)

        var empty = CoachCardPayload(kind: .rememberNote, label: "Remember this")
        empty.note = "  "
        #expect(CoachIntentBridge.validate(empty, snapshot: snap) == nil)

        var unknownCategory = card
        unknownCategory.noteCategory = "starSign"
        guard case .rememberNote(_, let fallback)? = CoachIntentBridge.validate(unknownCategory, snapshot: snap) else {
            Issue.record("unknown category should fall back, not reject"); return
        }
        #expect(fallback == .preference)

        var long = CoachCardPayload(kind: .rememberNote, label: "Remember this")
        long.note = String(repeating: "a", count: 500)
        guard case .rememberNote(let clamped, _)? = CoachIntentBridge.validate(long, snapshot: snap) else {
            Issue.record("long note should clamp, not reject"); return
        }
        #expect(clamped.count == 160)
    }

    // MARK: rememberNote — apply (append-only, deduped, capped)

    @Test func rememberNoteAppendsPinnedNoteAndDedupes() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = UserProfile()
        ctx.insert(profile)
        try? ctx.save()

        let first = CoachActions.apply(.rememberNote(text: "I hate treadmills", category: .preference),
                                       profile: profile, workouts: [], today: today, in: ctx)
        guard case .applied = first else { Issue.record("expected applied, got \(first)"); return }
        let second = CoachActions.apply(.rememberNote(text: "I prefer mornings", category: .habit),
                                        profile: profile, workouts: [], today: today, in: ctx)
        guard case .applied = second else { Issue.record("expected applied, got \(second)"); return }

        // Append-only: both facts survive (per-category corrections would have replaced).
        let active = profile.athlete?.notes.filter { $0.isActive } ?? []
        let allPinned = active.allSatisfy { $0.pinned }
        let allUserSourced = active.allSatisfy { $0.source == MemorySource.user.rawValue }
        #expect(active.count == 2)
        #expect(allPinned)
        #expect(allUserSourced)

        // Identical fact (case-insensitive) declines instead of duplicating.
        let dupe = CoachActions.apply(.rememberNote(text: "i hate TREADMILLS", category: .preference),
                                      profile: profile, workouts: [], today: today, in: ctx)
        guard case .declined = dupe else { Issue.record("expected declined dupe, got \(dupe)"); return }
        let stillActive = profile.athlete?.notes.filter { $0.isActive }.count
        #expect(stillActive == 2)
    }

    @Test func rememberNoteRefusesMedicalContent() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = UserProfile()
        ctx.insert(profile)

        let outcome = CoachActions.apply(.rememberNote(text: "my knee injury needs medication", category: .risk),
                                         profile: profile, workouts: [], today: today, in: ctx)
        guard case .declined = outcome else { Issue.record("medical notes must decline, got \(outcome)"); return }
        #expect((profile.athlete?.notes.isEmpty) != false)
    }

    @Test func rememberNoteCapsAtTwelveActive() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = UserProfile()
        ctx.insert(profile)
        for i in 0..<12 {
            CoachActions.apply(.rememberNote(text: "fact number \(i)", category: .preference),
                               profile: profile, workouts: [], today: today, in: ctx)
        }
        let thirteenth = CoachActions.apply(.rememberNote(text: "one fact too many", category: .preference),
                                            profile: profile, workouts: [], today: today, in: ctx)
        guard case .declined(let reason) = thirteenth else { Issue.record("expected declined, got \(thirteenth)"); return }
        #expect(reason.contains("full"))
    }

    // MARK: Week recap

    @Test func weekRecapSpeaksFromTheLog() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = UserProfile()
        let plan = TrainingPlan()
        ctx.insert(profile)
        ctx.insert(plan)
        profile.plan = plan

        guard let week = cal.dateInterval(of: .weekOfYear, for: today) else { return }
        // Two planned sessions already elapsed this week: one done, one open.
        let done = PlannedSession(); done.date = week.start; done.discipline = .running; done.status = .completed
        let open = PlannedSession(); open.date = today; open.discipline = .running; open.status = .planned
        // One next week, a long run.
        let next = PlannedSession(); next.date = cal.date(byAdding: .day, value: 8, to: week.start)!
        next.discipline = .running; next.runType = .long; next.targetDistanceM = 16_000
        [done, open, next].forEach { ctx.insert($0) }
        plan.sessions = [done, open, next]

        // Distance this week and last week (for the trend line).
        func run(_ date: Date, km: Double) -> Workout {
            let w = Workout(); w.type = .run; w.startedAt = date; w.durationS = km * 360
            let g = GPSDetail(); g.distanceM = km * 1000; w.gps = g
            ctx.insert(w); return w
        }
        let workouts = [run(week.start, km: 10),
                        run(cal.date(byAdding: .day, value: -3, to: week.start)!, km: 8)]
        try? ctx.save()

        let sections = CoachWeekRecap.sections(profile: profile, workouts: workouts, events: [], today: today)
        let all = sections.map { "\($0.title): \($0.detail)" }.joined(separator: " | ")
        #expect(all.contains("1 of 2"))                      // adherence so far
        #expect(all.contains("up 25%"))                      // 10 km vs 8 km
        #expect(all.contains("long run"))                    // next week preview
    }

    // MARK: Race plan

    @Test func racePlanDerivesFromCalibratedFitness() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let profile = UserProfile()
        let plan = TrainingPlan()
        plan.p5kSPerKm = 300                                  // 25:00 5K
        ctx.insert(profile)
        ctx.insert(plan)
        profile.plan = plan
        profile.raceDate = day(28)
        profile.raceDistanceM = 10_000
        profile.goalFinishTimeS = 3_000                       // 50:00 goal
        try? ctx.save()

        let sections = CoachRacePlan.sections(profile: profile, today: today)
        #expect(sections.count == 5)
        let verdict = sections[0].detail
        #expect(verdict.contains("10K pace"))
        #expect(verdict.contains("50:00"))                    // the goal is named
        #expect(sections.map(\.title).contains("Fueling"))

        // No race → nothing to plan (never invents).
        let raceless = UserProfile()
        ctx.insert(raceless)
        #expect(CoachRacePlan.sections(profile: raceless, today: today).isEmpty)
    }
}
