import XCTest

/// Pins the save-flow celebration order (user call 2026-07-23): the save screen arrives QUIET —
/// no overlay between the athlete and their summary/editor — and the circle-and-check beat plays
/// after Done, closing the screen when it completes.
///
/// The beat itself is 0.86s of wall time — too fast for XCUIElement existence polling to observe
/// reliably — so the pins are the arrival state and the dismissal, with a raw frame burst (written
/// to the runner's tmp) for visual review of the draw.
final class CelebrationFlowUITests: XCTestCase {

    @MainActor
    func testBeatPlaysAfterSaveNotOnArrival() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--save-screen"]
        app.launch()

        let done = app.navigationBars.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 12), "save screen did not appear")
        sleep(3)   // reveal cascade settles
        XCTAssertFalse(app.buttons["Run complete"].exists,
                       "the celebration must not cover the save screen on arrival")

        done.tap()
        captureBurst("beat", seconds: 1.4)
        if done.exists {   // a first tap can be swallowed while the reveal is still settling
            done.tap()
            captureBurst("beat-retap", seconds: 1.4)
        }
        XCTAssertTrue(done.waitForNonExistence(timeout: 8),
                      "the beat should dismiss the save screen when it completes")
    }

    /// Rapid raw frames for visual review — ~6–10 over the window; paths print to the log.
    private func captureBurst(_ prefix: String, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        var i = 0
        while Date() < deadline {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(prefix)-\(i).png")
            try? png.write(to: url)
            print("[probe] wrote \(url.path)")
            i += 1
        }
    }
}
