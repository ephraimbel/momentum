import Foundation
import Testing
@testable import Momentum

struct RunningRuleRegistryTests {
    @Test func compiledLegacyRoadRulesetIsCompleteAndUnique() {
        let registry = RunningRuleRegistry.legacyRoadV1
        #expect(registry.rulesetID == PlanningRequest.legacyRulesetID)
        #expect(registry.isComplete)
        #expect(registry.validationIssues.isEmpty)
        #expect(registry.definitions.count == RunningRuleID.allCases.count)
        #expect(Set(registry.definitions.map(\.id)).count == RunningRuleID.allCases.count)
        for id in RunningRuleID.allCases {
            #expect(registry[id] != nil, "Missing \(id.rawValue)")
        }
    }

    @Test func numericPlannerRulesRemainExplicitlyUnapprovedForExpertClaims() throws {
        let registry = RunningRuleRegistry.legacyRoadV1
        for id in [
            RunningRuleID.paceCalibration, .racePrediction, .weeklyVolumeProgression,
            .peakVolume, .longRunDose, .qualityDose, .deloadCadence,
            .taperShape, .returnProgression, .environmentAdjustment,
        ] {
            let rule = try #require(registry[id])
            #expect(rule.approvalState == .expertReviewRequired)
            #expect(rule.approvalDate == nil)
        }
    }

    @Test func buildGateFindsDuplicatesAndMissingRules() {
        let source = RunningRuleRegistry.legacyRoadV1
        let missing = source.definitions.filter { $0.id != .paceCalibration }
        let broken = RunningRuleRegistry(
            rulesetID: source.rulesetID,
            definitions: missing + [missing[0]]
        )
        let codes = Set(broken.validationIssues.map(\.code))
        #expect(codes.contains(.missingRequiredRule))
        #expect(codes.contains(.duplicateRuleID))
        #expect(!broken.isComplete)
    }

    @Test func buildGateRejectsInvalidBoundsMissingOwnersSourcesAndReview() throws {
        let source = try #require(RunningRuleRegistry.legacyRoadV1[.paceCalibration])
        let brokenRule = RunningRuleDefinition(
            id: source.id,
            version: 0,
            policies: source.policies,
            codeSymbol: "",
            purpose: source.purpose,
            supportedPopulation: source.supportedPopulation,
            inputUnits: [],
            outputUnits: [],
            bounds: [.init("reversed", unit: .seconds, lower: 10, upper: 1)],
            fallback: "",
            sourceType: source.sourceType,
            sourceReference: "",
            populationLimitations: source.populationLimitations,
            confidence: source.confidence,
            approvalState: .engineeringVerified,
            approvalDate: nil,
            ownerRoles: [],
            governanceReviewedAt: nil,
            nextReviewAt: nil,
            fixtureNames: [],
            copyDependencies: [],
            deprecated: true
        )
        let registry = RunningRuleRegistry(
            rulesetID: "broken",
            definitions: RunningRuleRegistry.legacyRoadV1.definitions
                .filter { $0.id != source.id } + [brokenRule]
        )
        let issues = Set(registry.validationIssues.filter { $0.ruleID == source.id }.map(\.code))
        for expected in [
            RunningRuleRegistryValidationCode.invalidVersion, .missingCodeSymbol, .missingUnits,
            .invalidBound, .missingFallback, .missingSource, .missingOwner,
            .missingGovernanceReview, .missingNextReview, .missingApprovalDate,
            .missingFixture, .inconsistentDeprecation,
        ] {
            #expect(issues.contains(expected), "Missing gate \(expected.rawValue)")
        }
    }

    @Test func releaseQualificationFailsWhenGovernanceReviewIsStale() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let beforeReviewExpiry = try #require(calendar.date(
            from: DateComponents(year: 2027, month: 2, day: 28)
        ))
        let afterReviewExpiry = try #require(calendar.date(
            from: DateComponents(year: 2027, month: 3, day: 2)
        ))
        let registry = RunningRuleRegistry.legacyRoadV1

        #expect(registry.validationIssues(asOf: beforeReviewExpiry).isEmpty)
        let stale = registry.validationIssues(asOf: afterReviewExpiry)
            .filter { $0.code == .staleReview }
        #expect(stale.count == RunningRuleID.allCases.count)
        #expect(Set(stale.compactMap(\.ruleID)) == Set(RunningRuleID.allCases))
    }

    @Test func traceRejectsARegisteredIDWhenSelectedRulesetOmitsIt() {
        let complete = RunningRuleRegistry.legacyRoadV1
        let incomplete = RunningRuleRegistry(
            rulesetID: complete.rulesetID,
            definitions: complete.definitions.filter { $0.id != .qualityDose }
        )
        let trace = RunningDecisionTrace(
            id: "trace",
            requestID: UUID(),
            status: .candidate,
            plannerVersion: "test",
            rulesetID: incomplete.rulesetID,
            policyID: .road5K10KV1,
            appliedRuleIDs: [.paceCalibration, .qualityDose],
            hardConstraints: [],
            relaxedPreferences: [],
            evidence: [],
            evidenceLimitations: [],
            legacyExceptions: [],
            validationCodes: [],
            headline: "",
            detail: ""
        )
        #expect(trace.unknownRuleIDs(in: incomplete) == [.qualityDose])
    }
}
