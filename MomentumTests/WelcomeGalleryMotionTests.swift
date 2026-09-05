import Foundation
import Testing
@testable import Momentum

struct WelcomeGalleryMotionTests {
    @Test func releaseIsContinuousAndCoastIsBounded() {
        var motion = WelcomeGalleryMotion()
        motion.drag(x: 80, y: 150, height: 800, at: 1)
        let held = motion.pose(at: 1)
        motion.release(predictedDeltaY: 100_000, height: 800, at: 1)
        #expect(abs(motion.pose(at: 1).phase - held.phase) < 0.000001)
        #expect(abs(motion.pose(at: 1).horizontal - held.horizontal) < 0.000001)
        let settled = motion.pose(at: 20)
        #expect(abs(settled.phase - held.phase) <= 0.160001)
        #expect(abs(settled.horizontal) < 0.000001)
        #expect(settled.contact < 0.000001)
    }

    @Test func grabbingDuringCoastDoesNotJump() {
        var motion = WelcomeGalleryMotion()
        motion.drag(x: -65, y: -100, height: 800, at: 0)
        motion.release(predictedDeltaY: -160, height: 800, at: 0)
        let prior = motion.pose(at: 0.1)
        motion.drag(x: 0, y: 0, height: 800, at: 0.1)
        let next = motion.pose(at: 0.1)
        #expect(abs(prior.phase - next.phase) < 0.000001)
        #expect(abs(prior.horizontal - next.horizontal) < 0.000001)
    }

    @Test func cancellationFreezesInteractionAcrossBackgrounding() {
        var motion = WelcomeGalleryMotion()
        motion.drag(x: 90, y: 230, height: 800, at: 0)
        motion.release(predictedDeltaY: 120, height: 800, at: 0)
        let phase = motion.pose(at: 0.2).phase
        motion.cancel(at: 0.2)
        #expect(motion.pose(at: 200).phase == phase)
        #expect(motion.pose(at: 200).horizontal == 0)
        #expect(!motion.isDragging)
    }

    @Test func wrappingOnlyJumpsBetweenOffscreenPositions() {
        for value in stride(from: -15.0, through: 15, by: 0.013) {
            let travel = WelcomeGalleryMotion.wrappedTravel(value)
            #expect(travel >= -0.32 && travel < 1.32)
            #expect(abs(travel - WelcomeGalleryMotion.wrappedTravel(value + 1.64)) < 0.000001)
        }
    }
}
