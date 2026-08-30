import Foundation
import SwiftData
import Observation

/// Nudges (2026-08-25): the one outbound social gesture beyond the reaction. Tap a mutual who
/// has no ring today and they get "Maya nudged you" in the bell inbox. Care, not a leaderboard:
/// mutuals only, one per pair per day, no text, never a count anyone can see.
///
/// Local truth for "can I nudge them / did I already": `mutuals` (who follows you back, pulled
/// from the server) and `sentToday`. Seeded community athletes count as mutuals — they are the
/// demo's friends and the server would never know them — and their nudge is local-only.
///
/// **`sentToday` is PERSISTED** (2026-08-29). It used to live only in memory, so the one-per-day
/// rule survived exactly as long as the process did: force-quit, reopen, and the same person
/// could be nudged again — and the pill that had read "Nudged" was back to "Nudge", so the app
/// had visibly forgotten something the athlete did. A gesture whose whole point is restraint
/// cannot be the one that resets on relaunch.
@MainActor @Observable
final class NudgeStore {
    private static let sentKey = "com.momentum.social.nudgesSentToday"
    private static let dayKey = "com.momentum.social.nudgesSentDay"
    private let defaults: UserDefaults

    private(set) var mutuals: Set<String> = []
    private(set) var sentToday: Set<String> = []
    /// The local day `sentToday` belongs to (`StreakCalculator.localDay` — the app's one
    /// day-boundary rule, so a nudge day and a training day roll over together).
    private var sentDay: Int
    weak var backend: (any SocialBackending)?
    private var lastPull: Date = .distantPast
    /// Set when the server refused a send, so the surface can say so instead of quietly undoing
    /// the athlete's tap. Cleared once read.
    private(set) var lastRefusal: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        SocialDebug.resetIfRequested(defaults, keys: [Self.sentKey, Self.dayKey])
        sentDay = defaults.integer(forKey: Self.dayKey)
        sentToday = Set(defaults.stringArray(forKey: Self.sentKey) ?? [])
        rollDay()
    }

    /// Whether the athlete may nudge `handle`: a mutual (or a seeded member), and not yet today.
    func canNudge(_ handle: String, isSample: Bool) -> Bool {
        rollDay()
        guard !sentToday.contains(handle) else { return false }
        return isSample || mutuals.contains(handle)
    }
    func nudgedToday(_ handle: String) -> Bool { rollDay(); return sentToday.contains(handle) }

    /// Send. Optimistic — the pill flips to "Nudged" in the same frame; a refused server write
    /// (not a mutual after all, already sent from another device) rolls it back AND says why,
    /// because an undo with no explanation is indistinguishable from a broken button.
    func nudge(_ handle: String, isSample: Bool, name: String? = nil) {
        rollDay()
        sentToday.insert(handle)
        persist()
        Haptics.success()
        guard !isSample, let backend else { return }
        Task {
            if await !backend.nudge(handle: handle) {
                sentToday.remove(handle)
                persist()
                let who = name ?? "@\(handle)"
                lastRefusal = "Couldn't nudge \(who). You can nudge people who follow you back, once a day."
                ToastCenter.shared.show(icon: "hand.wave", line: lastRefusal ?? "")
            }
        }
    }

    /// Consume the refusal message (so a re-render can't replay it).
    func takeRefusal() -> String? {
        defer { lastRefusal = nil }
        return lastRefusal
    }

    /// Pull who follows back + any unseen nudges, delivering the latter to the inbox. Throttled:
    /// it runs on every community appearance and app foreground.
    func refresh(in context: ModelContext, force: Bool = false) async {
        rollDay()
        guard let backend else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastPull) > 45 else { return }
        lastPull = now
        if let m = await backend.mutualHandles() { mutuals = m }
        guard let incoming = await backend.pullNudges(), !incoming.isEmpty else { return }
        for n in incoming {
            let who = n.fromName.isEmpty ? "@\(n.fromHandle)" : n.fromName
            AppNotification.post(kind: .nudge, title: "\(who) nudged you",
                                 body: "They noticed you haven't moved today. Keep moving.",
                                 on: n.createdAt, in: context,
                                 dedupeToken: "nudge-\(n.id.uuidString)", daily: false)
        }
        Haptics.light()
    }

    private func rollDay() {
        let today = StreakCalculator.localDay(Date())
        guard sentDay != today else { return }
        sentDay = today
        sentToday = []
        persist()
    }

    private func persist() {
        defaults.set(Array(sentToday), forKey: Self.sentKey)
        defaults.set(sentDay, forKey: Self.dayKey)
    }
}

/// One incoming nudge as the server hands it back.
struct NudgeHit: Sendable, Identifiable {
    let id: UUID
    let fromHandle: String
    let fromName: String
    let createdAt: Date
}
