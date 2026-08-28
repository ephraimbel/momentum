import CoreLocation

/// Where Today's map opens (2026-08-28, owner call: "when getting past the onboarding we should
/// open the map on the user's location"). Pure so the decision can be pinned by tests — it used to
/// live inline in `TodayView.onAppear`, where the one case that mattered (a freshly-onboarded
/// athlete who just granted location) silently fell through to the world camera, because Today
/// owned a private `LocationService` that never saw onboarding's grant.
///
/// Order of preference:
///  1. a LIVE fix — the athlete is right there, and after the onboarding location beat we have one;
///  2. their last-known neighbourhood from GPS history — right for a returning athlete offline;
///  3. the puck — authorized but nothing cached yet, so let Mapbox center as the fix lands;
///  4. the neutral "not located yet" camera — never a guessed neighbourhood.
enum TodayMapOpening: Equatable {
    case athlete(CLLocationCoordinate2D)
    case followPuck
    case unlocated

    static func decide(fix: CLLocationCoordinate2D?,
                       history: CLLocationCoordinate2D?,
                       authorized: Bool) -> TodayMapOpening {
        if let coord = fix ?? history { return .athlete(coord) }
        return authorized ? .followPuck : .unlocated
    }
}

extension TodayMapOpening {
    /// Whether this opening still owes the athlete a centre — the map is on the neutral camera and
    /// must take itself to them the moment permission or a fix arrives.
    var awaitsFirstFix: Bool { self == .unlocated }
}
