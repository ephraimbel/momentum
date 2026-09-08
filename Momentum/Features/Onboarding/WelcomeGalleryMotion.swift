import Foundation

/// Analytic, frame-rate-independent motion. A new touch picks up the current pose, never its
/// old target. Coast is bounded; wrapping belongs to the offscreen image path, not an animation.
struct WelcomeGalleryMotion {
    struct Pose {
        var phase: Double
        var horizontal: Double
        var contact: Double
    }

    private var phase = 0.0
    private var horizontal = 0.0
    private var coast = 0.0
    private var releasedAt = -100.0
    private var origin = 0.0
    private var horizontalOrigin = 0.0
    private(set) var isDragging = false

    func pose(at time: Double) -> Pose {
        if isDragging { return Pose(phase: phase, horizontal: horizontal, contact: 1) }
        let elapsed = max(0, time - releasedAt)
        let decay = exp(-elapsed / 0.38)
        return Pose(phase: phase + coast * (1 - decay),
                    horizontal: horizontal * (1 + elapsed * 8) * exp(-elapsed * 8),
                    contact: exp(-elapsed / 0.28))
    }

    mutating func drag(x: Double, y: Double, height: Double, at time: Double) {
        if !isDragging {
            let current = pose(at: time)
            origin = current.phase
            horizontalOrigin = current.horizontal
            isDragging = true
        }
        phase = origin + y / max(1, height) * 0.85
        horizontal = max(-30, min(30, horizontalOrigin + 30 * tanh(x / 110)))
    }

    mutating func release(predictedDeltaY: Double, height: Double, at time: Double) {
        guard isDragging else { return }
        coast = max(-0.16, min(0.16, predictedDeltaY / max(1, height) * 0.45))
        releasedAt = time
        isDragging = false
    }

    mutating func cancel(at time: Double) {
        phase = pose(at: time).phase
        coast = 0
        horizontal = 0
        releasedAt = -100
        isDragging = false
    }

    static func wrappedTravel(_ value: Double) -> Double {
        let period = 1.64
        return ((value.truncatingRemainder(dividingBy: period) + period)
                .truncatingRemainder(dividingBy: period)) - 0.32
    }

    /// Change the photograph at the SAME boundary as wrappedTravel, while the orbit is offscreen.
    /// Adding the visual -0.32 offset to this calculation swaps it early, at the bottom edge.
    static func photoLap(_ value: Double) -> Int { Int(floor(value / 1.64)) }
}

/// Only foreground animation time counts. Uptime cannot jump when the wall clock is corrected.
struct WelcomeAnimationClock {
    private var accumulated = 0.0
    private var started: Double?

    func elapsed(at now: Double = ProcessInfo.processInfo.systemUptime) -> Double {
        accumulated + (started.map { max(0, now - $0) } ?? 0)
    }

    mutating func setRunning(_ running: Bool, at now: Double = ProcessInfo.processInfo.systemUptime) {
        if running {
            if started == nil { started = now }
        } else if started != nil {
            accumulated = elapsed(at: now)
            started = nil
        }
    }
}
