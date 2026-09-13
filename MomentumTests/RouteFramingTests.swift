import Testing
import Foundation
import CoreLocation
import UIKit
@testable import Momentum

/// `RouteFraming` lays a route image rendered for one canvas over another so the route does not
/// move when the live map fades in (2026-09-13). These pin the geometry.
struct RouteFramingTests {

    /// A ~1 km square loop in Austin.
    private var loop: [CLLocationCoordinate2D] {
        let lat0 = 30.27, lon0 = -97.74, dLat = 0.009, dLon = 0.0104
        return [
            .init(latitude: lat0, longitude: lon0), .init(latitude: lat0 + dLat, longitude: lon0),
            .init(latitude: lat0 + dLat, longitude: lon0 + dLon), .init(latitude: lat0, longitude: lon0 + dLon),
            .init(latitude: lat0, longitude: lon0),
        ]
    }

    private let card = CGSize(width: 660, height: 880)
    private let cardInsets = UIEdgeInsets(top: 180, left: 90, bottom: 180, right: 90)
    private let page = CGSize(width: 402, height: 874)
    private let pageInsets = UIEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)

    /// Where a coordinate lands under a fit — the camera's own projection.
    private func project(_ c: CLLocationCoordinate2D, _ fit: RouteFraming.Fit) -> CGPoint {
        let m = RouteFraming.mercator(c)
        return CGPoint(x: fit.anchor.x + (m.x - fit.center.x) * fit.scale,
                       y: fit.anchor.y + (m.y - fit.center.y) * fit.scale)
    }

    @Test func fitCentresTheBoxInsideThePaddedCanvas() throws {
        let fit = try #require(RouteFraming.fit(loop, in: card, insets: cardInsets))
        let pts = loop.map { project($0, fit) }
        let minX = try #require(pts.map(\.x).min()), maxX = try #require(pts.map(\.x).max())
        let minY = try #require(pts.map(\.y).min()), maxY = try #require(pts.map(\.y).max())
        // Inside the padded rect (90…570 × 180…700), touching the constraining axis, centred.
        #expect(minX >= 89.9 && maxX <= 570.1)
        #expect(minY >= 179.9 && maxY <= 700.1)
        #expect(abs((minX + maxX) / 2 - 330) < 0.01)
        #expect(abs((minY + maxY) / 2 - 440) < 0.01)
        #expect(abs((maxX - minX) - 480) < 0.01 || abs((maxY - minY) - 520) < 0.01)
    }

    @Test func placementPutsEveryRoutePointWhereTheTargetCameraDrawsIt() throws {
        let source = try #require(RouteFraming.fit(loop, in: card, insets: cardInsets))
        let target = try #require(RouteFraming.fit(loop, in: page, insets: pageInsets, maxZoom: 17))
        let place = RouteFraming.placement(imageSize: card, source: source, target: target)
        let k = place.size.width / card.width
        let origin = CGPoint(x: place.center.x - place.size.width / 2, y: place.center.y - place.size.height / 2)
        for c in loop {
            let onCard = project(c, source)
            let viaImage = CGPoint(x: origin.x + onCard.x * k, y: origin.y + onCard.y * k)
            let onPage = project(c, target)
            #expect(abs(viaImage.x - onPage.x) < 0.01, "x drift for \(c)")
            #expect(abs(viaImage.y - onPage.y) < 0.01, "y drift for \(c)")
        }
    }

    @Test func identicalFramesAreTheIdentity() throws {
        let fit = try #require(RouteFraming.fit(loop, in: page, insets: pageInsets))
        let place = RouteFraming.placement(imageSize: page, source: fit, target: fit)
        #expect(abs(place.size.width - page.width) < 0.001)
        #expect(abs(place.size.height - page.height) < 0.001)
        #expect(abs(place.center.x - page.width / 2) < 0.001)
        #expect(abs(place.center.y - page.height / 2) < 0.001)
    }

    @Test func aClippedSourceStillLandsOnTheFullTarget() throws {
        // The card was framed to the route minus its ends; the live map frames the whole route.
        let full = loop + [CLLocationCoordinate2D(latitude: 30.27, longitude: -97.7425)]
        let clipped = Array(loop.dropLast())
        let source = try #require(RouteFraming.fit(clipped, in: card, insets: cardInsets))
        let target = try #require(RouteFraming.fit(full, in: page, insets: pageInsets, maxZoom: 17))
        let place = RouteFraming.placement(imageSize: card, source: source, target: target)
        let k = place.size.width / card.width
        let origin = CGPoint(x: place.center.x - place.size.width / 2, y: place.center.y - place.size.height / 2)
        for c in clipped {
            let onCard = project(c, source)
            let viaImage = CGPoint(x: origin.x + onCard.x * k, y: origin.y + onCard.y * k)
            let onPage = project(c, target)
            #expect(abs(viaImage.x - onPage.x) < 0.01)
            #expect(abs(viaImage.y - onPage.y) < 0.01)
        }
    }

    @Test func loopAssumptionMatchesTheExactPlacementForALoop() throws {
        let source = try #require(RouteFraming.fit(loop, in: card, insets: cardInsets))
        let target = try #require(RouteFraming.fit(loop, in: page, insets: pageInsets, maxZoom: 17))
        let exact = RouteFraming.placement(imageSize: card, source: source, target: target)
        let assumed = RouteFraming.assumedPlacement(imageSize: card, imageInsets: cardInsets,
                                                    canvas: page, canvasInsets: pageInsets)
        // A wide-as-tall loop is width-constrained on both canvases: the guess is the answer.
        #expect(abs(exact.size.width - assumed.size.width) < 0.5)
        #expect(abs(exact.center.x - assumed.center.x) < 0.5)
        #expect(abs(exact.center.y - assumed.center.y) < 0.5)
        // And the page shows the route at the live map's size: 346pt wide, not the card's 480.
        #expect(abs(assumed.size.width / card.width * 480 - 346) < 0.5)
    }

    @Test func tinyRoutesRespectTheLiveMapZoomClamp() throws {
        let tiny = [CLLocationCoordinate2D(latitude: 30.27, longitude: -97.74),
                    CLLocationCoordinate2D(latitude: 30.2703, longitude: -97.7403)]
        let clamped = try #require(RouteFraming.fit(tiny, in: page, insets: pageInsets, maxZoom: 17))
        let free = try #require(RouteFraming.fit(tiny, in: page, insets: pageInsets))
        #expect(clamped.scale < free.scale)
        #expect(abs(clamped.scale - 512 * pow(2, 17)) < 1)
    }
}
