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
@MainActor @Observable
final class NudgeStore {
    private(set) var mutuals: Set<String> = []
    private(set) var sentToday: Set<String> = []
    private var sentDay: Date = .distantPast
    weak var backend: (any SocialBackending)?
    private var lastPull: Date = .distantPast

    /// Whether the athlete may nudge `handle`: a mutual (or a seeded member), and not yet today.
    func canNudge(_ handle: String, isSample: Bool) -> Bool {
        rollDay()
        guard !sentToday.contains(handle) else { return false }
        return isSample || mutuals.contains(handle)
    }
    func nudgedToday(_ handle: String) -> Bool { rollDay(); return sentToday.contains(handle) }

    /// Send. Optimistic — the pill flips to "Nudged" in the same frame; a refused server write
    /// (not a mutual after all, already sent from another device) rolls it back quietly.
    func nudge(_ handle: String, isSample: Bool) {
        rollDay()
        sentToday.insert(handle)
        Haptics.success()
        guard !isSample, let backend else { return }
        Task {
            if await !backend.nudge(handle: handle) { sentToday.remove(handle) }
        }
    }

    /// Pull who follows back + any unseen nudges, delivering the latter to the inbox. Throttled:
    /// it runs on every community appearance and app foreground.
    func refresh(in context: ModelContext, force: Bool = false) async {
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
        if !Calendar.current.isDateInToday(sentDay) {
            sentToday = []
            sentDay = Date()
        }
    }
}

/// One incoming nudge as the server hands it back.
struct NudgeHit: Sendable, Identifiable {
    let id: UUID
    let fromHandle: String
    let fromName: String
    let createdAt: Date
}
