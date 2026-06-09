import Testing
import Foundation
@testable import Momentum

/// Verifies the pure memory-apply rules: sanitize, add/revise/retire, pinned protection, cap (§5, §11).
@MainActor
struct MemoryConsolidationTests {

    private let now = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func note(_ id: UUID = UUID(), _ text: String, confidence: String = "emerging",
                      pinned: Bool = false, active: Bool = true, createdAt: Date? = nil) -> NoteState {
        NoteState(id: id, category: "habit", text: text, confidence: confidence,
                  source: pinned ? "user" : "ai", pinned: pinned, isActive: active,
                  createdAt: createdAt ?? now)
    }

    @Test func cleanRejectsMedicalAndTrims() {
        #expect(MemoryConsolidation.clean("   ") == nil)
        #expect(MemoryConsolidation.clean("Watch that knee pain") == nil)     // banned
        #expect(MemoryConsolidation.clean("You run best in the morning") == "You run best in the morning")
        #expect(MemoryConsolidation.clean(String(repeating: "a", count: 200))?.count == 140)
    }

    @Test func addInsertsCleanNotes() {
        var ids = 0
        let out = MemoryConsolidation.apply(
            [MemoryUpdate(op: "add", id: nil, category: "response", text: "You bounce back fast after rest.",
                          confidence: "growing", evidenceKeys: ["recovery"]),
             MemoryUpdate(op: "add", id: nil, category: "risk", text: "diagnosed with something", // banned → dropped
                          confidence: "emerging", evidenceKeys: nil)],
            to: [], now: now, newID: { ids += 1; return UUID(uuidString: "00000000-0000-0000-0000-00000000000\(ids)")! })
        #expect(out.count == 1)
        #expect(out.first?.category == "response")
        #expect(out.first?.confidence == "growing")
    }

    @Test func reviseUpdatesById() {
        let id = UUID()
        let out = MemoryConsolidation.apply(
            [MemoryUpdate(op: "revise", id: id.uuidString, category: nil,
                          text: "You clearly prefer evenings now.", confidence: "confident", evidenceKeys: nil)],
            to: [note(id, "You might be a morning person.")], now: now)
        #expect(out.first?.text == "You clearly prefer evenings now.")
        #expect(out.first?.confidence == "confident")
    }

    @Test func retireRespectsPinned() {
        let pinnedID = UUID(), aiID = UUID()
        let out = MemoryConsolidation.apply(
            [MemoryUpdate(op: "retire", id: pinnedID.uuidString, category: nil, text: nil, confidence: nil, evidenceKeys: nil),
             MemoryUpdate(op: "retire", id: aiID.uuidString, category: nil, text: nil, confidence: nil, evidenceKeys: nil)],
            to: [note(pinnedID, "I prefer evenings.", pinned: true), note(aiID, "You skip Fridays.")],
            now: now)
        #expect(out.first { $0.id == pinnedID }?.isActive == true)   // pinned survives
        #expect(out.first { $0.id == aiID }?.isActive == false)      // ai note retired
    }

    @Test func capRetiresWeakestKeepsPinned() {
        // 21 active notes: 1 pinned emerging + 20 ai (10 confident, 10 emerging). Cap is 20.
        var notes: [NoteState] = [note(UUID(), "pinned", pinned: true)]
        for i in 0..<10 { notes.append(note(UUID(), "confident \(i)", confidence: "confident",
                                            createdAt: now.addingTimeInterval(Double(i)))) }
        for i in 0..<10 { notes.append(note(UUID(), "emerging \(i)", confidence: "emerging",
                                            createdAt: now.addingTimeInterval(Double(100 + i)))) }
        let out = MemoryConsolidation.apply([], to: notes, now: now)
        let active = out.filter(\.isActive)
        #expect(active.count == MemoryConsolidation.maxActiveNotes)   // 20
        #expect(out.first { $0.pinned }?.isActive == true)           // pinned always kept
        // The single retired note is an emerging one (weakest), not a confident one.
        let retired = out.first { !$0.isActive }
        #expect(retired?.confidence == "emerging")
    }
}
