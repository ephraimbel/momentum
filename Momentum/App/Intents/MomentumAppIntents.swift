import AppIntents
import SwiftData

/// "Hey Siri, log a meal in Momentum" → Siri asks "What did you eat?" → the dictation runs the
/// same local resolution ladder as the Fuel composer, saves, Siri speaks the receipt, and a
/// notification receipt (with Undo) lands. Runs in-app in the background — no extension, full
/// SwiftData access, no network dependency (see `SiriMealLogger` for the billing boundary).
///
/// Free-form speech can't live inside the trigger phrase itself (App Shortcut phrases only
/// interpolate fixed-vocabulary parameters), so the two-beat flow — phrase, then dictation —
/// is the canonical Siri pattern for arbitrary text like "2 gels and half a banana".
struct LogMealIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a Meal"
    static let description = IntentDescription(
        "Log food to your Fuel journal by voice — \u{201C}2 gels and a banana\u{201D}.",
        categoryName: "Fuel")
    static let openAppWhenRun = false

    @Parameter(title: "Food", requestValueDialog: "What did you eat?")
    var food: String

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$food) to Fuel")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = food.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw $food.needsValueError("What did you eat?")
        }
        let context = PersistenceController.shared.container.mainContext
        guard let receipt = SiriMealLogger.log(text: text, in: context) else {
            // The write failed — never claim success (the audit rule, spoken).
            return .result(dialog: "I couldn't save that just now — try again, or log it in Momentum.")
        }
        SiriMealLogger.postReceipt(receipt)
        return .result(dialog: IntentDialog("\(receipt.dialog)"))
    }
}

/// Registers the Siri phrases (users can also find "Log a Meal" in the Shortcuts app and
/// Spotlight). Phrases must contain the app name — variety covers how people actually say it.
struct MomentumShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogMealIntent(),
            phrases: [
                "Log a meal in \(.applicationName)",
                "Log food in \(.applicationName)",
                "Log a snack in \(.applicationName)",
                "Log a gel in \(.applicationName)",
                "Track a meal in \(.applicationName)",
                "Add a meal in \(.applicationName)",
                "I ate something in \(.applicationName)",
                "Log my breakfast in \(.applicationName)",
                "Log my lunch in \(.applicationName)",
                "Log my dinner in \(.applicationName)",
            ],
            shortTitle: "Log a Meal",
            systemImageName: "fork.knife")
    }
}
