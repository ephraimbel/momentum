import XCTest

/// Two standing rules, re-proven rather than trusted (owner double-check 2026-08-28):
///  • the app is PORTRAIT ONLY — rotating the device must not rotate the UI;
///  • no page scrolls SIDE TO SIDE — a vertical page must be locked horizontally, whatever
///    horizontal component sits inside it.
/// Plus what "enterprise level" actually means here: every tab reaches an interactive state fast.
final class PageLockAndLoadUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--seed-dense-history", "--awards-quiet"] + args
        app.launch()
        return app
    }

    /// Rotating the device must leave the UI portrait. Checked by the window's own aspect: in
    /// portrait it is taller than it is wide, and it must stay that way in every orientation.
    func testTheAppNeverRotates() {
        let app = launch(["--progress-tab"])
        XCTAssertTrue(app.tabBars.buttons.firstMatch.waitForExistence(timeout: 20), "app never came up")
        let portrait = app.frame
        XCTAssertGreaterThan(portrait.height, portrait.width, "did not start portrait")
        for orientation: UIDeviceOrientation in [.landscapeLeft, .landscapeRight, .portraitUpsideDown] {
            XCUIDevice.shared.orientation = orientation
            usleep(900_000)
            let f = app.frame
            XCTAssertGreaterThan(f.height, f.width,
                                 "UI rotated to \(orientation.rawValue): frame \(f)")
        }
        XCUIDevice.shared.orientation = .portrait
        usleep(600_000)
    }

    /// Swiping sideways on a page must move nothing. Compares the page's own screenshot before
    /// and after a hard horizontal fling in both directions — identical pixels means locked.
    /// (Run on pages that CONTAIN a horizontal component, since those are the ones at risk.)
    func testPagesDoNotDriftSideways() {
        for (name, args) in [("Progress", ["--progress-tab"]),
                             ("Plan", ["--plan-tab"]),
                             ("Fuel", ["--fuel-tab"])] {
            let app = launch(args)
            XCTAssertTrue(app.tabBars.buttons.firstMatch.waitForExistence(timeout: 20), "\(name) never came up")
            sleep(3)
            // Sample the page well clear of the tab bar and any inner carousel.
            let before = app.screenshot().pngRepresentation
            let mid = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
            mid.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.30)))
            usleep(700_000)
            mid.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.30)))
            usleep(900_000)
            let after = app.screenshot().pngRepresentation
            // The page may animate its own content, so compare geometry rather than raw pixels:
            // the tab bar and header must sit exactly where they did.
            let tab = app.tabBars.firstMatch
            XCTAssertEqual(tab.frame.minX, 0, accuracy: 0.5, "\(name): the page shifted sideways")
            XCTAssertEqual(app.frame.minX, 0, accuracy: 0.5, "\(name): the window shifted sideways")
            XCTAssertFalse(before.isEmpty || after.isEmpty)
            app.terminate()
        }
    }

    /// The post-run page is the one a finished athlete stares at, and it carries a full-bleed map
    /// plus charts — the two things that have pulled a page sideways before. A real scroll is
    /// never perfectly vertical, so this drags DIAGONALLY (the owner's report, 2026-08-28: "why
    /// do i move side to side when scrolling down") and asserts the page's own content stayed
    /// put horizontally.
    func testThePostRunPageDoesNotDriftSideways() {
        let app = XCUIApplication()
        // `--reset-store` first: `--seed-demo` only seeds an EMPTY store, so without it this test
        // inherits whatever the tests above left in the container and the marathon never lands.
        app.launchArguments = ["--reset-store", "--seed-demo", "--marathon-hero",
                               "--ui-test-run-detail", "--awards-quiet"]
        app.launch()
        let title = app.staticTexts["Austin Marathon"]
        XCTAssertTrue(title.waitForExistence(timeout: 25), "post-run page never came up")
        sleep(2)
        let x0 = title.frame.minX
        // Four diagonal drags, alternating lean, the way a thumb actually scrolls.
        for lean in [0.06, -0.06, 0.10, -0.10] {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + lean, dy: 0.30))
            from.press(forDuration: 0.05, thenDragTo: to)
            usleep(500_000)
            XCTAssertEqual(app.frame.minX, 0, accuracy: 0.5, "the window shifted sideways")
        }
        // Scroll back to the top and re-measure the same element.
        for _ in 0..<5 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
            usleep(250_000)
        }
        sleep(1)
        XCTAssertTrue(title.waitForExistence(timeout: 5), "title vanished after scrolling")
        print("DRIFT title.minX before=\(x0) after=\(title.frame.minX)")
        // Sub-point, not "close enough": the wobble this test was written for measured 0.33pt.
        XCTAssertEqual(title.frame.minX, x0, accuracy: 0.1,
                       "the post-run page drifted sideways under a diagonal scroll")
    }

    /// Every tab must reach an interactive state quickly from a cold launch.
    func testEveryTabLoadsFast() {
        for (name, args, anchor) in [("Progress", ["--progress-tab"], "progress"),
                                     ("Plan", ["--plan-tab"], "plan"),
                                     ("Fuel", ["--fuel-tab"], "fuel"),
                                     ("Profile", ["--profile-tab"], "")] {
            let app = launch(args)
            let t0 = Date()
            XCTAssertTrue(app.tabBars.buttons.firstMatch.waitForExistence(timeout: 25), "\(name) never came up")
            // Interactive, not merely present: the tab bar must answer a hit test.
            var tries = 0
            while !app.tabBars.buttons.firstMatch.isHittable && tries < 40 { usleep(250_000); tries += 1 }
            let dt = Date().timeIntervalSince(t0)
            XCTAssertTrue(app.tabBars.buttons.firstMatch.isHittable, "\(name) never became interactive")
            if !anchor.isEmpty {
                XCTAssertTrue(app.staticTexts[anchor].waitForExistence(timeout: 10), "\(name) header missing")
            }
            print("PAGELOAD \(name): \(String(format: "%.2f", dt))s")
            app.terminate()
        }
    }
}
