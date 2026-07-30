import Foundation

/// DEBUG helper so social UI tests start from a clean, independent state. With `--reset-social`,
/// the follow/reaction/moderation stores clear their persisted keys on launch (these are
/// UserDefaults-backed and otherwise persist across test runs, polluting later tests).
enum SocialDebug {
    static func resetIfRequested(_ defaults: UserDefaults, keys: [String]) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--reset-social") else { return }
        for key in keys { defaults.removeObject(forKey: key) }
        #endif
    }

    #if DEBUG
    /// `--seed-follows`: start the run already following a few known community athletes, so the
    /// profile's Following count, the Following list, and the Friends wall can all be verified by
    /// screenshot without driving taps (the real tap path is covered by `FollowFlowUITests`).
    static func seededFollows() -> Set<String> {
        guard ProcessInfo.processInfo.arguments.contains("--seed-follows") else { return [] }
        return ["mayaruns", "coachtheo", "joonw973"]
    }
    #endif
}
