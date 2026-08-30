import Foundation
import SwiftData
import WatchConnectivity

/// The phone half of the wrist sync (Watch Slice 4, revived): pushes a compact picture — today's
/// readiness, today's open session, the next race — as `applicationContext` (latest-wins, arrives
/// even if the watch app is closed), and receives the watch's morning check-in, saving it through
/// the same `DailyCheckin` the phone sheet writes and recomputing readiness through the ONE
/// recipe (`ReadinessToday`). Push is debounced; everything here is best-effort — sync failing
/// must never touch app behavior.
@MainActor
final class PhoneWatchSync: NSObject {
    static let shared = PhoneWatchSync()

    /// Set at app start (the Services-owned instance) so check-in recomputes can run the full
    /// readiness recipe. nil in tests/previews — receive still saves, recompute quietly skips.
    var health: (any HealthServing)?
    /// The paywall, for the one gate the wrist can't decide for itself: the voice coach is Pro
    /// (PRD §4.10) and the watch has no receipt of its own. nil ⇒ the wrist stays silent, which is
    /// the honest default for a watch that has never heard from its phone.
    var paywall: (any PaywallServing)?

    private var activated = false
    private var pushTask: Task<Void, Never>?

    func activate() {
        guard !activated, WCSession.isSupported() else { return }
        activated = true
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Debounced context push — called after readiness publishes (ReadinessToday), and safe to
    /// call from anywhere a plan/session change lands.
    func scheduleRefresh() {
        guard activated else { return }
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self.push()
        }
    }

    private static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }

    private func push() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled
        else { return }

        var context: [String: Any] = [:]
        // The wrist's voice-coach gate, decided here because both halves of it live on the phone:
        // the Pro entitlement and the Settings switch. Pushed on every refresh so muting on the
        // phone silences the watch on the next sync rather than at the next install.
        context["voiceCoach"] = (paywall?.isEntitled(to: .voiceCoach) ?? false)
            && (UserDefaults.standard.object(forKey: VoiceCoachService.storageKey) as? Bool ?? true)
        if let r = ReadinessTodayCache.today() {
            context["readinessScore"] = r.score
            context["readinessBand"] = r.band
            context["readinessDriver"] = r.driver
            context["readinessDayKey"] = Self.dayKey()
        }

        let ctx = PersistenceController.shared.container.mainContext
        let profiles = (try? ctx.fetch(FetchDescriptor<UserProfile>())) ?? []
        if let plan = profiles.first?.plan {
            let cal = Calendar.current
            if let s = plan.sessions.first(where: {
                cal.isDateInToday($0.date) && $0.completedWorkout == nil
                    && ($0.status == .planned || $0.status == .moved)
            }) {
                let unit = DistanceUnit.auto.resolved()
                context["sessionTitle"] = Self.title(for: s)
                context["sessionDetail"] = Self.detail(for: s, unit: unit)
                context["sessionTypeRaw"] = (s.workoutType?.rawValue)
                    ?? (s.discipline == .strength ? WorkoutType.strength.rawValue
                        : s.discipline == .cycling ? WorkoutType.ride.rawValue
                        : s.discipline == .walking ? WorkoutType.walk.rawValue
                        : WorkoutType.run.rawValue)
                context["sessionDayKey"] = Self.dayKey()
                // The wrist's pace halo band: the prescription ± honest tolerance (a touch more
                // room on the slow side — drifting easy is cheaper than drifting hot).
                if s.discipline == .running, let pace = s.targetPaceSPerKm, pace > 0 {
                    context["sessionPaceLo"] = pace * 0.94
                    context["sessionPaceHi"] = pace * 1.07
                }
                // The two numbers the wrist's voice coach needs to say anything at all about a
                // plain planned run: the day's distance ("8 miles today") and the pace to hold.
                // Without them the watch could only ever call bare splits.
                if let m = s.targetDistanceM, m > 0 { context["sessionTargetM"] = m }
                if let pace = s.targetPaceSPerKm, pace > 0, s.discipline != .strength {
                    context["sessionTargetPace"] = pace
                }
                // A quality session's guided structure, whole: the watch runs the same step
                // tracker the phone does, so the wrist can coach reps without the phone along.
                if s.discipline == .running,
                   let structured = StructuredWorkoutBuilder.build(from: s, p5kSPerKm: plan.p5kSPerKm,
                                                                   raceDistanceM: profiles.first?.raceDistanceM),
                   let steps = try? JSONEncoder().encode(structured) {
                    context["sessionSteps"] = steps
                }
            } else {
                context["sessionCleared"] = true
            }
            if let raceDate = plan.raceDate,
               raceDate >= cal.startOfDay(for: Date()) {
                context["raceName"] = plan.name.isEmpty ? "Race day" : plan.name
                context["raceDateKey"] = Self.dayKey(raceDate)
            } else {
                context["raceCleared"] = true
            }
        }

        guard !context.isEmpty else { return }
        try? session.updateApplicationContext(context)
    }

    private static func title(for s: PlannedSession) -> String {
        if s.discipline == .strength { return "Strength" }
        // One vocabulary, phone and watch (2026-08-28) — `RunType.planTitle`.
        if let rt = s.runType, rt != .freeRun { return rt.planTitle }
        return s.discipline == .cycling ? "Ride" : "Run"
    }

    private static func detail(for s: PlannedSession, unit: DistanceUnit) -> String {
        // Running sessions speak the same headline every phone surface does — a structured
        // session's SHAPE ("10 × 400m @ 8:24 /mi"), a plain run's distance and pace. One
        // formatter, so the wrist and the phone can never describe the day differently.
        if s.discipline == .running {
            let brief = PlanCoaching.brief(for: s, distanceUnit: unit, dropLeadingType: true)
            if !brief.isEmpty { return brief }
        }
        var parts: [String] = []
        if let m = s.targetDistanceM, m > 0 { parts.append(Formatters.distance(meters: m, unit: unit)) }
        if let pace = s.targetPaceSPerKm, pace > 0, s.discipline == .running {
            parts.append("~" + Formatters.pace(secPerKm: pace, unit: unit))
        }
        if parts.isEmpty, let d = s.targetDurationS, d > 0 { parts.append(Formatters.duration(s: d)) }
        return parts.joined(separator: " · ")
    }

    /// The watch's check-in answers: save (deduped — first answer of the day wins, same as the
    /// phone sheet), then recompute readiness through the one recipe and push the fresh number
    /// back to the wrist.
    fileprivate func receiveCheckin(energyRaw: String, legsRaw: String) {
        let ctx = PersistenceController.shared.container.mainContext
        let checkins = (try? ctx.fetch(FetchDescriptor<DailyCheckin>())) ?? []
        if DailyCheckin.today(in: checkins) == nil {
            let checkin = DailyCheckin(energy: .init(rawValue: energyRaw) ?? .ok,
                                       legs: .init(rawValue: legsRaw) ?? .ok)
            ctx.insert(checkin)
            try? ctx.save()
        }
        guard let health else { scheduleRefresh(); return }
        Task {
            let workouts = (try? ctx.fetch(FetchDescriptor<Workout>())) ?? []
            let fresh = (try? ctx.fetch(FetchDescriptor<DailyCheckin>())) ?? []
            if let r = await ReadinessToday.compute(health: health, workouts: workouts, checkins: fresh) {
                ReadinessToday.publish(r)   // cache + (via publish) the push back to the wrist
            } else {
                self.scheduleRefresh()
            }
        }
    }
}

extension PhoneWatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.scheduleRefresh() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()   // multi-watch hand-off: re-activate for the new pairing
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo["kind"] as? String == "checkin" else { return }
        let energy = userInfo["energy"] as? String ?? "ok"
        let legs = userInfo["legs"] as? String ?? "ok"
        Task { @MainActor in
            self.receiveCheckin(energyRaw: energy, legsRaw: legs)
        }
    }
}
