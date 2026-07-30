import Testing
import Foundation
@testable import Momentum

/// The coach's curated knowledge library — matching, personalization, and the medical boundary.
struct CoachKnowledgeTests {

    private var facts: CoachKnowledge.Facts {
        CoachKnowledge.Facts(p5kSPerKm: 300, raceDistanceM: 10_000, weeksToRace: 8,
                             daysPerWeek: 4, distanceUnit: .metric)
    }

    @Test func tempoAnswerInterpolatesTheirPace() throws {
        let answer = try #require(CoachKnowledge.answer(for: "What is a tempo run?", facts: facts))
        #expect(answer.contains("comfortably hard"))
        #expect(answer.contains("/km"))   // their Daniels tempo pace, formatted
        // Without calibrated fitness, the concept stands but no number is invented.
        let bare = try #require(CoachKnowledge.answer(for: "What is a tempo run?"))
        #expect(!bare.contains("/km"))
    }

    @Test func medicalBoundaryAlwaysWins() throws {
        for message in ["I get chest pain when I run hard",
                        "I've been dizzy during intervals lately",
                        "Can I keep training while pregnant?"] {
            let answer = try #require(CoachKnowledge.answer(for: message, facts: facts))
            #expect(answer.contains("professional"), "expected the medical boundary for: \(message)")
            #expect(!answer.contains("comfortably hard"))   // never coached around
        }
    }

    @Test func coreTopicsResolve() throws {
        let cases: [(q: String, marker: String)] = [
            ("Should I taper before my race?", "fitness stays sharp"),
            ("What cadence should I aim for?", "180"),
            ("Do treadmill runs count?", "1%"),
            ("When should I replace my shoes?", "500"),
            ("Why are my easy runs so slow?", "conversation"),
            ("Is coffee before a run ok? Thinking about caffeine.", "caffeine"),
            ("How much sleep do I need?", "7 to 9"),
            ("What is VDOT?", "Daniels"),
            ("How do I avoid injury?", "too much, too soon"),
        ]
        for c in cases {
            let answer = try #require(CoachKnowledge.answer(for: c.q, facts: facts), "no topic matched: \(c.q)")
            #expect(answer.localizedCaseInsensitiveContains(c.marker), "'\(c.q)' answered without '\(c.marker)': \(answer)")
        }
    }

    @Test func fuelingNotDietingStanceHolds() throws {
        let answer = try #require(CoachKnowledge.answer(for: "How many calories should I eat to lose weight?", facts: facts))
        #expect(answer.contains("fueling, not dieting"))
        #expect(answer.contains("dietitian"))
        #expect(!answer.contains("deficit"))
    }

    @Test func unknownQuestionsReturnNilForTheFallback() {
        #expect(CoachKnowledge.answer(for: "What's the capital of France?", facts: facts) == nil)
        #expect(CoachKnowledge.answer(for: "asdf qwerty", facts: facts) == nil)
    }

    @Test func taperMentionsTheirRaceWindowWhenClose() throws {
        var f = facts
        f.weeksToRace = 2
        let answer = try #require(CoachKnowledge.answer(for: "how should I taper", facts: f))
        #expect(answer.contains("2 weeks out"))
    }
}
