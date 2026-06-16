import Foundation

/// Pure, testable rules for what a social profile exposes (PRD §11, docs/SOCIAL-LAYER.md). Every
/// public-visibility decision routes through here so the conservative defaults can't be bypassed by a
/// call site. The server re-enforces fuzzing/redaction — this is the client-side source of truth.
enum SocialPrivacy {

    /// Normalize a raw display string into a valid @handle: lowercase, keep [a-z0-9_], cap at 20.
    static func normalizedHandle(_ raw: String) -> String {
        let kept = raw.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
        return String(String(String.UnicodeScalarView(kept)).prefix(20))
    }

    /// The visibility applied to a newly-finished workout (the athlete's chosen default).
    static func defaultVisibility(_ profile: UserProfile) -> WorkoutPrivacy {
        WorkoutPrivacy(rawValue: profile.defaultWorkoutVisibility) ?? .private
    }

    /// Whether a workout is visible to anyone beyond its owner (followers or everyone).
    static func isShared(_ workout: Workout) -> Bool {
        workout.privacy == .public || workout.privacy == .friends
    }

    /// A shared workout's route geometry is shown only when shared AND the athlete opted route maps in
    /// (and the server still trims/fuzzes start & end).
    static func showsRoute(_ workout: Workout, profile: UserProfile) -> Bool {
        isShared(workout) && profile.publicRouteMaps
    }

    /// Whether exact numbers (pace, weights) appear on the athlete's public posts.
    static func showsExactNumbers(_ profile: UserProfile) -> Bool {
        profile.showExactNumbers
    }

    /// The location string to show publicly, honoring granularity; nil when hidden or unset.
    static func publicLocation(_ profile: UserProfile) -> String? {
        let granularity = LocationGranularity(rawValue: profile.locationGranularity) ?? .off
        guard granularity != .off else { return nil }
        let trimmed = profile.city.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One-line summary of how exposed the athlete currently is — drives the profile privacy chip.
    static func exposureSummary(_ profile: UserProfile) -> String {
        if defaultVisibility(profile) == .private && !profile.appearOnMap && !profile.discoverable {
            return "Private — nothing is shared"
        }
        var parts: [String] = []
        if defaultVisibility(profile) != .private { parts.append("posts \(defaultVisibility(profile).label.lowercased())") }
        if profile.appearOnMap { parts.append("on the map") }
        if profile.discoverable { parts.append("discoverable") }
        return parts.isEmpty ? "Private — nothing is shared" : parts.joined(separator: " · ").capitalizedFirst
    }
}

private extension String {
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}
