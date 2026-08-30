import Testing
import Foundation
@testable import Momentum

/// The plan reveal's confetti, pinned rather than eyeballed.
///
/// This layer sits over the athlete's finished plan for about three seconds and then must be gone.
/// It has bitten twice: first the pieces computed their position inside a SwiftUI `body`, so
/// `withAnimation` never interpolated them and the fall rendered once at its final position (the
/// celebration simply never happened); then the restructure that fixed it left the Reduce Motion
/// still treatment mounted from a branch that could not be reached.
///
/// So three things are pinned here, and none of them need a simulator:
/// 1. **The scatter is deterministic.** A fixed LCG, not `Double.random`, so every launch and every
///    screenshot lay out identically — reseeding it is a visible change and should fail here.
/// 2. **Every piece is spent by the end.** Nothing may still be drawn over the plan when the fall
///    finishes; a piece left at full opacity is a graphic sitting on the athlete's own page.
/// 3. **Reduce Motion is a different treatment, not a slower one.** It resolves to a still frame
///    and a shorter life, and the layer's mounted duration must follow the mode.
struct PlanRevealConfettiTests {

    private let size = CGSize(width: 393, height: 852)   // iPhone 17 Pro logical size

    // MARK: The scatter is deterministic

    @Test func theScatterIsFixedAndModest() {
        let pieces = RevealConfettiScatter.pieces
        #expect(pieces.count == RevealConfettiScatter.count)
        // "A plan arriving, not a party." If this number climbs, someone reached for spectacle.
        #expect(pieces.count == 26)

        // Built twice, identical both times — the whole point of the LCG over `Double.random`.
        let again = RevealConfettiScatter.pieces
        for (a, b) in zip(pieces, again) {
            #expect(a.x == b.x)
            #expect(a.delay == b.delay)
            #expect(a.spin == b.spin)
        }
    }

    @Test func everyPieceStaysInsideItsStatedRange() {
        for (i, p) in RevealConfettiScatter.pieces.enumerated() {
            #expect(p.x >= 0.04 && p.x <= 0.96, "piece \(i) x \(p.x) starts off-screen")
            #expect(p.delay >= 0 && p.delay <= 0.34, "piece \(i) delay \(p.delay)")
            #expect(p.speed >= 0.80 && p.speed <= 1.20, "piece \(i) speed \(p.speed)")
            #expect(p.drift >= 0.02 && p.drift <= 0.07, "piece \(i) drift \(p.drift)")
            #expect(p.length >= 7 && p.length <= 12, "piece \(i) length \(p.length)")
            #expect((0..<5).contains(p.hue), "piece \(i) hue \(p.hue) is outside the aurora")
        }
        // The hues cycle through the page's five aurora stops, so no single colour dominates.
        #expect(Set(RevealConfettiScatter.pieces.map(\.hue)).count == 5)
    }

    // MARK: Every piece is spent by the end

    @Test func nothingIsStillDrawnWhenTheFallEnds() {
        for (i, p) in RevealConfettiScatter.pieces.enumerated() {
            let end = RevealConfettiScatter.placement(p, progress: 1, in: size)
            // Either it has been dropped entirely, or it has faded out — never left on the page.
            if let end {
                #expect(end.opacity <= 0.0001,
                        "piece \(i) is still drawn at \(end.opacity) over the finished plan")
            }
        }
    }

    @Test func aPieceFallsAndNeverClimbs() {
        for (i, p) in RevealConfettiScatter.pieces.enumerated() {
            var last = -Double.greatestFiniteMagnitude
            for step in 0...40 {
                guard let at = RevealConfettiScatter.placement(p, progress: Double(step) / 40,
                                                               in: size) else { continue }
                #expect(at.y >= last, "piece \(i) climbed at step \(step)")
                last = at.y
                #expect(at.opacity <= RevealConfettiScatter.peakOpacity + 0.0001,
                        "piece \(i) is brighter than the ceiling")
            }
            // It really did travel: a piece that never left the top would read as a dropped frame.
            #expect(last > size.height * 0.5, "piece \(i) never crossed the page")
        }
    }

    @Test func aPieceIsAbsentUntilItsOwnDelayHasPassed() {
        // Each piece keeps its own clock, which is what stops the fall reading as one curtain.
        let latest = RevealConfettiScatter.pieces.max { $0.delay < $1.delay }!
        #expect(RevealConfettiScatter.placement(latest, progress: 0, in: size) == nil)
        #expect(RevealConfettiScatter.placement(latest, progress: latest.delay * 0.5,
                                                in: size) == nil)
        #expect(RevealConfettiScatter.placement(latest, progress: 1, in: size) != nil)
    }

    // MARK: Reduce Motion is a different treatment, not a slower one

    @Test func reduceMotionIsStillAndShorter() {
        #expect(RevealConfettiScatter.restTotal < RevealConfettiScatter.total,
                "the still outstays the fall; a motionless scatter that lingers reads as debris")
        #expect(RevealConfettiScatter.duration(reduceMotion: true) == RevealConfettiScatter.restTotal)
        #expect(RevealConfettiScatter.duration(reduceMotion: false) == RevealConfettiScatter.total)
        #expect(RevealConfettiScatter.total == RevealConfettiScatter.lead + RevealConfettiScatter.fall)
    }

    @Test func theStillFrameStillReadsAsArrivingFromAbove() {
        let pieces = RevealConfettiScatter.pieces
        // A piece that would have waited longer in the fall sits higher in the still frame.
        let earliest = pieces.min { $0.delay < $1.delay }!   // smallest delay
        let latest = pieces.max { $0.delay < $1.delay }!     // largest delay
        let a = RevealConfettiScatter.restingPlacement(earliest, in: size)
        let b = RevealConfettiScatter.restingPlacement(latest, in: size)
        #expect(b.y < a.y, "the later piece should sit higher, so the scatter reads as falling")

        for (i, p) in pieces.enumerated() {
            let at = RevealConfettiScatter.restingPlacement(p, in: size)
            #expect(at.opacity == RevealConfettiScatter.peakOpacity,
                    "piece \(i) fades on its own; the still's fade belongs to the layer")
            #expect(at.y > -size.height, "piece \(i) is parked off the top of the page")
            #expect(at.y < size.height, "piece \(i) is parked below the page")
        }
    }
}
