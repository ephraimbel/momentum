import SwiftData

/// SwiftUI can evaluate an old ForEach closure after the session was removed and saved.
/// Check lifecycle metadata before faulting any persisted property (MOMENTUM-IOS-R).
@MainActor
enum PlanSessionPresentation {
    static func isLive(_ session: PlannedSession) -> Bool {
        !session.isDeleted && session.modelContext != nil
    }

    static func neighbor(_ session: PlannedSession) -> RestDayLine.Neighbor {
        guard isLive(session) else { return .none }
        if session.discipline == .strength { return .strength }
        guard let kind = session.runType else { return .easy }
        if kind == .race { return .race }
        if kind == .long { return .long }
        return kind.isQuality ? .quality : .easy
    }
}
