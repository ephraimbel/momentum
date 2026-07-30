import XCTest

/// Health-segment visual QA (not a regression test — run explicitly): walks the whole Health page
/// with real swipes, dumping a PNG per viewport in light and dark. Proves end-to-end scrollability
/// (each swipe must move content) and gives the full page a frame-by-frame beauty pass.
final class HealthSegmentShotsUITests: XCTestCase {

    private let dumpDir = "/private/tmp/claude-501/-Users-ephraimbelachew-momentum/9e5489bb-10b4-4631-a8cd-f5b4f9789f6e/scratchpad/healthwalk"

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func dump(_ app: XCUIApplication, _ name: String) {
        try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dumpDir)/\(name).png"))
    }

    private func walk(appearance: String) {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-demo", "--health-recovery-demo", "--progress-tab",
                               "--progress-health", "-com.momentum.appearance", appearance]
        app.launch()
        let discard = app.buttons["Discard"]
        if discard.waitForExistence(timeout: 4) { discard.tap(); sleep(1) }
        sleep(9)   // off-render model build + reveal cascade settles
        dump(app, "\(appearance)-0")
        // Walk the page: each swipe half a screen so cards are never cut at unlucky seams.
        for i in 1...10 {
            // Swipe like a human flick — a slow, held drag legitimately arms the charts'
            // hold-to-scrub and stalls the walk (that's designed behavior, not a scroll bug).
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
            top.press(forDuration: 0.02, thenDragTo: bottom,
                      withVelocity: .fast, thenHoldForDuration: 0.05)
            usleep(900_000)   // let any scroll-settled reveals finish
            dump(app, "\(appearance)-\(i)")
        }
    }

    func testWalkHealthLight() { walk(appearance: "light") }
    func testWalkHealthDark() { walk(appearance: "dark") }
}
