import XCTest

/// The Today deck's collapse ↔ expand cycle (2026-08-19 polish pass): collapsing must land the
/// glass peek with its own Start pill, expanding must bring the full deck back — and exactly ONE
/// Start control may exist in the tree at any settled state (the VoiceOver/XCUITest invariant the
/// mount-one-at-a-time design exists for). The Start control frame-morphs between the two states
/// (`matchedGeometryEffect`), so this also pins that both endpoints stay queryable by identifier.
final class TodayDeckCollapseUITests: XCTestCase {

    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testDeckCollapseAndExpandRoundTrip() {
        roundTrip(reduceMotion: false)
    }

    func testDeckCollapseAndExpandWithReduceMotion() {
        roundTrip(reduceMotion: true)
    }

    private func roundTrip(reduceMotion: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--awards-quiet"]
        if reduceMotion { app.launchArguments.append("--ui-test-reduce-motion") }
        app.launch()
        ScrollTestSupport.dismissRecoveryIfPresent(app, timeout: 3)

        // Settled Today: the expanded deck's Start is on screen. The collapsed state persists
        // across launches by design (@AppStorage), so a container that last ran collapsed is
        // expanded first — the round trip below must start from a known state.
        let deckStart = app.buttons["todayDeckStart"]
        let peekStart = app.buttons["todayPeekStart"]
        let settled = NSPredicate { _, _ in deckStart.exists || peekStart.exists }
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 30)
        if peekStart.exists { app.buttons["Show today's deck"].tap() }
        XCTAssertTrue(deckStart.waitForExistence(timeout: 10), "Expanded deck Start missing on Today.")

        // Collapse → the peek pill's Start replaces it (one Start in the tree, never two).
        let collapse = app.buttons["todayDeckCollapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5), "Deck collapse control missing.")
        collapse.tap()
        XCTAssertTrue(peekStart.waitForExistence(timeout: 5), "Peek Start missing after collapse.")
        XCTAssertFalse(deckStart.exists, "Deck Start must unmount while collapsed (duplicate-Start invariant).")

        // Expand → the full deck returns.
        app.buttons["Show today's deck"].tap()
        XCTAssertTrue(deckStart.waitForExistence(timeout: 5), "Deck Start missing after expand.")
        XCTAssertFalse(peekStart.exists, "Peek Start must unmount while expanded (duplicate-Start invariant).")
    }
}
