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
    /// `--seed-follows-active` follows a large deterministic slice of the community instead (~an
    /// eighth of the directory) — the "established account" look for screenshot runs.
    static func seededFollows() -> Set<String> {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--seed-follows-active") {
            let all = CommunityDirectory.all().map(\.handle)
            return Set(all.enumerated().compactMap { i, h in i.isMultiple(of: 8) ? h : nil })
        }
        guard args.contains("--seed-follows") else { return [] }
        return ["mayaruns", "coachtheo", "joonw973"]
    }
    #endif
}
