import Foundation

/// The ONE switch for every community-facing surface: the Profile ↔ Community slider, the globe's
/// athlete dots, the save screens' visibility row, and the publish sweep. Nothing community-shaped
/// may gate itself on anything else — one flag, in one place, is what lets the launch be a
/// decision instead of a scavenger hunt.
///
/// **ON since 2026-07-29** (owner call: the next update ships WITH the community page). DEBUG can
/// rehearse the solo app with `--no-community` — the gate-leak check that proves no community
/// surface renders when the flag is off.
enum CommunityAccess {
    static var enabled: Bool {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--no-community")
        #else
        true
        #endif
    }
}
