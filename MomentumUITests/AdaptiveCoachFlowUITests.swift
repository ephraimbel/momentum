import XCTest

final class AdaptiveCoachFlowUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    private func launch(coaching: Bool = false, manualDismissal: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--awards-quiet", "--plan-tab", "--plan-locked-week"]
        if coaching { app.launchArguments.append("--coach-loop-demo") }
        if manualDismissal { app.launchArguments.append("--coach-dismiss-demo") }
        app.launch()
        return app
    }

    @MainActor
    func testFuturePreviewShowsTheRoadmapWithoutDetailedWorkouts() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["PREVIEW"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["Estimated weekly distance"].exists)
        XCTAssertTrue(app.staticTexts["Long-run estimate"].exists)
        XCTAssertFalse(app.staticTexts["This week"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Future week preview"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Roadmap to your goal"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "preview is not a guarantee")).firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testHighestPriorityToastOpensTheCurrentPlanAndDoesNotChainAnotherMessage() {
        let app = launch(coaching: true)
        let toast = app.descendants(matching: .any).matching(identifier: "app-toast").firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 25))
        XCTAssertEqual(toast.label, "Recovery check in ready")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Priority coaching toast"; shot.lifetime = .keepAlways; add(shot)
        toast.tap()
        XCTAssertTrue(app.staticTexts["This week"].waitForExistence(timeout: 5))
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: toast)
        wait(for: [gone], timeout: 5)
        let another = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: toast)
        another.isInverted = true
        wait(for: [another], timeout: 2)
    }

    @MainActor
    func testDismissingTheToastKeepsThePreviewOnScreen() {
        let app = launch(coaching: true, manualDismissal: true)
        let toast = app.buttons["app-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 25))
        // Existence includes the entrance transition. XCTest otherwise starts its swipe
        // above the visible capsule using the in-flight accessibility frame.
        var previousFrame: CGRect?
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard toast.exists, toast.isHittable else { return false }
            let frame = toast.frame
            defer { previousFrame = frame }
            return frame == previousFrame
        }, object: nil)
        wait(for: [settled], timeout: 5)
        toast.swipeLeft()
        // Re-query: a retained firstMatch snapshot can outlive a disappearing SwiftUI view.
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons.matching(identifier: "app-toast").count == 0
        }, object: nil)
        wait(for: [gone], timeout: 5)
        XCTAssertTrue(app.staticTexts["PREVIEW"].exists)
    }

    @MainActor
    func testWeeklyReviewRevealsOnceAndSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--awards-quiet", "--plan-tab", "--adaptive-review-demo"]
        app.launch()
        let review = app.staticTexts["Your weekly review"]
        XCTAssertTrue(review.waitForExistence(timeout: 25))
        let reveal = app.buttons["Explore this week"]
        for _ in 0..<6 where !reveal.isHittable { app.swipeUp() }
        XCTAssertTrue(reveal.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Weekly review before reveal"; shot.lifetime = .keepAlways; add(shot)
        reveal.tap()
        XCTAssertFalse(reveal.exists)
        app.terminate()
        app.launchArguments = ["--seed-demo", "--awards-quiet", "--plan-tab"]
        app.launch()
        XCTAssertTrue(app.staticTexts["This week"].waitForExistence(timeout: 25))
        XCTAssertFalse(app.buttons["Explore this week"].exists)
    }

    @MainActor
    func testRecoveryFeedbackCanBeSavedRestoredAndCleared() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--awards-quiet", "--save-screen", "--save-bottom"]
        app.launch()
        let pain = app.buttons["recovery-pain"]
        XCTAssertTrue(pain.waitForExistence(timeout: 25))
        for _ in 0..<4 where !pain.isHittable { app.swipeUp() }
        pain.tap(); app.buttons["Yes"].tap()
        XCTAssertTrue((pain.value as? String) == "Yes")
        app.buttons["Done"].tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: pain)
        wait(for: [saved], timeout: 15)
        app.buttons["Plan"].tap()
        let hold = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Recovery check-in needed.")).firstMatch
        XCTAssertTrue(hold.waitForExistence(timeout: 10), "Saved pain feedback must reach the live plan before relaunch.")
        app.terminate()
        app.launchArguments = ["--seed-demo", "--awards-quiet", "--save-screen", "--save-bottom"]
        app.launch()
        XCTAssertTrue(pain.waitForExistence(timeout: 25))
        XCTAssertTrue((pain.value as? String) == "Yes")
        pain.tap(); app.buttons["Not answered"].tap()
        app.buttons["Done"].tap()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: pain)], timeout: 15)
        app.terminate(); app.launch()
        XCTAssertTrue(pain.waitForExistence(timeout: 25))
        XCTAssertTrue((pain.value as? String) == "Not answered")
    }

    @MainActor
    func testCoachingPushUsesTheProductionReceiptAndOpensTheCurrentWeek() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-demo", "--awards-quiet", "--plan-tab",
                               "--plan-locked-week", "--notify-authorize", "--coach-push-demo"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 20) { allow.tap() }
        XCTAssertTrue(app.staticTexts["PREVIEW"].waitForExistence(timeout: 25))
        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'Your coaching review is ready'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 25))
        banner.tap()
        XCTAssertTrue(app.staticTexts["This week"].waitForExistence(timeout: 20))
        let toast = app.descendants(matching: .any).matching(identifier: "app-toast").firstMatch
        XCTAssertFalse(toast.exists && toast.label == "Your coaching review is ready")
    }
}
