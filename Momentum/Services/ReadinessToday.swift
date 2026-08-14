import Foundation
import HealthKit

/// The ONE construction of today's readiness number — the full blend the Health hub shows
/// (banded HRV/resting-HR baselines, learned sleep need + 14-day debt, the check-in), extracted
/// so every surface computes the same score from the same recipe. The Today deck used to run a
/// light blend (no baselines, default 8 h sleep need, zero debt) and could read 91 where the hub
/// read 75 — one recipe, one number, on every surface, always.
@MainActor
enum ReadinessToday {

    /// Pure assembly from pre-fetched inputs. The hub calls this with the histories it already
    /// loaded for its charts; `compute` fetches and then calls it for surfaces without their own
    /// Health reads. Any change to the recipe lands on every surface at once.
    static func build(workouts: [Workout],
                      checkins: [DailyCheckin],
                      signals: RecoverySignals,
                      hrvHist: [(day: Date, value: Double)],
                      rhrHist: [(day: Date, value: Double)],
                      nights: [SleepReport.Night],
                      now: Date = Date(),
                      calendar: Calendar = .current) -> MorningReadiness? {
        let hrvBase = HealthBaselines.build(from: hrvHist, windowDays: HealthBaselines.Window.hrv,
                                            now: now, calendar: calendar)
        let rhrBase = HealthBaselines.build(from: rhrHist, windowDays: HealthBaselines.Window.restingHR,
                                            now: now, calendar: calendar)
        // Learned need + running 14-day debt (defaults when no nights) — the hub's sleepContext.
        let ctx: (need: Double, debt: Double) =
            SleepReport.build(from: nights, now: now, calendar: calendar)
                .map { ($0.needH, $0.debt14H) } ?? (8.0, 0)
        return MorningReadiness(load: RecoveryModel(workouts: workouts, now: now, calendar: calendar),
                                signals: signals,
                                hrvBaseline: hrvBase,
                                restingHRBaseline: rhrBase,
                                sleepNeedH: ctx.need,
                                sleepDebt14H: ctx.debt,
                                checkin: DailyCheckin.today(in: checkins, calendar: calendar, now: now))
    }

    /// Fetch-and-build for surfaces without their own Health reads (the Today deck, the Trends
    /// strip). A stubbed `HealthServing` (previews, tests) degrades to signals-only — the same
    /// graceful degradation the hub has, through the same recipe.
    static func compute(health: any HealthServing,
                        workouts: [Workout],
                        checkins: [DailyCheckin],
                        now: Date = Date(),
                        calendar: Calendar = .current) async -> MorningReadiness? {
        let signals = await health.recoverySignals()
        var hrvHist: [(day: Date, value: Double)] = []
        var rhrHist: [(day: Date, value: Double)] = []
        var nights: [SleepReport.Night] = []
        if let concrete = health as? HealthService {
            let bpm = HKUnit.count().unitDivided(by: .minute())
            hrvHist = await concrete.hrvDailyHistory(days: HealthBaselines.Window.hrv)
            rhrHist = await concrete.dailyHistory(.restingHeartRate, unit: bpm,
                                                  days: HealthBaselines.Window.restingHR)
            nights = await concrete.sleepNights(days: 60).map {
                SleepReport.Night(date: $0.date, asleepH: $0.asleepH, coreS: $0.coreS,
                                  deepS: $0.deepS, remS: $0.remS, awakeS: $0.awakeS, inBedS: $0.inBedS)
            }
        }
        return build(workouts: workouts, checkins: checkins, signals: signals,
                     hrvHist: hrvHist, rhrHist: rhrHist, nights: nights,
                     now: now, calendar: calendar)
    }

    /// Publish today's number for the sibling surfaces (`ReadinessTodayCache` — the strip's
    /// cache-first read), so whichever surface computed most recently is what everyone shows.
    /// The wrist counts as a sibling surface: every publish also schedules a WatchConnectivity
    /// push, so the watch's ring and complications carry this same number.
    static func publish(_ r: MorningReadiness) {
        // The confidence qualifier travels WITH the driver line. A score built from a check-in and
        // load alone must not read like a full HRV + sleep + resting-HR morning on any surface that
        // shows it — and the wrist is one of those surfaces (owner ask 2026-08-14).
        ReadinessTodayCache.store(score: r.score, band: r.band.rawValue,
                                  driver: r.displayDriverWithConfidence)
        PhoneWatchSync.shared.scheduleRefresh()
    }
}
