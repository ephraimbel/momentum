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

    @Test func theScatterIsFixedAndCelebratory() {
        let pieces = RevealConfettiScatter.pieces
        #expect(pieces.count == RevealConfettiScatter.count)
        // A real burst, still rendered as one Canvas pass rather than one view per piece.
        #expect(pieces.count == 72)

        // Built twice, identical both times — the whole point of the LCG over `Double.random`.
        let again = RevealConfettiScatter.pieces
        for (a, b) in zip(pieces, again) {
            #expect(a.originX == b.originX)
            #expect(a.originY == b.originY)
            #expect(a.delay == b.delay)
            #expect(a.velocityX == b.velocityX)
            #expect(a.velocityY == b.velocityY)
            #expect(a.spin == b.spin)
        }
    }

    @Test func everyPieceStaysInsideItsStatedRange() {
        for (i, p) in RevealConfettiScatter.pieces.enumerated() {
            #expect(p.originX >= -0.04 && p.originX <= 1.04, "piece \(i) origin x \(p.originX)")
            #expect(p.originY >= -0.08 && p.originY <= 0.30, "piece \(i) origin y \(p.originY)")
            #expect(p.delay >= 0 && p.delay <= 0.15, "piece \(i) delay \(p.delay)")
            #expect(p.velocityX >= -0.62 && p.velocityX <= 0.62, "piece \(i) vx \(p.velocityX)")
            #expect(p.velocityY >= -0.80 && p.velocityY <= 0.17, "piece \(i) vy \(p.velocityY)")
            #expect(p.gravity >= 1.55 && p.gravity <= 1.93, "piece \(i) gravity \(p.gravity)")
            #expect(p.drift >= 0.008 && p.drift <= 0.036, "piece \(i) drift \(p.drift)")
            #expect(p.length >= 8 && p.length <= 28, "piece \(i) length \(p.length)")
            #expect(p.width >= 3 && p.width <= 7, "piece \(i) width \(p.width)")
            #expect(p.depth >= 0.78 && p.depth <= 1.30, "piece \(i) depth \(p.depth)")
            #expect(p.alpha >= 0.82 && p.alpha <= 1, "piece \(i) alpha \(p.alpha)")
            #expect((0..<5).contains(p.hue), "piece \(i) hue \(p.hue) is outside the aurora")
        }
        // Both cannons and the crown must be populated, or the effect collapses into another rain.
        #expect(RevealConfettiScatter.pieces.filter { $0.originX < 0 }.count >= 20)
        #expect(RevealConfettiScatter.pieces.filter { $0.originX > 1 }.count >= 20)
        #expect(RevealConfettiScatter.pieces.filter { (0...1).contains($0.originX) }.count >= 10)
        #expect(Set(RevealConfettiScatter.pieces.map(\.hue)).count == 5)
        #expect(Set(RevealConfettiScatter.pieces.map(\.kind)) == Set(RevealConfettiScatter.Kind.allCases))
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

    @Test func theCannonsLaunchThenGravityClearsThePlan() {
        for (i, p) in RevealConfettiScatter.pieces.enumerated() {
            var minimumY = CGFloat.greatestFiniteMagnitude
            var last: RevealConfettiScatter.Placement?
            for step in 0...40 {
                guard let at = RevealConfettiScatter.placement(p, progress: Double(step) / 40,
                                                               in: size) else { continue }
                minimumY = min(minimumY, at.y)
                last = at
                #expect(at.opacity <= RevealConfettiScatter.peakOpacity + 0.0001,
                        "piece \(i) is brighter than the ceiling")
                #expect(at.foreshortening >= 0.22 && at.foreshortening <= 1.0001,
                        "piece \(i) has an invalid paper flip")
            }
            #expect(last != nil)
            #expect(last!.y > size.height * 0.90, "piece \(i) did not clear the plan")
            if p.originX < 0 || p.originX > 1 {
                #expect(minimumY < p.originY * size.height,
                        "side-cannon piece \(i) never launched upward")
            }
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
        for (i, p) in RevealConfettiScatter.pieces.enumerated() {
            let at = RevealConfettiScatter.restingPlacement(p, in: size)
            #expect(at.opacity == RevealConfettiScatter.peakOpacity * p.alpha,
                    "piece \(i) should keep its authored depth in the still treatment")
            #expect(at.x > 0 && at.x < size.width, "piece \(i) is outside the still burst")
            #expect(at.y > 0 && at.y < size.height * 0.60,
                    "piece \(i) is outside the still burst's upper field")
        }
    }
}
