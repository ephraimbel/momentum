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

    @Test func photosOnlyChangeAtTheOffscreenWrapInEitherDirection() {
        for lap in -8...8 {
            let boundary = Double(lap) * 1.64
            let before = boundary - 0.00001, after = boundary + 0.00001
            #expect(WelcomeGalleryMotion.photoLap(before) == lap - 1)
            #expect(WelcomeGalleryMotion.photoLap(after) == lap)
            #expect(WelcomeGalleryMotion.wrappedTravel(before) > 1.31)
            #expect(WelcomeGalleryMotion.wrappedTravel(after) < -0.31)
            // The old photo index changed here, with part of the circle still visible.
            let visibleEdge = boundary + 1.32
            #expect(WelcomeGalleryMotion.photoLap(visibleEdge - 0.00001)
                    == WelcomeGalleryMotion.photoLap(visibleEdge + 0.00001))
        }
    }

    @Test func animationClockResumesAtExactlyThePausedFrame() {
        var clock = WelcomeAnimationClock()
        clock.setRunning(true, at: 10)
        clock.setRunning(true, at: 10.2) // duplicate lifecycle notification must not reset it
        clock.setRunning(false, at: 10.4)
        let paused = clock.elapsed(at: 10.4)
        #expect(abs(paused - 0.4) < 0.000001)
        clock.setRunning(false, at: 100)
        #expect(clock.elapsed(at: 100) == paused)
        clock.setRunning(true, at: 100)
        #expect(clock.elapsed(at: 100) == paused)
        #expect(abs(clock.elapsed(at: 100.3) - 0.7) < 0.000001)
    }

    @Test func interruptedDragCanReleaseWithoutChangingTheResumePose() {
        var motion = WelcomeGalleryMotion()
        motion.drag(x: 90, y: 230, height: 800, at: 1)
        let held = motion.pose(at: 1)
        motion.release(predictedDeltaY: 0, height: 1, at: 1)
        let resumed = motion.pose(at: 1)
        #expect(held.phase == resumed.phase)
        #expect(held.horizontal == resumed.horizontal)
        #expect(held.contact == resumed.contact)
        #expect(!motion.isDragging)
    }
}
