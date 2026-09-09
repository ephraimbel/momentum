import Testing
@testable import Momentum

@MainActor
struct DeferredLaunchWorkTests {
    @Test func anActivityStartedBetweenLaunchStepsSurvivesDelayedCleanup() async {
        let work = DeferredLaunchWork()
        var ownership = LiveActivityOwnership()
        var ended: [String] = []
        var pauses = 0
        await work.run([
            .init(phase: .auth) {},
            .init(phase: .cardioActivities) {
                ended = ["previous-launch", "new-workout"].filter { ownership.isOrphan($0) }
            },
        ], pause: { _ in
            pauses += 1
            if pauses == 2 { ownership.record("new-workout") }
        })
        #expect(ended == ["previous-launch"])
    }

    @Test func runsOnceInOrderAndSuspendsBetweenSteps() async {
        let work = DeferredLaunchWork()
        var calls: [String] = []
        let steps: [DeferredLaunchWork.Step] = [
            .init(phase: .auth) { calls.append("auth") },
            .init(phase: .watch) { calls.append("watch") },
        ]
        await work.run(steps, pause: { _ in calls.append("pause") })
        #expect(calls == ["pause", "auth", "pause", "watch", "pause"])
        await work.run(steps, pause: { _ in calls.append("unexpected pause") })
        #expect(calls.count == 5)
        #expect(work.completed == [.auth, .watch])
    }

    @Test func cancellationDuringInitialDelayDoesNotStartSDKs() async {
        let work = DeferredLaunchWork()
        var called = false
        await work.run([.init(phase: .meta) { called = true }],
                       pause: { _ in throw CancellationError() })
        #expect(!called)
        #expect(work.completed.isEmpty)
    }

    @Test func interruptedWorkResumesWithoutRepeatingCompletedPhases() async {
        let work = DeferredLaunchWork()
        var calls: [DeferredLaunchWork.Phase] = []
        var pauses = 0
        let steps: [DeferredLaunchWork.Step] = [
            .init(phase: .auth) { calls.append(.auth) },
            .init(phase: .watch) { calls.append(.watch) },
        ]
        await work.run(steps, pause: { _ in
            pauses += 1
            if pauses == 2 { throw CancellationError() }
        })
        #expect(calls == [.auth])
        await work.run(steps, pause: { _ in })
        #expect(calls == [.auth, .watch])
    }

    @Test func aNewRunSupersedesAnOlderSuspendedRun() async {
        let work = DeferredLaunchWork()
        var oldPause: CheckedContinuation<Void, Never>?
        var calls = 0
        let steps: [DeferredLaunchWork.Step] = [.init(phase: .metrics) { calls += 1 }]
        let old = Task { @MainActor in
            await work.run(steps, pause: { _ in
                await withCheckedContinuation { oldPause = $0 }
            })
        }
        // Wait for the old invocation to reach its injected first suspension.
        while oldPause == nil { await Task.yield() }
        await work.run(steps, pause: { _ in })
        oldPause?.resume()
        await old.value
        #expect(calls == 1)
        #expect(work.completed == [.metrics])
    }

    @Test func diagnosticsBracketExactlyTheWorkThatRan() async {
        let work = DeferredLaunchWork()
        var events: [String] = []
        await work.run([.init(phase: .readiness) { events.append("work") }],
                       pause: { _ in }, observe: { phase, began in
            events.append("\(phase.rawValue):\(began)")
        })
        #expect(events == ["readiness:true", "work", "readiness:false"])
    }
}
