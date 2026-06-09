import Testing
import Foundation
import SwiftData
@testable import Momentum

/// Verifies user corrections: pinned notes, one-per-category replacement, medical rejection, forget.
@MainActor
struct AthleteModelCorrectionTests {

    /// Returns a container the caller must retain (binding it keeps the context alive).
    func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.models)
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func seedProfile(_ ctx: ModelContext) throws -> UserProfile {
        let profile = UserProfile()
        profile.disciplines = [Discipline.running.rawValue]
        ctx.insert(profile)
        try ctx.save()
        return profile
    }

    @Test func addsPinnedUserNote() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let profile = try seedProfile(ctx)
        AthleteModelService().addCorrection("I actually train in the evenings", category: .habit, for: profile, in: ctx)
        let note = try #require(profile.athlete?.notes.first)
        #expect(note.pinned)
        #expect(note.source == MemorySource.user.rawValue)
        #expect(note.confidence == Confidence.confident.rawValue)
        #expect(note.category == MemoryCategory.habit.rawValue)
        #expect(note.text == "I actually train in the evenings")
    }

    @Test func replacesSameCategoryRatherThanDuplicating() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let profile = try seedProfile(ctx)
        let svc = AthleteModelService()
        svc.addCorrection("Mornings", category: .habit, for: profile, in: ctx)
        svc.addCorrection("Evenings now", category: .habit, for: profile, in: ctx)
        let habitNotes = profile.athlete?.notes.filter {
            $0.isActive && $0.category == MemoryCategory.habit.rawValue
        } ?? []
        #expect(habitNotes.count == 1)
        #expect(habitNotes.first?.text == "Evenings now")
    }

    @Test func rejectsMedicalCorrections() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let profile = try seedProfile(ctx)
        AthleteModelService().addCorrection("my knee pain flares up", category: .response, for: profile, in: ctx)
        #expect(profile.athlete?.notes.isEmpty ?? true)
    }

    @Test func forgetDeactivatesNote() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let profile = try seedProfile(ctx)
        let svc = AthleteModelService()
        svc.addCorrection("Evenings", category: .habit, for: profile, in: ctx)
        let id = try #require(profile.athlete?.notes.first?.id)
        svc.forget(noteID: id, in: ctx)
        #expect(profile.athlete?.notes.first?.isActive == false)
    }
}
