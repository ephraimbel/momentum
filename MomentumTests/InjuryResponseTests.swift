import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The injury loop: report → deterministic, bounded, no-shame plan response → gated return.
@MainActor
struct InjuryResponseTests {

    /// A runner profile with a real generated plan (quality + easy + long runs to respond to).
    private func makeRunner(_ ctx: ModelContext) -> UserProfile {
        let vm = OnboardingViewModel()
        vm.activities = [.run]
        vm.goal = .raceDistance
        vm.raceDistance = .tenK
        vm.hasRace = true
        vm.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 10, to: Date())!
        vm.experience = .some
        vm.weeklyRunVolumeM = 30_000
        return vm.finish(in: ctx)
    }

    @Test func twingeKeepsRunningButDropsQuality() throws {
        let pc = PersistenceController.inMemory(); let ctx = pc.container.mainContext
        let profile = makeRunner(ctx)
        let plan = try #require(profile.plan)
        let cal = Calendar.current
        let windowEnd = cal.date(byAdding: .day, value: InjurySeverity.twinge.windowDays, to: cal.startOfDay(for: Date()))!

        let outcome = InjuryResponse.report(area: .shins, severity: .twinge, profile: profile, in: ctx)
        #expect(outcome.sessionsChanged > 0)
        #expect(profile.activeInjuryArea == "shins")
        #expect(profile.injuryHistory.contains("shins"))          // remembered for future plans

        // Window: still RUNNING (no cross-train), but nothing hard remains.
        let window = plan.sessions.filter { $0.date <= windowEnd && $0.status == .planned }
        for s in window where s.discipline == .running {
            if let rt = s.runType { #expect(!rt.isQuality && rt != .long) }
        }
        // Beyond the window the plan is untouched — bounded, not a rewrite.
        let beyond = plan.sessions.filter { $0.date > windowEnd }
        #expect(beyond.contains { $0.runType?.isQuality == true || $0.runType == .long })
    }

    @Test func moderateSwapsImpactForCrossTrainingAndSevereMakesItOptional() throws {
        let pc = PersistenceController.inMemory(); let ctx = pc.container.mainContext
        let profile = makeRunner(ctx)
        let plan = try #require(profile.plan)
        let cal = Calendar.current

        let outcome = InjuryResponse.report(area: .knee, severity: .severe, profile: profile, in: ctx)
        #expect(outcome.sessionsChanged > 0)
        #expect(outcome.guidance.localizedCaseInsensitiveContains("professional"))   // red flags out loud

        let windowEnd = try #require(profile.activeInjuryUntil)
        let window = plan.sessions.filter {
            $0.status == .planned && $0.date <= windowEnd
            && cal.startOfDay(for: $0.date) >= cal.startOfDay(for: Date())
        }
        #expect(!window.isEmpty)
        for s in window {
            #expect(s.discipline == .cycling)                     // no impact left in the window
            #expect(s.rationale?.contains("pain-free") == true)   // explicitly optional
            #expect(s.targetDurationS != nil)
        }
        // Injury events land in the adaptation history + inbox.
        let events = (try? ctx.fetch(FetchDescriptor<CoachingEvent>())) ?? []
        #expect(events.contains { $0.headline.localizedCaseInsensitiveContains("knee") })
    }

    @Test func resumeRestoresAGentleReturnNotQualityWork() throws {
        let pc = PersistenceController.inMemory(); let ctx = pc.container.mainContext
        let profile = makeRunner(ctx)
        let plan = try #require(profile.plan)

        InjuryResponse.report(area: .calf, severity: .moderate, profile: profile, in: ctx)
        let outcome = InjuryResponse.resume(profile: profile, in: ctx)

        #expect(profile.activeInjuryArea == nil)                  // state cleared
        #expect(outcome.sessionsChanged > 0)
        let restored = plan.sessions
            .filter { $0.discipline == .running && $0.rationale?.contains("back") == true
                      || $0.rationale?.contains("rebuild") == true }
            .sorted { $0.date < $1.date }
        #expect(!restored.isEmpty)
        // The first run back is a short recovery jog; nothing restored is quality.
        #expect(restored.first?.runType == .recovery)
        #expect((restored.first?.targetDistanceM ?? 0) <= 3_000)
        #expect(restored.allSatisfy { !($0.runType?.isQuality ?? false) })
        // No cross-train conversions remain in the future.
        #expect(!plan.sessions.contains { $0.status == .planned && $0.rationale?.hasPrefix(InjuryResponse.marker) == true })
    }

    @Test func firstWeekBackHoldsNoQualityAnywhere() throws {
        // Re-injury risk peaks right after resume — even sessions the injury window never touched
        // must hold no quality for 7 days.
        let pc = PersistenceController.inMemory(); let ctx = pc.container.mainContext
        let profile = makeRunner(ctx)
        let plan = try #require(profile.plan)
        let cal = Calendar.current

        InjuryResponse.report(area: .achilles, severity: .twinge, profile: profile, in: ctx)   // 5-day window
        // Plant an eager interval session on day 6 — past the window, inside the return gate.
        let eager = try #require(plan.sessions.filter {
            $0.discipline == .running && $0.status == .planned
            && $0.date > cal.date(byAdding: .day, value: 5, to: Date())!
        }.min { $0.date < $1.date })
        eager.date = cal.date(byAdding: .day, value: 6, to: cal.startOfDay(for: Date()))!
        eager.runType = .intervals

        InjuryResponse.resume(profile: profile, in: ctx)
        #expect(eager.runType == .easy)                            // gated
        #expect(eager.rationale?.contains("First week back") == true)

        // Quality beyond the 7-day gate survives — the gate is bounded too.
        let farOut = plan.sessions.filter { $0.date > cal.date(byAdding: .day, value: 8, to: Date())! }
        #expect(farOut.contains { $0.runType?.isQuality == true || $0.runType == .long })
    }
}
