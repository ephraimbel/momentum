import Testing
import Foundation
@testable import Momentum

/// `PlanMoveAdvice` is the one line the board says after the athlete drags a session to a new day.
/// Its whole job is restraint: name a placement worth naming, stay silent otherwise, and never once
/// read as a verdict on the athlete.
@Suite("PlanMoveAdvice")
struct PlanMoveAdviceTests {

    private func note(_ moved: RestDayLine.Neighbor, sameDay: RestDayLine.Neighbor = .none,
                      before: RestDayLine.Neighbor = .none, after: RestDayLine.Neighbor = .none) -> String? {
        PlanMoveAdvice.note(moved: moved, sameDay: sameDay, dayBefore: before, dayAfter: after)
    }

    // MARK: Silence is the default

    @Test func anOrdinaryLandingSaysNothing() {
        #expect(note(.quality) == nil)
        #expect(note(.long, before: .easy, after: .easy) == nil)
        #expect(note(.quality, sameDay: .strength, before: .easy, after: .strength) == nil)
    }

    @Test func onlyHardRunningEarnsANote() {
        // An easy run or a lift goes wherever it fits, and a race is a fixed point on the calendar:
        // moving one is a decision about the season, not about spacing.
        for moved: RestDayLine.Neighbor in [.easy, .strength, .race, .none] {
            #expect(note(moved, sameDay: .long, before: .quality, after: .race) == nil)
        }
    }

    // MARK: The ladder, in order

    @Test func doublingUpOutranksEverything() {
        // The board stacks same-day sessions rather than refusing them, so this is the placement an
        // athlete is likeliest not to have intended. It wins over every neighbour rule.
        #expect(note(.quality, sameDay: .long, before: .quality, after: .race) == "Two hard sessions on the same day.")
        #expect(note(.long, sameDay: .quality) == "Two hard sessions on the same day.")
        // A lift or an easy run sharing the day is not doubling up on hard work.
        #expect(note(.quality, sameDay: .strength) == nil)
        #expect(note(.quality, sameDay: .easy) == nil)
    }

    @Test func raceDayNeighboursAreNamedFirst() {
        #expect(note(.quality, after: .race) == "The day before your race.")
        #expect(note(.quality, before: .race) == "The day after your race.")
    }

    @Test func hardOnBothSidesReadsAsOneLine() {
        #expect(note(.quality, before: .long, after: .quality) == "Hard days on both sides of this one.")
        // And it outranks the single-neighbour lines: a session boxed in on both sides should hear
        // about the box, not about one of its walls.
        #expect(note(.quality, before: .quality, after: .long) == "Hard days on both sides of this one.")
    }

    @Test func forwardOutranksBackward() {
        // Matching RestDayLine: what a day leads into is more actionable than what it followed.
        #expect(note(.quality, before: .easy, after: .long) == "Your long run is the next day.")
        #expect(note(.long, after: .quality) == "Another hard day follows this one.")
        #expect(note(.quality, before: .long) == "This follows your long run.")
        #expect(note(.quality, before: .quality) == "This follows a hard day.")
    }

    // MARK: Voice

    @Test func everyLineIsAPlacementNeverAVerdict() {
        // Assemble every line the engine can produce and hold it to the coaching voice: it states
        // where the session landed, and never grades the athlete or tells them to undo it.
        let all: [String] = [
            note(.quality, sameDay: .long), note(.quality, after: .race), note(.quality, before: .race),
            note(.quality, before: .long, after: .quality), note(.quality, after: .long),
            note(.quality, after: .quality), note(.quality, before: .long), note(.quality, before: .quality)
        ].compactMap { $0 }
        #expect(all.count == 8)
        let banned = ["should", "avoid", "bad", "wrong", "mistake", "too", "instead", "failed", "don't"]
        for line in all {
            let lower = line.lowercased()
            #expect(!banned.contains { lower.contains($0) }, "\(line) reads as a verdict")
            #expect(line.hasSuffix("."))
            #expect(line.count < 50)
        }
        #expect(Set(all).count == 8)   // eight distinct lines, no rule shadowing another
    }
}
