import XCTest

/// Visual capture of the world globe — confirms the realistic satellite Earth renders and the fly-out
/// settles. Uses the `--world` deep link (deterministic; avoids the flaky location-alert tap nav), and
/// attaches screenshots for eyeball review of the look.
final class GlobeLookUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testGlobeLooksRealistic() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--world"]
        app.launch()

        let header = app.staticTexts["Around the world"]
        XCTAssertTrue(header.waitForExistence(timeout: 15), "Globe view didn't open.")

        sleep(4)   // let the fly-out settle on the globe
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "globe-settled"
        shot.lifetime = .keepAlways
        add(shot)

        // The honest community header + legend are present over the globe.
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'Momentum community'")).firstMatch.exists,
            "Community count not shown over the globe.")
        XCTAssertTrue(app.staticTexts["Community"].exists, "Globe legend missing.")
    }
}
