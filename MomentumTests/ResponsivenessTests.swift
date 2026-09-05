import Foundation
import Testing
@testable import Momentum

@Suite("Responsiveness regressions")
@MainActor
struct ResponsivenessTests {
    @Test func firstMapMountStartsExactlyOneFlight() {
        var transition = MapGlobeTransition()
        let ticket = transition.enter(mapReady: false)
        #expect(transition.phase == .waitingForMap)
        #expect(transition.mapReady() == ticket)
        #expect(transition.mapReady() == nil)
        #expect(transition.entered(ticket) == true)
        #expect(transition.entered(ticket) == false)
    }

    @Test func exitingBeforeMapLoadsCannotStartTheOldEntry() {
        var transition = MapGlobeTransition()
        let entry = transition.enter(mapReady: false)
        let exit = transition.exit()
        #expect(transition.mapReady() == nil)
        #expect(transition.entered(entry) == false)
        #expect(transition.exited(exit) == true)
    }

    @Test func rapidRoundTripsRejectOldExitEvenWhenModeMatchesAgain() {
        var transition = MapGlobeTransition()
        let firstEntry = transition.enter(mapReady: true)
        let firstExit = transition.exit()
        let secondEntry = transition.enter(mapReady: true)
        let secondExit = transition.exit()
        #expect(transition.entered(firstEntry) == false)
        #expect(transition.exited(firstExit) == false)
        #expect(transition.entered(secondEntry) == false)
        #expect(transition.phase == .exiting)
        #expect(transition.exited(secondExit) == true)
        #expect(transition.phase == .home)
    }

    @Test func tabDepartureInvalidatesCallbacksInEitherMode() {
        for inWorld in [true, false] {
            var transition = MapGlobeTransition()
            let entry = transition.enter(mapReady: true)
            let exit = transition.exit()
            transition.settle(inWorld: inWorld)
            #expect(transition.entered(entry) == false)
            #expect(transition.exited(exit) == false)
            #expect(transition.phase == (inWorld ? .world : .home))
        }
    }

    @Test func immediateReducedMotionRoundTripNeedsNoCallback() {
        var transition = MapGlobeTransition()
        let entry = transition.enter(mapReady: true)
        #expect(transition.entered(entry) == true)
        let exit = transition.exit()
        #expect(transition.exited(exit) == true)
        #expect(transition.mapReady() == nil)
    }

    @Test func estimateReplacementOwnsResultAndSpinnerCleanup() {
        let meal = UUID()
        let old = EstimateGate.take(meal)
        let current = EstimateGate.take(meal)
        defer { EstimateGate.end(meal, token: current) }
        #expect(!EstimateGate.owns(meal, token: old))
        #expect(EstimateGate.owns(meal, token: current))
        EstimateGate.end(meal, token: old)
        #expect(EstimateGate.owns(meal, token: current))
        EstimateGate.end(meal, token: current)
        #expect(!EstimateGate.owns(meal, token: current))
        #expect(!EstimateGate.isEstimating(meal))
    }

    @Test func independentMealsNeverShareOwnership() {
        let first = UUID(), second = UUID()
        let a = EstimateGate.take(first), b = EstimateGate.take(second)
        defer { EstimateGate.end(first, token: a); EstimateGate.end(second, token: b) }
        #expect(!EstimateGate.owns(first, token: b))
        #expect(!EstimateGate.owns(second, token: a))
    }

    @Test func loadBandsStayExactlyTheSameAtBoundaries() {
        let samples: [(Double, ProgressInsights.Status, ProgressInsights.Recommendation)] = [
            (0.79, .underloaded, .increase), (0.8, .building, .hold),
            (1.29, .building, .hold), (1.3, .pushing, .hold),
            (1.49, .pushing, .hold), (1.5, .overreaching, .ease),
            (1.79, .overreaching, .ease), (1.8, .overreaching, .rest)
        ]
        for (ratio, status, recommendation) in samples {
            let result = ProgressInsights.loadVerdict(chronic: 100, acwr: ratio)
            #expect(result.status == status)
            #expect(result.recommendation == recommendation)
        }
        #expect(ProgressInsights.loadVerdict(chronic: 0.99, acwr: 4).recommendation == .start)
    }

    @Test func singlePassLoadMathMatchesOriginalIncludingDSTAndWindowEdges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 12))!
        let acuteCut = calendar.date(byAdding: .day, value: -7, to: now)!
        let chronicCut = calendar.date(byAdding: .day, value: -28, to: now)!
        let sessions = (-2...400).map { offset in
            (date: calendar.date(byAdding: .day, value: -offset, to: now)!, load: Double((offset + 5) % 7) * 120)
        }
        let acute = sessions.filter { $0.date >= acuteCut }.reduce(0) { $0 + $1.load }
        let total = sessions.filter { $0.date >= chronicCut }.reduce(0) { $0 + $1.load }
        let historyDays = calendar.dateComponents([.day], from: sessions.map(\.date).min()!, to: now).day!
        let chronic = total / min(4, max(1, Double(historyDays) / 7))
        let result = ProgressInsights.acuteChronic(sessions: sessions, now: now, calendar: calendar)
        #expect(result.acute == acute)
        #expect(result.chronic == chronic)
        #expect(result.acwr == acute / chronic)
    }

    @Test func lightweightRecommendationMatchesDashboardForMixedHistory() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        for count in [0, 1, 7, 40, 200] {
            let workouts = (0..<count).map { index in
                let workout = Workout()
                workout.startedAt = now.addingTimeInterval(-Double(index) * 86_400)
                workout.type = index.isMultiple(of: 3) ? .strength : .run
                workout.durationS = index.isMultiple(of: 4) ? 0 : 1800
                workout.perceivedEffort = index % 9 + 1
                let gps = GPSDetail(); gps.distanceM = 5000; workout.gps = gps
                return workout
            }
            #expect(ProgressInsights.loadRecommendation(workouts: workouts, now: now)
                    == ProgressInsights(workouts: workouts, now: now).recommendation)
        }
    }

    @Test func tenThousandWorkoutHistoryUsesLoadOnlyPath() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let workouts = (0..<10_000).map { index in
            let workout = Workout()
            workout.startedAt = now.addingTimeInterval(-Double(index) * 86_400)
            workout.durationS = 1800
            workout.type = .run
            return workout
        }
        let clock = ContinuousClock()
        var recommendation: ProgressInsights.Recommendation = .start
        let elapsed = clock.measure {
            recommendation = ProgressInsights.loadRecommendation(workouts: workouts, now: now)
        }
        #expect(recommendation == .hold)
        // Diagnostic, not a device-independent timing assertion. This never constructs charts.
        print("Plan load-only evaluation, 10,000 workouts: \(elapsed)")
    }
}
