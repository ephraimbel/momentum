import Foundation
import WatchKit

/// The wrist's haptic vocabulary — momentum's sonic logo, felt. One pattern per meaning, used
/// consistently everywhere, so a runner learns to read the watch without looking:
///
///   go          one firm start tap                (session begins)
///   split       two light taps                    (auto-lap / manual lap)
///   inBand      one soft confirm                  (pace settled back into the target band)
///   easeOff     slow double-pulse                 (drifting hot — settle down)
///   pickUp      rising double                     (drifting slow — lift)
///   surge       rising triple                     (fastest lap so far — you're flying)
///   done        the success chord                 (workout saved)
///   tick        countdown metronome               (3·2·1, rest-timer endgame)
///
/// Sequenced taps are spaced by real sleeps — WatchKit has no composer, so rhythm IS the pattern.
/// Keep this the ONLY place that calls `WKInterfaceDevice.play` for meaning-bearing moments.
enum WatchHaptics {
    static func go()    { WKInterfaceDevice.current().play(.start) }
    static func tick()  { WKInterfaceDevice.current().play(.directionUp) }
    static func done()  { WKInterfaceDevice.current().play(.success) }

    static func split() {
        Task { @MainActor in
            WKInterfaceDevice.current().play(.click)
            try? await Task.sleep(for: .milliseconds(140))
            WKInterfaceDevice.current().play(.click)
        }
    }

    static func inBand() { WKInterfaceDevice.current().play(.click) }

    static func easeOff() {
        Task { @MainActor in
            WKInterfaceDevice.current().play(.directionDown)
            try? await Task.sleep(for: .milliseconds(320))
            WKInterfaceDevice.current().play(.directionDown)
        }
    }

    static func pickUp() {
        Task { @MainActor in
            WKInterfaceDevice.current().play(.click)
            try? await Task.sleep(for: .milliseconds(180))
            WKInterfaceDevice.current().play(.directionUp)
        }
    }

    static func surge() {
        Task { @MainActor in
            WKInterfaceDevice.current().play(.click)
            try? await Task.sleep(for: .milliseconds(150))
            WKInterfaceDevice.current().play(.directionUp)
            try? await Task.sleep(for: .milliseconds(150))
            WKInterfaceDevice.current().play(.success)
        }
    }
}
