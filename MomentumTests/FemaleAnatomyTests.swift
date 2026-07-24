import Testing
import SwiftUI
@testable import Momentum

/// The female anatomical dataset (ported from react-native-body-highlighter, same MIT source as
/// the male) must parse into non-empty figures whose slugs map to the same muscle groups — so the
/// figure a female athlete sees is complete and lit correctly, not a set of empty paths.
@Suite("FemaleAnatomy")
struct FemaleAnatomyTests {

    @Test func femaleLightsTheSameMusclesAsMale() {
        // The invariant that matters: the female figure resolves to the SAME set of lightable
        // muscle groups as the male, front and back — so any workout lights identically on either
        // figure. (Structural-only slugs like head/ankles that map to no muscle may differ
        // harmlessly; the female back omits a couple the male back already renders faint or skips.)
        #expect(Set(BodyAnatomy.front.compactMap(\.muscle)) == Set(BodyAnatomy.femaleFront.compactMap(\.muscle)))
        #expect(Set(BodyAnatomy.back.compactMap(\.muscle)) == Set(BodyAnatomy.femaleBack.compactMap(\.muscle)))
    }

    @Test func everyFemaleSlugCarriesPathData() {
        let empty = (MuscleBodyData.femaleFront + MuscleBodyData.femaleBack)
            .filter { $0.paths.isEmpty || $0.paths.contains(where: \.isEmpty) }
            .map(\.slug)
        #expect(empty.isEmpty, "slugs with no path data: \(empty)")
    }

    @Test func femaleFiguresParseIntoRealPaths() {
        // The parsed anatomy must produce non-empty bounding boxes — a garbled parse (bad arc
        // handling, dropped commands) collapses paths to nothing.
        for part in BodyAnatomy.femaleFront {
            #expect(!part.path.isEmpty)
        }
        for part in BodyAnatomy.femaleBack {
            #expect(!part.path.isEmpty)
        }
        #expect(!BodyAnatomy.femaleFrontOutline.isEmpty)
        #expect(!BodyAnatomy.femaleBackOutline.isEmpty)
    }

    @Test func femaleMuscleRegionsLightUp() {
        // The lit regions must resolve to real MuscleGroups (nil = structural/faint only). If the
        // mapping missed, a worked muscle wouldn't glow on the female figure.
        let lit = BodyAnatomy.femaleFront.compactMap(\.muscle)
        #expect(lit.contains(.chest))
        #expect(lit.contains(.quads))
        #expect(lit.contains(.biceps))
        let litBack = BodyAnatomy.femaleBack.compactMap(\.muscle)
        #expect(litBack.contains(.glutes))
        #expect(litBack.contains(.hamstrings))
        #expect(litBack.contains(.back))
    }

    @Test func viewBoxesAreDistinctPerSexAndSide() {
        // The female art lives in its own coordinate space — a wrong box distorts or clips it.
        #expect(BodyAnatomy.viewBox(.front, .female) == BodyAnatomy.ViewBox(minX: -50, minY: -40, width: 734, height: 1538))
        #expect(BodyAnatomy.viewBox(.back, .female) == BodyAnatomy.ViewBox(minX: 756, minY: 0, width: 774, height: 1448))
        #expect(BodyAnatomy.viewBox(.front, .neutral) == BodyAnatomy.ViewBox(minX: 0, minY: 0, width: 724, height: 1448))
        #expect(BodyAnatomy.viewBox(.back, .neutral) == BodyAnatomy.ViewBox(minX: 724, minY: 0, width: 724, height: 1448))
    }

    @Test func profileSexMapsToFigure() {
        #expect(BodySex(profileSex: "female") == .female)
        #expect(BodySex(profileSex: "male") == .neutral)
        #expect(BodySex(profileSex: "other") == .neutral)
        #expect(BodySex(profileSex: nil) == .neutral)
    }
}
