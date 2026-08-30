import XCTest

/// The Athlete Panel's figure turns around (2026-08-29). Front-only meant glutes, hamstrings and
/// the whole back could never light up however hard the athlete trained them, so the panel's own
/// promise — a training portrait you can watch change — only ever covered half a body.
///
/// This pins the behaviour, not the pixels: the figure is a real button, one tap turns it, a
/// second turns it back, and it never gets stranded facing sideways. The caption under the feet is
/// deliberately hidden from VoiceOver (the figure button already announces which side is showing),
/// so every assertion here reads the BUTTON, never the caption's text.
final class AthletePanelFlipUITests: XCTestCase {

    private let front = "Athlete figure, front"
    private let back = "Athlete figure, back"

    private func launchProgress(_ extraArgs: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--progress-tab"] + extraArgs
        app.launch()
        return app
    }

    /// The figure, once it will actually accept a touch.
    ///
    /// Progress reveals its stack with a fade + lift (`RevealOnAppear`, 0.5s), so the panel exists
    /// in the accessibility tree — and reports its FINAL frame — while it is still translucent and
    /// still sliding into that frame. A tap synthesized into that half second is aimed at where the
    /// figure is about to be, and lands on where it isn't. Waiting for the frame to hold still is
    /// what makes this suite deterministic; it is not papering over a product bug, it is the same
    /// beat a person waits through before touching anything.
    @discardableResult
    private func settledFigure(_ app: XCUIApplication, _ identifier: String,
                               timeout: TimeInterval = 25) -> XCUIElement {
        let element = app.buttons[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(identifier) never appeared")
        var previous = CGRect.null
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let frame = element.frame
            if frame == previous, element.isHittable { return element }
            previous = frame
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("\(identifier) never settled into a stable, hittable frame")
        return element
    }

    /// One tap turns the body over; a second turns it back.
    func testTappingTheFigureTurnsTheBodyAndBack() {
        let app = launchProgress()
        settledFigure(app, front).tap()
        XCTAssertTrue(app.buttons[back].waitForExistence(timeout: 5), "one tap should turn the figure")
        XCTAssertFalse(app.buttons[front].exists, "and only one face is ever mounted")

        app.buttons[back].tap()
        XCTAssertTrue(app.buttons[front].waitForExistence(timeout: 5), "a second tap turns it back")
        XCTAssertFalse(app.buttons[back].exists)
    }

    /// Taps landing during the turn must not strand the figure edge-on or half-swapped — the guard
    /// in `flipBody()` is what makes a tap mid-turn a no-op instead of a second, overlapping turn.
    func testHammeringTheFigureNeverStrandsItSideways() {
        let app = launchProgress()
        settledFigure(app, front)

        let anyFace = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "Athlete figure,")).firstMatch
        for _ in 0..<6 {
            if anyFace.exists { anyFace.tap() }
        }

        // However the taps landed, it settles showing exactly one real face.
        let settled = app.buttons[front].waitForExistence(timeout: 5) || app.buttons[back].exists
        XCTAssertTrue(settled, "the figure must settle on a real face, never mid-turn")
        XCTAssertNotEqual(app.buttons[front].exists, app.buttons[back].exists,
                          "exactly one face at a time")
    }

    /// The caption under the feet is the visible affordance, so it has to turn the figure too.
    /// Its centre is a fixed offset below the figure's own frame (`captionGap` + `captionHeight`/2
    /// in `AthletePanel`), so this taps the layout rather than a guessed pixel.
    func testTheCaptionTurnsTheFigureAsWell() {
        let app = launchProgress()
        let figure = settledFigure(app, front)

        let frame = figure.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.maxY + 18))
            .tap()
        XCTAssertTrue(app.buttons[back].waitForExistence(timeout: 5),
                      "tapping the caption should turn the figure")
    }

    /// The debug entry point future screenshot passes rely on.
    func testDebugArgLandsOnTheBack() {
        let app = launchProgress(["--athlete-panel-back"])
        XCTAssertTrue(app.buttons[back].waitForExistence(timeout: 25),
                      "--athlete-panel-back should open with the figure already turned")
    }
}
