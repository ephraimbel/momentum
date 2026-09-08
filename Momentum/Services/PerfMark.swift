import Foundation
import os

/// Tap-to-screen timing for the flows we promise are fast (2026-09-07). DEBUG builds write one
/// line per flow to the unified log (subsystem `app.momentum.perf`), read back on the simulator
/// with `log show --predicate 'subsystem == "app.momentum.perf"'`. A release build compiles the
/// calls to nothing: no logging, no dictionary, no cost.
enum PerfMark {
    #if DEBUG
    private static let log = Logger(subsystem: "app.momentum.perf", category: "flow")
    @MainActor private static var starts: [String: Date] = [:]
    #endif

    /// The moment of the tap (or the state change that stands in for it).
    @MainActor static func start(_ name: String) {
        #if DEBUG
        starts[name] = Date()
        #endif
    }

    /// The answer is on screen (call from the destination's `onAppear`, or after the state it
    /// draws is set). `afterRender` waits one runloop turn so the commit that draws it counts.
    @MainActor static func end(_ name: String, afterRender: Bool = true) {
        #if DEBUG
        guard starts[name] != nil else { return }
        if afterRender {
            DispatchQueue.main.async { end(name, afterRender: false) }
            return
        }
        guard let t0 = starts.removeValue(forKey: name) else { return }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        log.notice("⏱ \(name, privacy: .public) \(ms, privacy: .public) ms")
        #endif
    }
}
