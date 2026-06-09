import UIKit

/// Centralized haptics (PRD §6.2). Semantic names map to the per-interaction spec so call
/// sites read intent, not mechanism. CoreHaptics-based custom patterns (milestone, PR) can
/// replace the impl later without changing callers.
@MainActor
enum Haptics {
    /// Button press, set logged.
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    /// Rest-timer completion.
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    /// Selection cards.
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    /// Start a cardio activity (soft success).
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    /// Cardio milestone (distinct). Placeholder until a CoreHaptics pattern is authored.
    static func milestone() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    /// PR celebration. Placeholder until a CoreHaptics pattern is authored.
    static func celebration() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
