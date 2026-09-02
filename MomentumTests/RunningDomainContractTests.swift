import Foundation
import Testing
@testable import Momentum

struct RunningDomainContractTests {
    @Test func healthSignalsCanNeverRepresentCompletedTrainingExposure() {
        #expect(!RunningEvidenceSource.healthSignal.canRepresentCompletedTrainingExposure)
        #expect(RunningEvidenceSource.momentumWorkout.canRepresentCompletedTrainingExposure)
        #expect(RunningEvidenceSource.fieldTest.canRepresentCompletedTrainingExposure)
    }

    @Test func evidenceReportsBadProvenanceInsteadOfSilentlyNormalizingIt() {
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        let evidence = RunningEvidence(
            value: 42.0,
            source: .athleteEntry,
            observedAt: now.addingTimeInterval(-3_600),
            window: DateInterval(start: now, duration: 1_800),
            sampleCount: 0,
            confidence: .high,
            limitations: [.selfReported]
        )

        #expect(evidence.sampleCount == 0)
        #expect(evidence.validationIssues == [
            .nonPositiveSampleCount,
            .observationPrecedesWindow,
            .highConfidenceHasKnownLimitations,
        ])
    }

    @Test func evidenceRoundTripsWithoutRawSensorPayload() throws {
        let now = Date(timeIntervalSinceReferenceDate: 200_000)
        let evidence = RunningEvidence(
            value: RunningEasyEffortTrend(
                direction: .stable,
                paceSPerKm: RunningValueRange(lower: 330, upper: 345),
                heartRateBPM: RunningValueRange(lower: 138, upper: 145),
                perceivedEffort: RunningValueRange(lower: 3, upper: 4),
                comparableSessionCount: 4
            ),
            source: .derived,
            observedAt: now,
            window: DateInterval(start: now.addingTimeInterval(-14 * 86_400), end: now),
            sampleCount: 4,
            confidence: .moderate,
            limitations: [.missingEnvironment]
        )
        let data = try JSONEncoder().encode(evidence)
        let decoded = try JSONDecoder().decode(
            RunningEvidence<RunningEasyEffortTrend>.self,
            from: data
        )

        #expect(decoded == evidence)
        let payload = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["gpspoint", "route", "healthsample", "medicalnote"] {
            #expect(!payload.contains(forbidden))
        }
    }

    @Test func unknownAthleteStateStaysUnknown() {
        let state = RunningAthleteState.unknown
        #expect(state.evidenceSummaries.isEmpty)
        #expect(state.currentFrequency == nil)
        #expect(state.performanceCurve == nil)
        #expect(state.environment == nil)
    }

    @Test func athleteEvidenceSummaryOrderIsStable() {
        let at = Date(timeIntervalSinceReferenceDate: 300_000)
        let state = RunningAthleteState(
            currentFrequency: RunningEvidence(
                value: 4, source: .derived, observedAt: at,
                sampleCount: 4, confidence: .moderate
            ),
            toleranceBySessionClass: [
                .long: RunningEvidence(
                    value: RunningToleranceObservation(
                        band: .developing,
                        completedExposureCount: 3,
                        typicalRecoveryS: RunningValueRange(lower: 86_400, upper: 129_600)
                    ),
                    source: .momentumWorkout,
                    observedAt: at,
                    sampleCount: 3,
                    confidence: .low,
                    limitations: [.smallSample]
                ),
                .easy: RunningEvidence(
                    value: RunningToleranceObservation(
                        band: .established,
                        completedExposureCount: 12,
                        typicalRecoveryS: RunningValueRange(lower: 43_200, upper: 86_400)
                    ),
                    source: .momentumWorkout,
                    observedAt: at,
                    sampleCount: 12,
                    confidence: .moderate
                ),
            ]
        )

        #expect(state.evidenceSummaries.map(\.dimension) == [
            "currentFrequency", "tolerance.easy", "tolerance.long",
        ])
    }

    @Test func seasonKeepsItsAthleteNameAndRejectsTwoPrimaryEvents() {
        let firstID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let later = Date(timeIntervalSinceReferenceDate: 500_000)
        let earlier = later.addingTimeInterval(-86_400)
        let season = RunningSeason(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!,
            name: "  Chicago Marathon  ",
            status: .active,
            primaryOutcome: .targetTime,
            motivations: [.performance],
            events: [
                RunningSeasonEvent(id: firstID, name: "Later", date: later,
                                   distanceM: 42_195, priority: .a),
                RunningSeasonEvent(id: secondID, name: "Earlier", date: earlier,
                                   distanceM: 21_097.5, priority: .a),
            ]
        )

        #expect(season.name == "Chicago Marathon")
        #expect(season.events.map(\.id) == [secondID, firstID])
        #expect(season.validationIssues.map(\.code).contains(.multiplePrimaryEvents))
    }

    @Test func undatedFinishTimeGoalIsValidWithoutInventingAnEvent() {
        let season = RunningSeason(
            id: UUID(),
            name: "Sub-20 5K",
            status: .active,
            primaryOutcome: .targetTime,
            events: []
        )
        #expect(season.validationIssues.isEmpty)
    }

    @Test func calendarConfigurationPreservesNonGregorianLocalDayRules() throws {
        var original = Calendar(identifier: .buddhist)
        original.locale = Locale(identifier: "th_TH")
        original.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        original.firstWeekday = 2
        original.minimumDaysInFirstWeek = 4
        let restored = try RunningCalendarConfiguration(original).value()

        #expect(restored.identifier == original.identifier)
        #expect(restored.locale?.identifier == original.locale?.identifier)
        #expect(restored.timeZone.identifier == original.timeZone.identifier)
        #expect(restored.firstWeekday == 2)
        #expect(restored.minimumDaysInFirstWeek == 4)
    }

    @Test func targetHierarchyDeduplicatesAndNeverUsesPrimaryAsFallback() {
        let hierarchy = RunningTargetHierarchy(
            primary: .distance,
            fallbacks: [.pace, .distance, .pace, .effort]
        )
        #expect(hierarchy.fallbacks == [.pace, .effort])
    }
}

