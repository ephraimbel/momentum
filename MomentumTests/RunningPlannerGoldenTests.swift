import Foundation
import Testing
@testable import Momentum

struct RunningPlannerGoldenTests {
    @Test func goldenCorpusHasBalancedReleaseOneCoverage() {
        let personas = RunningPlannerTestFixtures.goldenPersonas
        #expect(personas.count == 32)
        #expect(Set(personas.map(\.id)).count == personas.count)
        for family in RunningPlannerTestFixtures.Family.allCases {
            #expect(personas.filter { $0.family == family }.count == 8, "Missing eight-persona coverage for \(family.rawValue)")
        }
    }

    @Test func currentPlannerMatchesTheReviewedSemanticBaseline() throws {
        for persona in RunningPlannerTestFixtures.goldenPersonas {
            let evaluation = try LegacyPlanShadowEvaluator.evaluate(
                inputs: persona.inputs,
                catalog: RunningPlannerTestFixtures.catalog,
                calibration: persona.calibration,
                startDate: RunningPlannerTestFixtures.startDate,
                calendar: RunningPlannerTestFixtures.calendar
            )

            if !evaluation.validation.isValid {
                let details = evaluation.validation.hardViolations.map {
                    "\($0.code.rawValue)@w\($0.location.weekIndex.map(String.init) ?? "-")d\($0.location.dayOffset.map(String.init) ?? "-")"
                }.joined(separator: ",")
                Issue.record("\(persona.id) violates the evaluator: \(details)")
            }
            if evaluation.digest.value != persona.expectedDigest {
                Issue.record("BASELINE \(persona.id)=\(evaluation.digest.value)")
            }

            let repeated = try LegacyPlanShadowEvaluator.evaluate(
                inputs: persona.inputs,
                catalog: RunningPlannerTestFixtures.catalog,
                calibration: persona.calibration,
                startDate: RunningPlannerTestFixtures.startDate,
                calendar: RunningPlannerTestFixtures.calendar
            )
            #expect(repeated.digest == evaluation.digest, "Non-deterministic digest for \(persona.id)")
        }
    }
}
