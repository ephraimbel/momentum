import Foundation

/// Nonessential startup work remains on its required actor, but yields between SDK calls.
/// A cancelled/backgrounded launch resumes at the next unfinished phase on foregrounding.
@MainActor
final class DeferredLaunchWork {
    enum Phase: String, CaseIterable, Sendable {
        case tikTok, meta, auth, metrics, quarantine, planBackfill, watch
        case cardioActivities, restActivities, anatomy, readiness
    }

    struct Step {
        let phase: Phase
        let perform: @MainActor () -> Void
    }

    private(set) var completed: Set<Phase> = []
    private var generation: UInt64 = 0

    /// Injecting the pause makes cancellation, resumption and overlapping callers testable
    /// without wall-clock sleeps. Only the newest invocation may advance the queue.
    func run(_ steps: [Step],
             pause: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
             observe: @MainActor (Phase, Bool) -> Void = { _, _ in }) async {
        generation &+= 1
        let current = generation
        guard steps.contains(where: { !completed.contains($0.phase) }) else { return }
        do {
            try await pause(.milliseconds(600))
            for step in steps {
                guard current == generation, !Task.isCancelled else { return }
                guard !completed.contains(step.phase) else { continue }
                observe(step.phase, true)
                step.perform()
                completed.insert(step.phase)
                observe(step.phase, false)
                // Unlike Task.yield(), a short suspension lets the main run loop commit a frame.
                try await pause(.milliseconds(20))
            }
        } catch {
            // Cancellation does not consume unfinished phases or execute deferred work early.
        }
    }
}
