import Foundation
import Testing
@testable import Momentum

struct RunningPlannerAdversarialTests {
    private static let qualificationSeed: UInt64 = 0x4D4F_4D45_4E54_554D

    @Test func requestGeneratorIsExactlyReplayable() throws {
        let first = LegacyAdversarialPlanRequestGenerator.make(
            seed: Self.qualificationSeed,
            index: 9_731,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar
        )
        let second = LegacyAdversarialPlanRequestGenerator.make(
            seed: Self.qualificationSeed,
            index: 9_731,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar
        )

        let firstReplay = LegacyPlanReplay(
            inputs: first.inputs,
            catalog: RunningPlannerTestFixtures.catalog,
            calibration: first.calibration,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar
        )
        let secondReplay = LegacyPlanReplay(
            inputs: second.inputs,
            catalog: RunningPlannerTestFixtures.catalog,
            calibration: second.calibration,
            startDate: RunningPlannerTestFixtures.startDate,
            calendar: RunningPlannerTestFixtures.calendar
        )
        #expect(try firstReplay.canonicalData() == secondReplay.canonicalData())
    }

    @Test func tenThousandSupportedRequestsPassTheLegacyInvariantGate() throws {
        var failures: [String] = []
        var failureCounts: [PlanValidationCode: Int] = [:]
        failures.reserveCapacity(20)

        for index in 0..<10_000 {
            let request = LegacyAdversarialPlanRequestGenerator.make(
                seed: Self.qualificationSeed,
                index: index,
                startDate: RunningPlannerTestFixtures.startDate,
                calendar: RunningPlannerTestFixtures.calendar
            )
            let evaluation = try LegacyPlanShadowEvaluator.evaluate(
                inputs: request.inputs,
                catalog: RunningPlannerTestFixtures.catalog,
                calibration: request.calibration,
                startDate: RunningPlannerTestFixtures.startDate,
                calendar: RunningPlannerTestFixtures.calendar
            )

            if !evaluation.validation.isValid {
                for issue in evaluation.validation.hardViolations {
                    failureCounts[issue.code, default: 0] += 1
                }
                if failures.count < 20 {
                    let issues = evaluation.validation.hardViolations.map {
                        "\($0.code.rawValue)@w\($0.location.weekIndex.map(String.init) ?? "-")d\($0.location.dayOffset.map(String.init) ?? "-")"
                    }.joined(separator: ",")
                    failures.append(
                        "seed=\(request.seed) index=\(request.index) \(Self.summary(request.inputs)) "
                        + "issues=\(issues) context=\(Self.volumeContext(evaluation.candidate, evaluation.validation))"
                    )
                }
            }
            if evaluation.digest.value.count != 64, failures.count < 20 {
                failures.append("seed=\(request.seed) index=\(request.index) invalid digest")
            }
        }

        if !failures.isEmpty {
            let counts = failureCounts.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue)=\($0.value)" }
                .joined(separator: ",")
            let details = "counts[\(counts)] " + failures.joined(separator: " | ")
            Issue.record("Adversarial failures: \(details)")
        }
        #expect(failures.isEmpty)
    }

    private static func summary(_ inputs: PlanInputs) -> String {
        let runwayDays = inputs.raceDate.map {
            RunningPlannerTestFixtures.calendar.dateComponents(
                [.day],
                from: RunningPlannerTestFixtures.startDate,
                to: $0
            ).day ?? -1
        }
        return [
            "goal=\(inputs.goal.rawValue)",
            "race=\(inputs.raceDistanceM.map { String(format: "%.1f", $0) } ?? "nil")",
            "runwayDays=\(runwayDays.map(String.init) ?? "nil")",
            "days=\(inputs.daysPerWeek)",
            "disciplines=\(inputs.disciplines.map(\.rawValue).joined(separator: "+"))",
            "priority=\(inputs.hybridPriority?.rawValue ?? "nil")",
            "experience=\(inputs.runningExperience.rawValue)",
            "intensity=\(inputs.intensity.rawValue)",
            "age=\(inputs.age.map(String.init) ?? "nil")",
            "current=\(inputs.currentWeeklyVolumeM.map { String(Int($0)) } ?? "nil")",
            "target=\(inputs.targetWeeklyVolumeM.map { String(Int($0)) } ?? "nil")",
            "unit=\(inputs.distanceUnit.rawValue)",
            "preferred=\(inputs.preferredDayOffsets.map(String.init).joined(separator: ","))",
            "avoid=\(inputs.avoidDayOffsets.map(String.init).joined(separator: ","))",
            "injuries=\(inputs.injuryHistory.map(\.rawValue).joined(separator: ","))",
        ].joined(separator: " ")
    }

    private static func volumeContext(_ plan: GeneratedPlan,
                                      _ report: PlanValidationReport) -> String {
        let weekIndexes = Set(report.hardViolations.compactMap(\.location.weekIndex)).sorted()
        return weekIndexes.map { index in
            guard let position = plan.weeks.firstIndex(where: { $0.index == index }) else {
                return "w\(index){missing}"
            }
            let previousLoading = plan.weeks[..<position].last {
                !$0.isDeload && !$0.isTaper && $0.runVolumeM > 0
            }?.runVolumeM
            let week = plan.weeks[position]
            let distances = week.sessions.compactMap(\.targetDistanceM)
                .map { String(Int($0.rounded())) }.joined(separator: "+")
            return "w\(index){prev=\(previousLoading.map { String(Int($0.rounded())) } ?? "nil"),"
                + "current=\(Int(week.runVolumeM.rounded())),deload=\(week.isDeload),"
                + "taper=\(week.isTaper),distances=\(distances)}"
        }.joined(separator: ";")
    }
}
