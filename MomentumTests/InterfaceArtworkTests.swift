import Testing
import UIKit
@testable import Momentum

/// Check the compiled asset catalog, including Unicode country names and both appearances.
/// A source PNG existing on disk does not prove UIKit can find and decode the shipped resource.
@MainActor
struct InterfaceArtworkTests {
    @Test func everyCatalogCountryHasLoadableArtwork() throws {
        for name in Set(RaceCatalog.races.map(\.flagArtworkName)) {
            try verifyArtwork(name)
        }
    }

    @Test func bothAnimatedPaywallIllustrationsHaveLoadableArtwork() throws {
        try verifyArtwork("PaywallRaceFlag")
        try verifyArtwork("PaywallFuelApple")
    }

    @Test func welcomeHasFullResolutionOpeningAndClosingStills() throws {
        for name in ["WelcomePoster", "WelcomeClosingPoster"] {
            try verifyArtwork(name)
            let image = try #require(UIImage(named: name))
            let bitmap = try #require(image.cgImage)
            #expect(bitmap.width >= 720 && bitmap.height > bitmap.width)
        }
    }

    private func verifyArtwork(_ name: String) throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let image = try #require(UIImage(named: name, in: .main,
                                            compatibleWith: UITraitCollection(userInterfaceStyle: style)),
                                     "Missing interface artwork: \(name)")
            let bitmap = try #require(image.cgImage, "Could not decode artwork: \(name)")
            #expect(bitmap.width >= 60 && bitmap.height >= 60, "Artwork too small: \(name)")
            #expect(image.renderingMode != .alwaysTemplate, "Artwork lost its original colors: \(name)")
        }
    }
}
