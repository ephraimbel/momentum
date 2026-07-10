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
}
