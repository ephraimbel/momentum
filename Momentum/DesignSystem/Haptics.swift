import UIKit

/// Centralized haptics (PRD §6.2). Semantic names map to the per-interaction spec so call
/// sites read intent, not mechanism. CoreHaptics-based custom patterns (milestone, PR) can
/// replace the impl later without changing callers.
///
/// Generators are shared and re-`prepare()`d after every fire: allocating a cold generator per
/// call meant the Taptic Engine was asleep for exactly the taps that matter most (the first
/// press on a screen), so the buzz trailed the touch by a beat.
@MainActor
enum Haptics {
    private static let lightGen = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private static let rigidGen = UIImpactFeedbackGenerator(style: .rigid)
    private static let selectionGen = UISelectionFeedbackGenerator()
    private static let notifyGen = UINotificationFeedbackGenerator()

    /// Button press, set logged.
    static func light() { lightGen.impactOccurred(); lightGen.prepare() }
    /// Rest-timer completion.
    static func medium() { mediumGen.impactOccurred(); mediumGen.prepare() }
    /// Selection cards.
    static func selection() { selectionGen.selectionChanged(); selectionGen.prepare() }
    /// Start a cardio activity (soft success).
    static func success() { notifyGen.notificationOccurred(.success); notifyGen.prepare() }
    /// Cardio milestone (distinct). Placeholder until a CoreHaptics pattern is authored.
    static func milestone() { rigidGen.impactOccurred(); rigidGen.prepare() }
    /// PR celebration. Placeholder until a CoreHaptics pattern is authored.
    static func celebration() { notifyGen.notificationOccurred(.success); notifyGen.prepare() }

    /// Wake the Taptic Engine ahead of a run of imminent haptics (a countdown, a save beat) so
    /// the very first one lands with the frame it belongs to instead of a beat behind it.
    static func warm() {
        lightGen.prepare(); mediumGen.prepare(); notifyGen.prepare()
    }
}
