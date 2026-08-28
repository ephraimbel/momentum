import SwiftUI

/// What the athlete can change about a card beyond picking a template (2026-08-27, the Share
/// Aura editor grammar in our theme): the words on it, the ink the words are set in, and which
/// layers are on. Composer state only — nothing here is persisted to the workout, so a share is
/// a fresh sheet of paper every time and "Reset" is just `ShareEdits()`.
struct ShareEdits: Equatable {
    /// Headline over the media. Empty = the workout's own title, else its sport.
    var title: String = ""
    /// The small line above the headline (Aura puts the city there). Empty = the workout's date.
    var subtitle: String = ""
    var ink: ShareInk = .white
    var showTitle = true
    var showRoute = true
    var showStats = true
    var showWordmark = true

    /// The headline actually drawn: the athlete's edit, else the workout's name, else its sport.
    func resolvedTitle(for workout: Workout) -> String {
        let t = title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
        let own = workout.title.trimmingCharacters(in: .whitespaces)
        return own.isEmpty ? workout.type.title : own
    }

    func resolvedSubtitle(for workout: Workout) -> String {
        let s = subtitle.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { return s }
        return workout.startedAt.formatted(date: .abbreviated, time: .omitted)
    }
}

/// The three inks a card's type can wear over media. White is the default and the safe one on a
/// photo; ink is for pale skies and snow; lavender is the brand accent, allowed here because a
/// finished workout is earned progress — never a fourth "decoration" color.
enum ShareInk: String, CaseIterable, Identifiable {
    case white, ink, lavender
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .white:    .white
        case .ink:      Theme.inkOnFixedLight
        case .lavender: Theme.proLavender
        }
    }
    /// The route's soft casing under the iridescent core — must contrast the ink, not match it.
    var routeCasing: Color {
        switch self {
        case .white, .lavender: .white.opacity(0.92)
        case .ink:              Theme.inkOnFixedLight.opacity(0.85)
        }
    }
    var next: ShareInk {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
    var label: String {
        switch self { case .white: "White"; case .ink: "Ink"; case .lavender: "Lavender" }
    }
}
