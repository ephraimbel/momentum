import XCTest

/// Drives the two full-bleed pagers (own profile, community) with real vertical swipes so the
/// swipe-to-swipe experience can be recorded (`xcrun simctl io <udid> recordVideo` alongside) and
/// judged frame by frame — blank beats, blurry placeholders, or a hitch on the snap are only
/// visible in motion. Also the perf gauge for paging: `scrollingAndDecelerationMetric` reads the
/// hitch a live map mount lands on the settle.
///
/// Env `PAGER_CAPTURE_SWIPES` (default 5) sets how many pages to page through, and
/// `PAGER_CAPTURE_DWELL_MS` (default 2200) how long to rest on each so the media can land.
final class PagerSwipeCaptureUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private var swipes: Int { Int(ProcessInfo.processInfo.environment["PAGER_CAPTURE_SWIPES"] ?? "") ?? 5 }
    private var dwellMS: UInt32 { UInt32(ProcessInfo.processInfo.environment["PAGER_CAPTURE_DWELL_MS"] ?? "") ?? 2200 }

    private func monitor() {
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Allow Once", "Allow While Using App", "OK", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]; if b.exists { b.tap(); return true }
            }
            return false
        }
    }

    /// Page down `swipes` times, then back up twice — the scroll-back is where a recycled lazy page
    /// shows whether it remembered its media.
    private func page(_ app: XCUIApplication) {
        usleep(dwellMS * 1000)
        for _ in 0..<swipes {
            app.swipeUp(velocity: .fast)
            usleep(dwellMS * 1000)
        }
        for _ in 0..<min(2, swipes) {
            app.swipeDown(velocity: .fast)
            usleep(dwellMS * 1000)
        }
    }

    /// Own profile: the pager opens on the first GPS workout of the seeded history.
    func testOwnPagerSwipes() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--profile-tab", "--profile-open-run", "--community-perf"]
        monitor()
        app.launch()
        XCTAssertTrue(app.buttons["Edit activity"].firstMatch.waitForExistence(timeout: 20),
                      "Immersive pager didn't open.")
        page(app)
    }

    /// Community: the pager opens on the first wall post (live Mapbox, the worst case on purpose —
    /// no `--ui-test-social`).
    func testCommunityPagerSwipes() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--profile-tab", "--profile-community",
                               "--feed-global", "--open-first-post"]
        monitor()
        app.launch()
        XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 40),
                      "Community pager didn't open.")
        page(app)
    }

    /// The own profile grid: a burst of fast scrolls up and down the mosaic.
    func testOwnGridScroll() { gridScroll(["--seed-demo", "--profile-tab"]) }

    /// The same burst over a ~200-workout history (the marketing seed) — deep enough that the lazy
    /// grid recycles every cell and the snapshot-less tail heals on appearance.
    func testDeepGridScroll() {
        gridScroll(["--reset-store", "--seed-demo", "--marketing-profile", "--profile-tab"])
    }

    private func gridScroll(_ args: [String]) {
        let app = XCUIApplication()
        app.launchArguments = args
        monitor()
        app.launch()
        XCTAssertTrue(app.buttons["Grid"].waitForExistence(timeout: 20), "Profile grid didn't load.")
        usleep(dwellMS * 1000)
        for _ in 0..<3 {
            app.swipeUp(velocity: .fast)
            usleep(900_000)
        }
        for _ in 0..<3 {
            app.swipeDown(velocity: .fast)
            usleep(900_000)
        }
        for _ in 0..<2 {
            app.swipeUp(velocity: .fast)
            usleep(900_000)
        }
    }
}

extension PagerSwipeCaptureUITests {
    /// Drives every tap on a community post — like, unlike, comments open/close, save, byline →
    /// profile → back, double-tap like — with `--community-perf` on, so the main-thread watchdog and
    /// the per-second eval counters (`log stream --predicate 'subsystem == "com.momentum.perf"'`)
    /// can be lined up against the tap times logged here.
    func testCommunityInteractions() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--profile-tab", "--profile-community", "--feed-global",
                               "--open-first-post", "--reset-social", "--community-perf"]
        monitor()
        app.launch()
        XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 40), "Pager didn't open.")
        sleep(5)   // let the first page's map land so taps are measured on a quiet screen

        func stamp(_ what: String) { NSLog("UITAP \(what)") }
        func hittable(_ q: XCUIElementQuery) -> XCUIElement? {
            q.allElementsBoundByIndex.first(where: \.isHittable)
        }

        // Like, then unlike.
        for _ in 0..<2 {
            guard let heart = hittable(app.buttons.matching(NSPredicate(format: "label == 'Like' OR label == 'Liked'"))) else {
                return XCTFail("No like control on the active page.")
            }
            stamp("like \(heart.label)"); heart.tap(); usleep(1_500_000)
        }
        // Comments: open, dwell, Done.
        guard let comments = hittable(app.buttons.matching(identifier: "active-post-comments")) else {
            return XCTFail("No comments control on the active page.")
        }
        stamp("comments open"); comments.tap()
        XCTAssertTrue(app.textFields["comment-field"].waitForExistence(timeout: 8), "Comment sheet didn't open.")
        sleep(2)
        stamp("comments done"); app.buttons["Done"].firstMatch.tap()
        sleep(1)
        // Save / unsave.
        for _ in 0..<2 {
            guard let save = hittable(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Save' OR label BEGINSWITH 'Saved'"))) else {
                return XCTFail("No save control on the active page.")
            }
            stamp("save \(save.label)"); save.tap(); usleep(1_200_000)
        }
        // Double-tap the media to like.
        stamp("double-tap"); app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).doubleTap()
        usleep(1_500_000)
        // Byline → profile → back.
        if let byline = hittable(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View '"))) {
            stamp("byline open"); byline.tap()
            let followPill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Follow'"))
            XCTAssertTrue(followPill.firstMatch.waitForExistence(timeout: 10), "Athlete profile didn't push.")
            sleep(2)
            if let follow = hittable(followPill) {
                stamp("follow \(follow.label)"); follow.tap(); usleep(1_200_000)
                if let again = hittable(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Follow'"))) {
                    stamp("follow \(again.label)"); again.tap(); usleep(1_200_000)
                }
            }
            stamp("profile back")
            if let back = hittable(app.buttons.matching(identifier: "Back")) ?? hittable(app.buttons.matching(NSPredicate(format: "label == 'Back'"))) {
                back.tap()
            } else {
                app.navigationBars.buttons.element(boundBy: 0).tap()
            }
            sleep(2)
        }
        // Swipe once, like the next page too.
        stamp("swipe"); app.swipeUp(); sleep(3)
        if let heart = hittable(app.buttons.matching(NSPredicate(format: "label == 'Like' OR label == 'Liked'"))) {
            stamp("like2 \(heart.label)"); heart.tap(); usleep(1_500_000)
        }
        stamp("close")
        if let close = hittable(app.buttons.matching(NSPredicate(format: "label == 'Close'"))) { close.tap() }
        sleep(2)
        // On the wall: scope tabs and a tile double-tap.
        stamp("tab friends"); app.buttons["Friends"].firstMatch.tap(); sleep(2)
        stamp("tab global"); app.buttons["Global"].firstMatch.tap(); sleep(3)
        stamp("end")
    }
}
