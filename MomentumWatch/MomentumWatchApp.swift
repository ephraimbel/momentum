import SwiftUI

/// The watchOS app (PRD §8.10 / §4.10) — on-wrist GPS cardio and strength logging, the serious-user
/// unlock. Dark/true-black by design (OLED + battery, PRD §13.1), with iridescence reserved for live
/// progress. Phone sync layers on in a later slice (WatchConnectivity).
@main
struct MomentumWatchApp: App {
    var body: some Scene {
        WindowGroup { WatchRootView() }
    }
}
