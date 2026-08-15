import Testing
import Foundation
@testable import Momentum

/// Connecting Apple Health means "understand me from here", never "ingest my life".
///
/// The regression this pins: the first automatic sweep read a year back, so a new athlete on a
/// well-used phone pulled five figures of mirrored Watch/Garmin/Strava rows on their first visit to
/// Today — on the main actor — and the app was unusable until it finished. The start line is the
/// floor on every import path, and no caller may reach behind it.
struct HealthImportStartLineTests {

    private func defaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: "startline.\(name).\(UUID().uuidString)")!
        HealthService.resetDedupe(defaults: d)
        return d
    }

    private let connectedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - The stamp

    @Test func startLineIsStampedOnce() {
        let d = defaults("once")
        HealthService.markImportStartLine(now: connectedAt, defaults: d)
        #expect(HealthService.importStartLine(defaults: d) == connectedAt)

        // A later call must not move it — re-authorizing, or a new build running the same code,
        // cannot re-open the back catalogue.
        HealthService.markImportStartLine(now: connectedAt.addingTimeInterval(90 * 86_400), defaults: d)
        #expect(HealthService.importStartLine(defaults: d) == connectedAt)
    }

    @Test func noStartLineBeforeConnecting() {
        #expect(HealthService.importStartLine(defaults: defaults("virgin")) == nil)
    }

    @Test func wipeClearsTheStartLineSoItRestampsLater() {
        let d = defaults("wipe")
        HealthService.markImportStartLine(now: connectedAt, defaults: d)
        HealthService.resetDedupe(defaults: d)
        #expect(HealthService.importStartLine(defaults: d) == nil)
    }

    // MARK: - The floor

    @Test func aYearAgoIsClampedToTheStartLine() {
        let aYearBack = connectedAt.addingTimeInterval(-365 * 86_400)
        #expect(HealthService.effectiveCutoff(requested: aYearBack, startLine: connectedAt) == connectedAt)
    }

    @Test func theThreeDayResyncOverlapCannotReachBehindTheStartLine() {
        // The incremental sweep deliberately re-reads a few days so a late-syncing Garmin isn't
        // missed. On the pass right after connecting, that window points into the past — and must
        // still be clamped, or the overlap quietly becomes a back door to the whole catalogue.
        let overlapReach = connectedAt.addingTimeInterval(-HealthService.autoImportOverlapS)
        #expect(HealthService.effectiveCutoff(requested: overlapReach, startLine: connectedAt) == connectedAt)
    }

    @Test func windowsAfterTheStartLineAreLeftAlone() {
        // Steady state: an incremental sweep asking for "since yesterday" is already inside the
        // permitted range and must not be widened back to the connection moment.
        let yesterday = connectedAt.addingTimeInterval(30 * 86_400)
        #expect(HealthService.effectiveCutoff(requested: yesterday, startLine: connectedAt) == yesterday)
    }

    @Test func anUnboundedRequestIsBoundedByTheStartLine() {
        // `since: nil` is what the explicit Settings button passes. Even a deliberate user action
        // does not reach behind the connection moment.
        #expect(HealthService.effectiveCutoff(requested: nil, startLine: connectedAt) == connectedAt)
    }

    @Test func withoutAStartLineTheRequestStandsUnchanged() {
        let requested = connectedAt.addingTimeInterval(-10 * 86_400)
        #expect(HealthService.effectiveCutoff(requested: requested, startLine: nil) == requested)
        #expect(HealthService.effectiveCutoff(requested: nil, startLine: nil) == nil)
    }

    // MARK: - The cap

    /// Even inside the permitted window the pass is bounded, so a multi-source athlete whose
    /// devices all mirror the same sessions can't produce an unbounded batch.
    @Test func importIsCappedPerPass() {
        #expect(HealthService.maxImportPerPass > 0)
        #expect(HealthService.maxImportPerPass <= 500)
    }
}
