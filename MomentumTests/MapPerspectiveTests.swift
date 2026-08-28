import Testing
import Foundation
@testable import Momentum

/// The 2D/3D map toggle (owner ask 2026-08-28): no choice keeps each style's own tilt — so
/// shipping the button changes nothing for anyone who never taps it — and an explicit choice
/// overrides every style, in both directions.
struct MapPerspectiveTests {
    @Test func noChoiceKeepsEachStylesOwnTilt() {
        for style in MapStyleOption.allCases {
            #expect(style.explorePitch(nil) == style.explorePitch)
        }
        #expect(MapStyleOption.realistic.explorePitch(nil) == 0)          // the default look, untouched
        #expect(MapStyleOption.standardSatellite.explorePitch(nil) == 55)
    }

    @Test func flatFlattensEveryStyle() {
        for style in MapStyleOption.allCases { #expect(style.explorePitch(.flat) == 0) }
    }

    @Test func tiltedTiltsEveryStyleAndNeverReducesADeeperOwnTilt() {
        for style in MapStyleOption.allCases {
            #expect(style.explorePitch(.tilted) >= MapPerspective.tiltedPitch)
        }
        #expect(MapStyleOption.realistic.explorePitch(.tilted) == 45)
        #expect(MapStyleOption.standardSatellite.explorePitch(.tilted) == 55)   // 3D is never LESS 3D
    }

    @Test func theRunIsFlatUnlessTheAthleteChose3D() {
        // A style's own tilt never applies on the run (the 2D behaviour every run had before);
        // only an explicit 3D choice tilts the follow camera.
        #expect((MapPerspective(rawValue: "")?.pitch ?? 0) == 0)
        #expect(MapPerspective.flat.pitch == 0)
        #expect(MapPerspective.tilted.pitch == MapPerspective.tiltedPitch)
    }

    @Test func rawValuesRoundTripThroughAppStorage() {
        for p in MapPerspective.allCases { #expect(MapPerspective(rawValue: p.rawValue) == p) }
        #expect(MapPerspective(rawValue: "") == nil)   // "never chosen" stays nil, never a default
    }
}
