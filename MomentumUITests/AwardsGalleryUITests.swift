import XCTest

/// Pins the awards-gallery back button: popping must STICK. The `--awards-gallery` auto-push once
/// re-armed itself on every profile onAppear, so pressing back bounced the athlete straight back
/// into the gallery 0.8s later (user report 2026-07-22).
final class AwardsGalleryUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    func testBackFromAwardsGalleryStaysOnProfile() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--profile-tab", "--profile-highlights", "--awards-gallery"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]; if b.exists { b.tap(); return true }
            }
            return false
        }
        app.launch()

        // The gallery auto-pushes shortly after the profile appears; its lowercase "awards"
        // masthead and Back chevron mark it.
        let masthead = app.staticTexts["awards"]
        XCTAssertTrue(masthead.waitForExistence(timeout: 12), "awards gallery never opened")
        let back = app.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 3))

        back.tap()

        // The pop must outlive the old 0.8s re-arm window — still on the profile 2.5s later.
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertFalse(masthead.exists, "back button bounced into the awards gallery again")
        // The shelf itself can be below the fold on shorter devices. The selected Highlights
        // control is the stable proof that the navigation pop returned to the intended profile
        // face; asserting an off-screen child made this regression test depend on viewport size.
        let highlights = app.buttons["Highlights"]
        XCTAssertTrue(highlights.waitForExistence(timeout: 3),
                      "profile Highlights face not visible after popping the gallery")
        XCTAssertTrue(highlights.isSelected,
                      "profile did not return to the selected Highlights face")
    }
}
