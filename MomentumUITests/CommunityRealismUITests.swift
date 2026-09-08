import XCTest

/// Live Mapbox capture (no --ui-test-social), separate from deterministic silhouette tests.
final class CommunityRealismUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--profile-tab", "--profile-community", "--feed-global", "--community-perf"] + extra
        // Isolate the test's starting position without clearing saved routes or collections.
        for scope in ["everyone", "following"] {
            app.launchArguments += ["-com.momentum.community.experience.\(scope).anchorID", "",
                                    "-com.momentum.community.experience.\(scope).anchorDate", "0"]
        }
        app.launch()
        let resume = app.buttons["welcome.gallery.start"]
        if resume.waitForExistence(timeout: 3) { resume.tap() }
        return app
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func settleMaps() {
        let settled = expectation(description: "Allow cold Mapbox tiles to arrive")
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { settled.fulfill() }
        wait(for: [settled], timeout: 50)
    }

    @MainActor func testLiveWallDeepBrowseAndPostKeepWorking() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Explore"].waitForExistence(timeout: 30))
        capture(app, "wall-first-paint")
        settleMaps()
        capture(app, "wall-warm")
        let info = app.buttons["community.examples.info"]
        XCTAssertTrue(info.exists)
        info.tap()
        XCTAssertTrue(app.alerts["About example profiles"].waitForExistence(timeout: 5))
        app.alerts.buttons["Got it"].tap()
        for page in 0..<6 {
            app.swipeUp()
            capture(app, "wall-page-\(page + 1)")
        }
        let tiles = app.buttons.matching(NSPredicate(format: "label CONTAINS ' mi · '"))
        guard let tile = tiles.allElementsBoundByIndex.first(where: {
            $0.isHittable && $0.frame.minY > app.frame.minY + 130 && $0.frame.maxY < app.frame.maxY - 110
        }) else { return XCTFail("No routed tile accessible after deep scrolling") }
        let author = String(tile.label.split(separator: ",").first ?? "")
        tile.tap()
        XCTAssertTrue(app.buttons["View \(author)'s profile"].waitForExistence(timeout: 15))
        settleMaps()
        capture(app, "route-fullscreen")
        app.buttons["View \(author)'s profile"].tap()
        capture(app, "athlete-from-route")
    }

    @MainActor func testCompactHeaderIsDefault() {
        let app = launch(["--reset-social"])
        XCTAssertTrue(app.staticTexts["Explore"].waitForExistence(timeout: 30))
        let find = app.buttons["Find people"]
        for _ in 0..<12 where !find.isHittable { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(find.isHittable)
        capture(app, "header-compact-default")
    }

    @MainActor func testSearchByHandleOpensTheSameAthlete() {
        let app = launch(["--ui-test-social", "--find-athletes", "--find-query", "@sub3maya"])
        let row = app.buttons["View Maya Rivera's profile"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        capture(app, "search-handle-result")
        row.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format:
            "label BEGINSWITH 'Follow Maya Rivera' OR label BEGINSWITH 'Following Maya Rivera'"))
            .firstMatch.waitForExistence(timeout: 15))
        capture(app, "search-athlete-profile")
    }
    @MainActor func testRouteBrowserFiltersAndOpensPost() {
        let app = launch(["--ui-test-social", "-com.momentum.appearance", "dark"])
        let browse = app.buttons["community.routes.browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 30))
        browse.tap()
        let distance = app.buttons["community.routes.distance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 10))
        distance.tap()
        let short = app.buttons.matching(NSPredicate(format: "label == 'Under 3 mi' OR label == 'Under 5 km'" )).firstMatch
        XCTAssertTrue(short.waitForExistence(timeout: 5))
        short.tap()
        capture(app, "route-browser-short")
        distance.tap()
        app.buttons["Any distance"].tap()
        app.buttons["community.routes.location"].tap()
        let location = app.buttons["Amsterdam"]
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        location.tap()
        capture(app, "route-browser-amsterdam")
        let route = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Example route'")).firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 10))
        route.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
        capture(app, "route-browser-opened-post")
        app.buttons["Close"].tap()
        XCTAssertTrue(distance.waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
    }

    @MainActor func testSavedCollectionPersistsAcrossRelaunch() {
        let app = launch(["--ui-test-social", "--saved-routes"])
        let organize = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Organize '")).firstMatch
        XCTAssertTrue(organize.waitForExistence(timeout: 30))
        organize.tap()
        app.buttons["New collection…"].tap()
        let alert = app.alerts["New collection"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertFalse(alert.buttons["Create"].isEnabled)
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText("Weekend tests")
        alert.buttons["Create"].tap()
        XCTAssertTrue(organize.waitForExistence(timeout: 5))
        capture(app, "saved-route-collection")
        app.terminate()
        let restored = launch(["--ui-test-social", "--saved-routes"])
        let filter = restored.buttons["saved.collections.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 30))
        filter.tap()
        restored.buttons["Weekend tests"].tap()
        XCTAssertTrue(restored.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Organize '")).firstMatch.exists)
        restored.buttons["Collection options"].tap()
        restored.buttons["Delete collection"].tap()
        XCTAssertTrue(restored.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Organize '")).firstMatch.exists,
                      "Deleting a collection must preserve the saved route")
    }

    @MainActor func testSavedRouteDetailRemovalUpdatesTheLibrary() {
        let app = launch(["--reset-store", "--reset-auth", "--ui-test-social", "--saved-routes"])
        let organize = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Organize '")).firstMatch
        XCTAssertTrue(organize.waitForExistence(timeout: 30))
        let title = String(organize.label.dropFirst("Organize ".count))
        let route = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
        XCTAssertTrue(route.exists)
        route.tap()
        let remove = app.buttons["Remove from saved routes"]
        XCTAssertTrue(remove.waitForExistence(timeout: 15))
        remove.tap()
        XCTAssertTrue(app.staticTexts["Nothing saved yet"].waitForExistence(timeout: 10))
        XCTAssertFalse(organize.exists)
    }

    @MainActor func testFastScrollingAndBackgroundReturnKeepControlsWorking() {
        let app = launch(["--reset-social", "--ui-test-social", "--ui-test-reduce-motion"])
        let browse = app.buttons["community.routes.browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 30))
        for _ in 0..<5 { app.swipeUp(velocity: .fast) }
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        for _ in 0..<12 where !browse.isHittable { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(browse.isHittable)
        browse.tap()
        XCTAssertTrue(app.buttons["community.routes.distance"].waitForExistence(timeout: 10))
        for _ in 0..<3 { app.swipeUp(velocity: .fast) }
        app.buttons["Done"].tap()
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        capture(app, "wall-after-fast-scroll-and-background")
    }

    @MainActor func testLargeTextKeepsRouteFiltersAndDoneReachable() {
        let app = launch(["--reset-social", "--ui-test-social", "-UIPreferredContentSizeCategoryName",
                          "UICTContentSizeCategoryAccessibilityXXXL"])
        let browse = app.buttons["community.routes.browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 30))
        for _ in 0..<12 where !browse.isHittable { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(browse.isHittable)
        browse.tap()
        let distance = app.buttons["community.routes.distance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 10))
        XCTAssertTrue(distance.isHittable)
        XCTAssertTrue(app.buttons["community.routes.location"].isHittable)
        XCTAssertTrue(app.buttons["Done"].isHittable)
        distance.tap()
        let short = app.buttons.matching(NSPredicate(format: "label == 'Under 3 mi' OR label == 'Under 5 km'")).firstMatch
        XCTAssertTrue(short.waitForExistence(timeout: 5))
        short.tap()
        capture(app, "route-browser-accessibility-text")
        app.buttons["Done"].tap()
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
    }

}
