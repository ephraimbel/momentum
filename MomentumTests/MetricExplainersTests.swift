import Testing
@testable import Momentum

/// The "how we calculate" catalog behind every chart's ⓘ. Guards that each entry is complete and
/// that ids are unique (they key the sheet + any future lookup).
struct MetricExplainersTests {

    @Test func everyExplainerIsComplete() {
        for e in MetricExplainers.all {
            #expect(!e.id.isEmpty)
            #expect(!e.title.isEmpty)
            #expect(!e.tagline.isEmpty)
            #expect(!e.sections.isEmpty, "\(e.id) has no sections")
            for s in e.sections {
                #expect(!s.heading.isEmpty, "\(e.id) section heading empty")
                #expect(s.body.count > 20, "\(e.id) section '\(s.heading)' too thin")
            }
        }
    }

    @Test func idsAreUnique() {
        let ids = MetricExplainers.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func coversTheProAnalyticsCards() {
        // The metrics surfaced by ProTrendsSection + StrengthProgressSection must each have an entry.
        let required = ["fitnessFreshness", "cadence", "climb", "efficiency",
                        "liftProgression", "trainingVolume", "muscleBalance"]
        let ids = Set(MetricExplainers.all.map(\.id))
        for r in required { #expect(ids.contains(r), "missing explainer: \(r)") }
    }
}
