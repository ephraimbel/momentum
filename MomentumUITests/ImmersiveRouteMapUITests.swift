import XCTest

/// Pins the immersive route map's explore → re-center loop: the map is explorable by pinch /
/// double-tap only (single-finger drags belong to the vertical pager), the re-center control
/// appears in the trailing column only once the athlete has explored, and tapping it re-fits the
/// whole route (which hides the control again).
final class ImmersiveRouteMapUITests: XCTestCase {

    @MainActor
    func testRecenterAppearsOnExploreAndRefitsOnTap() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--profile-tab", "--profile-open-run"]
        app.launch()

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 12), "immersive pager did not open")
        sleep(3)   // let the map settle at the fitted overview

        let recenter = app.buttons["Re-center route"]
        XCTAssertFalse(recenter.exists, "re-center must be hidden before exploring")

        // Double-tap the route map to zoom in (the explore gesture).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).doubleTap()
        XCTAssertTrue(recenter.waitForExistence(timeout: 6),
                      "re-center did not appear after exploring — \(app.debugDescription)")
        print("[probe] recenter frame \(recenter.frame) hittable \(recenter.isHittable)")

        recenter.tap()
        // Re-fitting flips isExplored back off, which removes the button.
        let gone = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: gone, object: recenter)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 6), .completed,
                       "re-center still present after tap — camera did not re-fit")
    }
}
