import Foundation

/// Pure, testable rules for what a social profile exposes (PRD §11, docs/SOCIAL-LAYER.md). Every
/// public-visibility decision routes through here so the conservative defaults can't be bypassed by a
/// call site. The server re-enforces fuzzing/redaction — this is the client-side source of truth.
enum SocialPrivacy {

    /// Normalize a raw display string into a valid @handle: diacritic-fold to ASCII (José → jose),
    /// lowercase, keep only [a-z0-9_], cap at 20. Must stay in lockstep with the server's
    /// `profiles_handle_format` constraint (supabase/migrations/…_handle_available.sql) — anything
    /// this produces must pass `^[a-z0-9_]{0,20}$`, or a "valid" handle would fail its claim.
    static func normalizedHandle(_ raw: String) -> String {
        let folded = raw
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let kept = folded.unicodeScalars.filter {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
        }
        return String(String(String.UnicodeScalarView(kept)).prefix(20))
    }

    /// Handles the product owns — never claimable. Byte-identical mirror of the SQL list in
    /// supabase/migrations/…_handle_available.sql (the server enforces; this is instant client UX).
    static let reservedHandles: Set<String> = [
        "momentum", "admin", "administrator", "support", "help", "official", "mod", "moderator",
        "team", "staff", "root", "api", "www", "app", "about", "settings", "profile", "athlete",
        "everyone", "following", "feed",
    ]

    static func isReservedHandle(_ handle: String) -> Bool {
        reservedHandles.contains(handle.lowercased())
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

    /// The granularity that goes with a location the athlete just typed. **Filling the field IS the
    /// opt-in** — Edit Profile offers one optional line, and leaving it blank is how you stay
    /// unplaced; there's no separate switch to forget. Clearing it takes the location back off the
    /// wire entirely (`.off`), and an athlete who once chose the coarser `.region` keeps it.
    static func granularity(forCity city: String, current: String) -> LocationGranularity {
        guard !city.trimmingCharacters(in: .whitespaces).isEmpty else { return .off }
        let existing = LocationGranularity(rawValue: current) ?? .off
        return existing == .off ? .city : existing
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
