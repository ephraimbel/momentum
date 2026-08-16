import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Fixture tests for the deterministic Tier-A distillation (`docs/ATHLETE-MODEL.md` §4).
/// All times are relative to a fixed `now` so results are deterministic.
@MainActor
struct AthleteModelEngineTests {

    let cal = Calendar.current
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 12))! }

    func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func day(_ daysAgo: Int, hour: Int = 7) -> Date {
        let d = cal.date(byAdding: .day, value: -daysAgo, to: now)!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: d)!
    }

    @discardableResult
    private func run(_ ctx: ModelContext, daysAgo: Int, minutes: Double = 30,
                     paceSPerKm: Double? = nil, effort: Int? = nil, hour: Int = 7) -> Workout {
        let w = Workout(); w.type = .run; w.startedAt = day(daysAgo, hour: hour)
        w.durationS = minutes * 60; w.perceivedEffort = effort
        let gps = GPSDetail(); gps.distanceM = 5000
        if let p = paceSPerKm { gps.avgPaceSPerKm = p }
        w.gps = gps
        ctx.insert(w)
        return w
    }

    @discardableResult
    private func strength(_ ctx: ModelContext, daysAgo: Int, exercise: Exercise,
                          weightKg: Double, reps: Int = 5, minutes: Double = 45) -> Workout {
        let w = Workout(); w.type = .strength; w.startedAt = day(daysAgo); w.durationS = minutes * 60
        let s = StrengthSession()
        s.totalVolumeKg = weightKg * Double(reps)
        s.totalSets = 1
        let row = WorkoutExercise(); row.exercise = exercise
        let set = SetEntry(); set.weightKg = weightKg; set.reps = reps; set.isComplete = true; set.type = .working
        row.sets = [set]; s.exercises = [row]; w.strength = s
        ctx.insert(w)
        return w
    }

    // MARK: - Tests

    @Test func emptyHistoryIsDefault() {
        let f = AthleteModelEngine(workouts: [], plan: nil, now: now, calendar: cal).facts
        #expect(f == AthleteFacts())
        #expect(f.medianSessionMinutes == 0)
        #expect(f.currentACWR == 0)
    }

    @Test func morningRhythmAndSessionLength() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let ws = (0..<8).map { run(ctx, daysAgo: $0 * 3 + 1, minutes: 45, hour: 7) }
        try ctx.save()
        let f = AthleteModelEngine(workouts: ws, plan: nil, now: now, calendar: cal).facts
        #expect(f.trainingHourHistogram[7] == 8)
        #expect(f.preferredSessionMinutes == 45)
        #expect(AthleteModelEngine.confidence(.rhythm, count: f.signalSampleCounts["rhythm"] ?? 0) == .confident)
    }

    @Test func disciplineMixReflectsHistory() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let bench = Exercise(name: "Bench", primaryMuscles: [.chest], equipment: .barbell, category: .compound)
        ctx.insert(bench)
        var ws: [Workout] = (0..<6).map { run(ctx, daysAgo: $0 * 5 + 2) }
        ws += (0..<4).map { strength(ctx, daysAgo: $0 * 5 + 4, exercise: bench, weightKg: 80) }
        try ctx.save()
        let f = AthleteModelEngine(workouts: ws, plan: nil, now: now, calendar: cal).facts
        #expect(abs((f.disciplineShare["run"] ?? 0) - 0.6) < 0.001)
        #expect(abs((f.disciplineShare["strength"] ?? 0) - 0.4) < 0.001)
    }

    @Test func easyPaceImprovingIsNegativeTrend() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        // Oldest→newest: pace falls (gets faster) at the same easy effort.
        let specs: [(Int, Double)] = [(50, 360), (40, 360), (30, 355), (20, 335), (10, 330), (5, 325)]
        let ws = specs.map { run(ctx, daysAgo: $0.0, paceSPerKm: $0.1, effort: 3) }
        try ctx.save()
        let f = AthleteModelEngine(workouts: ws, plan: nil, now: now, calendar: cal).facts
        #expect(f.paceAtEffortTrendPct < 0)
        #expect(AthleteModelEngine.confidence(.paceAtEffort, count: f.signalSampleCounts["paceAtEffort"] ?? 0) == .confident)
    }

    @Test func strengthE1RMTrendsUp() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let bench = Exercise(name: "Bench", primaryMuscles: [.chest], equipment: .barbell, category: .compound)
        ctx.insert(bench)
        let specs: [(Int, Double)] = [(40, 80), (30, 82), (20, 85), (10, 90)]
        let ws = specs.map { strength(ctx, daysAgo: $0.0, exercise: bench, weightKg: $0.1) }
        try ctx.save()
        let f = AthleteModelEngine(workouts: ws, plan: nil, now: now, calendar: cal).facts
        #expect((f.e1rmTrendByExercise["Bench"] ?? 0) > 0)
    }

    @Test func fadingFrequencyIsNegative() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        var ws = (0..<5).map { run(ctx, daysAgo: 30 + $0 * 4) }   // prior 28d window: busy
        ws += (0..<2).map { run(ctx, daysAgo: 3 + $0 * 5) }       // last 28d: quiet
        try ctx.save()
        let f = AthleteModelEngine(workouts: ws, plan: nil, now: now, calendar: cal).facts
        #expect(f.frequencyTrend28d < 0)
    }

    @Test func planAdherenceAndConsecutiveMissed() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let plan = TrainingPlan()
        func session(_ daysAgo: Int, _ status: SessionStatus) -> PlannedSession {
            let s = PlannedSession(); s.date = day(daysAgo); s.status = status; return s
        }
        plan.sessions = [
            session(2, .missed), session(5, .missed), session(9, .completed),
            session(14, .completed), session(20, .moved),
        ]
        ctx.insert(plan); try ctx.save()
        let f = AthleteModelEngine(workouts: [run(ctx, daysAgo: 9)], plan: plan, now: now, calendar: cal).facts
        #expect(abs(f.planAdherence28d - 0.5) < 0.001)        // 2 completed / (2 completed + 2 missed)
        #expect(abs(f.movedSessionRate28d - 0.2) < 0.001)     // 1 moved / 5 total
        #expect(f.consecutiveMissed == 2)
    }

    // MARK: - Pure helpers

    @Test func confidenceThresholds() {
        #expect(AthleteModelEngine.confidence(.rhythm, count: 3) == .emerging)
        #expect(AthleteModelEngine.confidence(.rhythm, count: 5) == .growing)
        #expect(AthleteModelEngine.confidence(.rhythm, count: 8) == .confident)
    }

    @Test func avoidWeekdaysNeedRealEvidence() {
        var missed = Array(repeating: 0, count: 7)
        var completed = Array(repeating: 0, count: 7)
        // Tuesday (index 2): 4 slips vs 1 completion → 80% slip rate on ≥3 slips → avoid.
        missed[2] = 4; completed[2] = 1
        // Thursday (index 4): 2 slips — under the ≥3 evidence bar, however bad the ratio.
        missed[4] = 2; completed[4] = 0
        // Saturday (index 6): 3 slips vs 5 completions → 37% — a day they usually make.
        missed[6] = 3; completed[6] = 5
        #expect(AthleteModelEngine.avoidWeekdays(missed: missed, completed: completed) == [2])
        // Malformed histograms never avoid anything.
        #expect(AthleteModelEngine.avoidWeekdays(missed: [], completed: completed).isEmpty)
        #expect(AthleteModelEngine.avoidWeekdays(missed: missed, completed: Array(repeating: 0, count: 3)).isEmpty)
    }

    @Test func numericHelpers() {
        #expect(AthleteModelEngine.median([3, 1, 2]) == 2)
        #expect(AthleteModelEngine.median([4, 1, 2, 3]) == 2.5)
        #expect(AthleteModelEngine.modeBinned([44, 46, 45, 30], bin: 15) == 45)
        #expect(AthleteModelEngine.halfSplitTrendPct([100, 100, 90, 90]) == -10)
        #expect(AthleteModelEngine.pctChange(current: 110, prior: 100) == 10)
        #expect(AthleteModelEngine.pctChange(current: 5, prior: 0) == 100)
        #expect(AthleteModelEngine.monthKey(now, calendar: cal) == "2026-06")
    }
}
