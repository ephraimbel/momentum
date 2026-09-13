#if DEBUG
import Foundation
import os

/// DEBUG-only main-thread hang meter (2026-09-12, the responsiveness pass). Armed by the
/// `--community-perf` launch argument alongside `CommunityPerf`. A background thread pings the main
/// queue every 16 ms and logs every stall over `threshold` with its length and the wall-clock time
/// it ended, so a hitch can be lined up against the UI test's own tap log
/// (`log stream --predicate 'subsystem == "com.momentum.perf"'`).
///
/// A tap that "feels slow" is almost always one of these: the touch was delivered, and the main
/// thread then spent 80–300 ms doing something synchronous before the frame that answered it.
/// Nothing here ships — the whole file is compiled out of Release.
enum MainThreadWatchdog {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--community-perf")
    private static let log = Logger(subsystem: "com.momentum.perf", category: "hang")
    private static let threshold: TimeInterval = 0.05
    nonisolated(unsafe) private static var started = false

    static func startIfRequested() {
        guard enabled, !started else { return }
        started = true
        let thread = Thread {
            let stamp = DateFormatter()
            stamp.dateFormat = "HH:mm:ss.SSS"
            while true {
                let sent = CFAbsoluteTimeGetCurrent()
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let waited = CFAbsoluteTimeGetCurrent() - sent
                if waited > threshold {
                    log.notice("HANG \(Int(waited * 1000), privacy: .public)ms ended \(stamp.string(from: Date()), privacy: .public)")
                }
                Thread.sleep(forTimeInterval: 0.016)
            }
        }
        thread.name = "momentum.perf.watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
#endif
