import Testing
import Foundation
import SwiftData
@testable import Momentum

/// The estimator's contract with the function (2026-09-07): the text-only request is unchanged, a
/// photo rides as base64 under one key, a not-food answer is a rejection and never numbers, and a
/// hand-set meal is never overwritten by whatever comes back later.
@MainActor
struct FuelEstimatorTests {

    private func decode(_ estimateJSON: String) throws -> FuelEstimator.Estimate {
        try JSONDecoder().decode(FuelEstimator.Estimate.self, from: Data(estimateJSON.utf8))
    }

    private let banana = """
    {"name":"Banana","qty":1,"unit":"banana","kcal":105,"carbs_g":27,"protein_g":1,"fat_g":0,"sodium_mg":1,"fluids_ml":0,\
    "potassium_mg":422,"magnesium_mg":null,"iron_mg":0.3,"calcium_mg":6,"fiber_g":3,"sugar_g":14,"satfat_g":0,"nova":1}
    """

    @Test func aTextOnlyRequestCarriesNoImageKey() throws {
        let body = FuelEstimator.requestBody(text: "2 eggs", imageJPEG: nil, sessionLabel: "tomorrow's long run", durationS: nil)
        let json = try #require(String(data: JSONEncoder().encode(body), encoding: .utf8))
        #expect(json.contains("\"text\":\"2 eggs\""))
        #expect(json.contains("\"session\":\"tomorrow's long run\""))
        #expect(!json.contains("image"))
    }

    @Test func aPhotoRequestCarriesTheJPEGAsBase64UnderOneKey() throws {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let body = FuelEstimator.requestBody(text: "", imageJPEG: bytes, sessionLabel: nil, durationS: nil)
        let data = try JSONEncoder().encode(body)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let image = try #require(object["image"] as? [String: Any])
        #expect(image["mime"] as? String == "image/jpeg")
        #expect(image["base64"] as? String == bytes.base64EncodedString())
        #expect(object["text"] as? String == "")
    }

    @Test func aNotFoodAnswerIsARejectionNeverAnEstimate() throws {
        let estimate = try decode(#"{"items":[],"confidence":0,"tags":[],"note":"A desk.","reason":"not_food"}"#)
        guard case .rejected(let reason) = FuelEstimator.outcome(for: estimate) else {
            Issue.record("expected a rejection"); return
        }
        #expect(reason == "not_food")
        #expect(FuelEstimator.rejectionLine(reason).contains("doesn't look like a meal"))
        #expect(!FuelEstimator.isValid(estimate))
    }

    @Test func anEmptyAnswerWithoutAReasonIsDeclined() throws {
        let estimate = try decode(#"{"items":[],"confidence":0.4,"tags":[],"note":""}"#)
        guard case .declined = FuelEstimator.outcome(for: estimate) else { Issue.record("expected declined"); return }
    }

    @Test func theDeployedTextOnlyShapeStillDecodesAndEstimates() throws {
        let estimate = try decode(#"{"items":[\#(banana)],"confidence":0.8,"tags":["light"],"note":"Good pre-run."}"#)
        #expect(estimate.reason == nil)
        guard case .estimated(let e) = FuelEstimator.outcome(for: estimate) else { Issue.record("expected estimate"); return }
        #expect(e.items.first?.magnesium_mg == nil)   // unknown stays unknown
        #expect(e.items.first?.potassium_mg == 422)
    }

    @Test func aManualMealIsNeverOverwrittenByALateEstimate() throws {
        let schema = Schema(PersistenceController.models)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        let meal = Meal()
        meal.text = "my bowl"
        meal.nutrition = NutritionValues(values: [.kcal: 610, .carbs: 80, .protein: 25, .fat: 18])
        meal.source = "manual"
        ctx.insert(meal); try ctx.save()
        let estimate = try decode(#"{"items":[\#(banana)],"confidence":0.8,"tags":[],"note":"Late."}"#)
        FuelEstimator.apply(estimate, to: meal)
        #expect(meal.kcal == 610)
        #expect(meal.source == "manual")
        #expect(meal.items.isEmpty)
        #expect(!meal.isEstimable)
    }

    @Test func aMalformedItemRejectsTheWholeResponse() throws {
        let bad = banana.replacingOccurrences(of: "\"kcal\":105", with: "\"kcal\":-5")
        let estimate = try decode(#"{"items":[\#(banana),\#(bad)],"confidence":0.8,"tags":[],"note":""}"#)
        #expect(!FuelEstimator.isValid(estimate))
        guard case .declined = FuelEstimator.outcome(for: estimate) else { Issue.record("expected declined"); return }
    }
}
