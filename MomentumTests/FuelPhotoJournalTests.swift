import Testing
import Foundation
import SwiftData
import UIKit
@testable import Momentum

/// The photo journal (2026-09-07): a plate logged without words is a real meal that is due an
/// estimate, wears an honest title, never leaks into the usuals, and lands a rejection the same
/// way the text lane does. Plus the readout builder keeping the day's completed run in the carb
/// tier, so a past day never reads as an easy one just because its long run is over.
@MainActor
struct FuelPhotoJournalTests {

    /// The controller must outlive the context (see `SiriMealLoggerTests.fresh`): returning
    /// `mainContext` alone lets the container deallocate under it.
    private func fresh() -> (keep: PersistenceController, context: ModelContext) {
        let pc = PersistenceController.inMemory()
        return (pc, pc.container.mainContext)
    }

    /// A small valid JPEG through the journal's own path (`MealPhotoTests` renders the same way).
    private func smallJPEG() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48), format: format)
        let image = renderer.image { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            UIColor.brown.setFill(); ctx.fill(CGRect(x: 16, y: 12, width: 32, height: 24))
        }
        let prepared = try #require(MealPhoto.prepare(image: image))
        #expect(MealPhoto.isSendable(prepared))
        return prepared
    }

    private func toast() -> MealItem {
        MealItem(name: "Toast", qty: 1, unit: "slice", kcal: 101, carbsG: 19,
                 proteinG: 3, fatG: 1, sodiumMg: 123, fluidsMl: 0)
    }

    // MARK: 1. A photo-only meal is due

    @Test func aPhotoOnlyMealIsDueAnEstimateAndTitledHonestly() throws {
        let meal = Meal()
        meal.text = ""
        meal.photoData = try smallJPEG()
        #expect(meal.source == "pending")
        #expect(meal.estimateAttempts == 0)
        #expect(meal.hasPhoto)
        #expect(meal.isEstimable)
        #expect(meal.needsEstimate(maxAttempts: 3))
        #expect(meal.journalTitle == "Photo of a meal")
    }

    // MARK: 2. Title fallbacks

    @Test func journalTitleFallsBackFromItemsToWordsToPlateToMeal() {
        let meal = Meal()
        // Neither words nor a plate: a name, never a blank row.
        #expect(meal.journalTitle == "Meal")
        // The athlete's own words, trimmed.
        meal.text = "  eggs "
        #expect(meal.journalTitle == "eggs")
        // Items outrank the words once they land.
        meal.items = [toast(),
                      MealItem(name: "Egg", qty: 2, unit: "egg", kcal: 140, carbsG: 1,
                               proteinG: 12, fatG: 10, sodiumMg: 140, fluidsMl: 0)]
        #expect(meal.journalTitle == "Toast · Egg ×2")
        // A plate with no words and no items yet.
        meal.items = []
        meal.text = "   "
        meal.photoData = Data([0xFF, 0xD8, 0xFF])
        #expect(meal.journalTitle == "Photo of a meal")
    }

    // MARK: 3. rejectionNote

    @Test func rejectionNoteShowsOnlyForAnUnreadPendingMeal() {
        let meal = Meal()
        meal.note = FuelEstimator.rejectionLine("not_food", hasPhoto: true)
        meal.confidence = 0
        meal.carbsG = nil
        meal.source = "pending"
        #expect(meal.rejectionNote == meal.note)

        // The athlete's own hand: their words, never the server's.
        meal.source = "manual"
        #expect(meal.rejectionNote == nil)
        meal.source = "pending"

        // Numbers on the row: the note is a coach line, not a rejection.
        meal.carbsG = 10
        #expect(meal.rejectionNote == nil)
        meal.carbsG = nil

        // Any confidence above zero is an estimate that happened.
        meal.confidence = 0.5
        #expect(meal.rejectionNote == nil)
        meal.confidence = 0

        // No words to show is no rejection to show.
        meal.note = ""
        #expect(meal.rejectionNote == nil)
        meal.note = nil
        #expect(meal.rejectionNote == nil)
    }

    // MARK: 4. Usuals exclusion

    @Test func aPhotoOnlyMealNeverBecomesAUsual() throws {
        let (pc, context) = fresh(); _ = pc
        // No words canonicalize to the empty key, which must never be looked up.
        let emptyKey = MealTextKey.normalized("")
        #expect(emptyKey.isEmpty)
        #expect(!MealTextKey.isMatchable(emptyKey))
        #expect(!MealTextKey.isMatchable(MealTextKey.normalized("  \n ")))

        let jpeg = try smallJPEG()
        // A plate still pending: outside the candidate population altogether.
        let pending = Meal()
        pending.photoData = jpeg
        context.insert(pending)
        // The same plate once the estimate landed its items: numbers, but still no words.
        let read = Meal()
        read.photoData = jpeg
        read.items = [toast()]
        read.source = "ai"
        read.confidence = 0.6
        read.eatenAt = Date()
        context.insert(read)
        // A typed meal with numbers: the one legitimate usual.
        let typed = Meal()
        typed.text = "oatmeal"
        typed.items = [toast()]
        typed.source = "ai"
        typed.confidence = 0.8
        typed.eatenAt = Date().addingTimeInterval(-3600)
        context.insert(typed)
        try context.save()

        let candidates = FuelLocalResolver.candidates(in: context)
        #expect(candidates.count == 2)
        #expect(!candidates.contains { $0.id == pending.id })
        #expect(candidates.contains { $0.id == read.id })
        // The usuals grouping (`FuelView.computeUsuals`) keys candidates by the same canonical
        // key the typed lookup uses and skips an unmatchable one: the wordless plate is never a chip.
        let usualKeys = candidates.map { MealTextKey.normalized($0.text) }.filter(MealTextKey.isMatchable)
        #expect(usualKeys == ["oatmeal"])
        // Nor can typing reach it: not with an unrelated sentence, and not with nothing at all.
        #expect(FuelLocalResolver.match(for: "grilled chicken and rice", in: context) == nil)
        #expect(FuelLocalResolver.match(for: "", in: context) == nil)
        #expect(FuelLocalResolver.match(for: "oatmeal", in: context)?.id == typed.id)
    }

    // MARK: 5. Rejected persistence through the injectable estimator

    @Test func aRejectedAnswerRestsTheMealWithTheTextVariantLine() async throws {
        let (pc, context) = fresh(); _ = pc
        let receipt = try #require(await SiriMealLogger.logAndEstimate(
            text: "grandma's mystery casserole", in: context, entitled: true,
            estimate: { _ in .rejected(reason: "not_food") }))
        #expect(!receipt.resolved)

        let meal = try #require(try context.fetch(FetchDescriptor<Meal>()).first)
        let note = try #require(meal.note)
        // A Siri meal is text: it never hears about a photo it did not send.
        #expect(note == FuelEstimator.rejectionLine("not_food", hasPhoto: false))
        #expect(!note.lowercased().contains("photo"))
        // The cap is spent, the confidence is zero, and no number was invented.
        #expect(meal.estimateAttempts == 3)
        #expect(meal.confidence == 0)
        #expect(meal.carbsG == nil)
        #expect(meal.kcal == nil)
        #expect(meal.source == "pending")
        #expect(!meal.needsEstimate(maxAttempts: 3))
        // The hand-fired "Estimate again" ignores the cap and may still ask.
        #expect(meal.isEstimable)
        // The row shows the server's words once, as the status line.
        #expect(meal.rejectionNote == note)
    }

    @Test func aMealSetByHandMidFlightKeepsItsOwnWordsWhenTheRejectionLands() async throws {
        let (pc, context) = fresh(); _ = pc
        let container = pc.container
        let receipt = try #require(await SiriMealLogger.logAndEstimate(
            text: "grandma's mystery casserole", in: context, entitled: true,
            estimate: { text in
                // While the call is out, the athlete opens the row and sets it by hand.
                await MainActor.run {
                    let ctx = container.mainContext
                    guard let meal = (try? ctx.fetch(FetchDescriptor<Meal>()))?
                        .first(where: { $0.text == text }) else {
                        Issue.record("the meal under estimate must already be on the record")
                        return
                    }
                    meal.carbsG = 42
                    meal.kcal = 300
                    meal.note = "Leftovers from Sunday."
                    meal.source = "manual"
                    try? ctx.save()
                }
                return .rejected(reason: "not_food")
            }))
        #expect(!receipt.resolved)

        let meal = try #require(try context.fetch(FetchDescriptor<Meal>()).first)
        #expect(meal.source == "manual")
        #expect(meal.note == "Leftovers from Sunday.")
        // The fire stood (a call was made) but the rejection's cap-spend never landed.
        #expect(meal.estimateAttempts == 1)
        #expect(meal.confidence == nil)
        #expect(meal.carbsG == 42)
        #expect(meal.kcal == 300)
        #expect(meal.rejectionNote == nil)
        #expect(!meal.isEstimable)
    }

    // MARK: 6. Request body contract

    @Test func theRequestBodyCarriesAnImageOnlyWhenOneWasSent() throws {
        let textOnly = FuelEstimator.requestBody(text: "eggs", imageJPEG: nil,
                                                 sessionLabel: "today's session", durationS: 3600)
        #expect(textOnly.image == nil)
        let textData = try JSONEncoder().encode(textOnly)
        let textObject = try #require(try JSONSerialization.jsonObject(with: textData) as? [String: Any])
        #expect(textObject["image"] == nil)
        #expect(textObject["text"] as? String == "eggs")
        let context = try #require(textObject["context"] as? [String: Any])
        #expect(context["session"] as? String == "today's session")
        #expect(context["durationS"] as? Double == 3600)

        let jpeg = try smallJPEG()
        let withPhoto = FuelEstimator.requestBody(text: "eggs", imageJPEG: jpeg, sessionLabel: nil, durationS: nil)
        let photoData = try JSONEncoder().encode(withPhoto)
        let photoObject = try #require(try JSONSerialization.jsonObject(with: photoData) as? [String: Any])
        #expect(photoObject["text"] as? String == "eggs")
        let image = try #require(photoObject["image"] as? [String: Any])
        #expect(image["mime"] as? String == "image/jpeg")
        #expect(image["mime"] as? String == MealPhoto.mimeType)
        let base64 = try #require(image["base64"] as? String)
        #expect(base64 == jpeg.base64EncodedString())
        #expect(Data(base64Encoded: base64) == jpeg)

        // The bytes on the wire carry exactly the encoded body's content, in both shapes (key
        // order is the encoder's business, so compare the parsed objects, not the bytes).
        func parsed(_ data: Data) throws -> NSDictionary {
            try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        }
        #expect(try parsed(FuelEstimator.encodedBody(text: "eggs", imageJPEG: nil,
                                                     sessionLabel: "today's session", durationS: 3600)) == parsed(textData))
        #expect(try parsed(FuelEstimator.encodedBody(text: "eggs", imageJPEG: jpeg,
                                                     sessionLabel: nil, durationS: nil)) == parsed(photoData))
    }

    // MARK: 7. Rejection line variants

    @Test func theRejectionLineSpeaksOfAPhotoOnlyWhenOneWasSent() {
        #expect(FuelEstimator.rejectionLine("not_food", hasPhoto: true).contains("photo"))
        #expect(!FuelEstimator.rejectionLine("not_food", hasPhoto: false).contains("photo"))
        #expect(!FuelEstimator.rejectionLine("unreadable", hasPhoto: false).contains("photo"))
        #expect(FuelEstimator.rejectionLine("unreadable", hasPhoto: true).contains("photo"))
        // Two reasons are two different lines, in each voice.
        #expect(FuelEstimator.rejectionLine("not_food", hasPhoto: true)
                != FuelEstimator.rejectionLine("unreadable", hasPhoto: true))
        #expect(FuelEstimator.rejectionLine("not_food", hasPhoto: false)
                != FuelEstimator.rejectionLine("unreadable", hasPhoto: false))
        // Every line is coach copy: no dashes, and it always offers the by-hand way out.
        for reason in ["not_food", "unreadable", "something_else"] {
            for hasPhoto in [true, false] {
                let line = FuelEstimator.rejectionLine(reason, hasPhoto: hasPhoto)
                #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}"))
                #expect(line.contains("by hand"))
            }
        }
    }

    // MARK: 8. The builder keeps the day's run in the carb tier

    @Test func theBuilderKeepsTheDaysRunInTheCarbTier() throws {
        let (pc, context) = fresh(); _ = pc
        let profile = UserProfile()
        profile.bodyMassKg = 70
        context.insert(profile)
        // A fixed local afternoon: two hours earlier is the same calendar day everywhere.
        let cal = Calendar.current
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 14)))
        let run = Workout()
        run.type = .run
        run.durationS = 5400
        run.startedAt = now.addingTimeInterval(-2 * 3600)
        context.insert(run)
        try context.save()

        let quiet = FuelReadoutBuilder.readout(meals: [], plan: nil, workouts: [], profile: profile,
                                               water: [], now: now)
        let ran = FuelReadoutBuilder.readout(meals: [], plan: nil, workouts: [run], profile: profile,
                                             water: [], now: now)
        #expect(quiet.carbsFloorG == Int((FuelReadiness.carbsPerKgEasy * 70).rounded()))
        #expect(quiet.drivingSession == nil)
        #expect(ran.carbsFloorG == Int((FuelReadiness.carbsPerKgModerate * 70).rounded()))
        #expect(ran.carbsFloorG > quiet.carbsFloorG)
        let driver = try #require(ran.drivingSession)
        #expect(driver.contains("today"))
        #expect(driver.contains("1h 30m"))
        #expect(ran.drivingIsToday)
        #expect(!ran.raceEve)

        // A lift of the same length is not a run: it never keys the carb tier.
        let lift = Workout()
        lift.type = .strength
        lift.durationS = 5400
        lift.startedAt = run.startedAt
        context.insert(lift)
        try context.save()
        let lifted = FuelReadoutBuilder.readout(meals: [], plan: nil, workouts: [lift], profile: profile,
                                                water: [], now: now)
        #expect(lifted.carbsFloorG == quiet.carbsFloorG)
        #expect(lifted.drivingSession == nil)

        // The tier follows the run's real length: past the long threshold it is a long session,
        // and a jog under the hour leaves the floor where an easy day sits.
        let long = Workout()
        long.type = .run
        long.durationS = FuelingGuide.highCarbFromS
        long.startedAt = now.addingTimeInterval(-3 * 3600)
        let jog = Workout()
        jog.type = .run
        jog.durationS = 1800
        jog.startedAt = run.startedAt
        context.insert(long); context.insert(jog)
        try context.save()
        let longDay = FuelReadoutBuilder.readout(meals: [], plan: nil, workouts: [long], profile: profile,
                                                 water: [], now: now)
        #expect(longDay.carbsFloorG == Int((FuelReadiness.carbsPerKgLong * 70).rounded()))
        #expect(longDay.drivingSession?.contains("long session") == true)
        let jogDay = FuelReadoutBuilder.readout(meals: [], plan: nil, workouts: [jog], profile: profile,
                                                water: [], now: now)
        #expect(jogDay.carbsFloorG == quiet.carbsFloorG)
        #expect(jogDay.drivingSession == nil)
    }
}
