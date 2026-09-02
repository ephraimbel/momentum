import Testing
@testable import Momentum

struct TrainingLoadContextTests {
    @Test func operationalBandsStayStableWithoutCallingThemSafe() {
        #expect(TrainingLoadContext.band(ratio: 0, hasBaseline: false) == .learning)
        #expect(TrainingLoadContext.band(ratio: .nan) == .learning)
        #expect(TrainingLoadContext.band(ratio: 0.79) == .lighterThanRecent)
        #expect(TrainingLoadContext.band(ratio: 0.8) == .nearRecentNorm)
        #expect(TrainingLoadContext.band(ratio: 1.29) == .nearRecentNorm)
        #expect(TrainingLoadContext.band(ratio: 1.3) == .aboveRecentNorm)
        #expect(TrainingLoadContext.band(ratio: 1.5) == .muchAboveRecentNorm)

        for band in TrainingLoadContext.Band.allCases {
            let label = band.displayName.lowercased()
            #expect(!label.contains("sweet spot"))
            #expect(!label.contains("safe"))
            #expect(!label.contains("injury"))
        }
    }

    @Test func explanationStatesTheScientificBoundary() {
        let copy = TrainingLoadContext.methodExplanation.lowercased()
        #expect(copy.contains("cannot predict injury"))
        #expect(copy.contains("how the work felt"))
        #expect(!copy.contains("injury risk"))
        #expect(!copy.contains("danger zone"))
        #expect(!copy.contains("sweet spot"))
    }

    @Test func aLightWeekIsContextNotAutomaticPermissionToAdd() {
        let copy = TrainingLoadContext.summary(ratio: 0.6).lowercased()
        #expect(copy.contains("lighter than your recent pattern"))
        #expect(!copy.contains("detraining"))
        #expect(!copy.contains("room to add"))
        #expect(!copy.contains("push harder"))
    }

    @Test func sparseHistoryDoesNotManufactureAConclusion() {
        let copy = TrainingLoadContext.summary(ratio: 1.8, hasBaseline: false)
        #expect(copy.contains("baseline is still taking shape"))
        #expect(!copy.contains("1.80"))
    }
}
