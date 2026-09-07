import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

/// Moving a session on the Plan board: the drag payload, its lifted preview, and the two target
/// treatments the board wears while a session is in the air.
///
/// The interaction (2026-09-05): press and hold a session, then slide it onto another day. Drop on
/// a **day** and the session moves there; drop on **another session** and the two trade days, which
/// is the move athletes actually ask for ("swap Tuesday's tempo with Thursday's easy"). Before this,
/// moving a session cost four taps and a sheet, and "Move" was not even in the row's context menu.
///
/// Drag is a pointing-device gesture, so it is never the only path: the context menu keeps a Move
/// submenu and every session line carries a VoiceOver "Move to another day" action into the same
/// reschedule surface. Nothing here is required to reschedule a session.
struct PlannedSessionTransfer: Codable, Sendable, Transferable {
    /// `PlannedSession.id` — a stable UUID that survives the round trip through the drag session,
    /// unlike `PersistentIdentifier`. The board resolves it against the live plan on drop, so a
    /// payload naming a session that no longer exists simply does nothing.
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .plannedSession)
    }
}

extension UTType {
    /// The board's own drag type, declared in the app's Info.plist (`UTExportedTypeDeclarations`).
    /// Naming it keeps the drag in-app: a session cannot be dropped into Mail as junk text, and the
    /// board never lights up for a string dragged in from another app.
    static let plannedSession = UTType(exportedAs: "app.momentum.planned-session")
}

/// What the athlete carries while dragging: the session in miniature, on a raised capsule, so the
/// thing under the finger is unmistakably the row that was lifted.
struct PlanSessionDragPreview: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 28, height: 28)
                .background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
            Text(title)
                .font(.rounded(Theme.FontSize.caption, weight: .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .padding(.leading, 6).padding(.trailing, Theme.Space.md)
        .padding(.vertical, 6)
        .raised(Capsule())
    }
}

/// Makes a session row draggable, or leaves it exactly as it was.
///
/// A `ViewModifier` rather than an inline `if`, because `.draggable` changes the view's type and
/// branching on it inside the board's `ForEach` would hand SwiftUI two different rows for the same
/// session. Completed work is not draggable: a finished day is a record of what happened, and
/// dragging it would quietly rewrite history rather than plan anything.
struct DraggableSessionModifier: ViewModifier {
    let session: PlannedSession
    let distanceUnit: DistanceUnit
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.draggable(PlannedSessionTransfer(id: session.id)) {
                PlanSessionDragPreview(icon: PlanCoaching.icon(for: session),
                                       title: PlanCoaching.brief(for: session, distanceUnit: distanceUnit))
            }
        } else {
            content
        }
    }
}

extension View {
    /// A day row that is currently under the finger. Lavender because the rebrand reserves it for
    /// "tappable or happening now", and a live drop target is precisely that.
    @ViewBuilder
    func planDropTarget(_ active: Bool) -> some View {
        overlay {
            if active {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.purple.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.purple.opacity(0.55), lineWidth: 1.5)
                    }
                    .padding(.horizontal, 6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    /// A session row being hovered by another session: these two will trade days. The swap glyph is
    /// the whole explanation, so the athlete never has to guess which of the two drops they are about
    /// to perform.
    @ViewBuilder
    func planSwapTarget(_ active: Bool) -> some View {
        overlay(alignment: .trailing) {
            if active {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.purple, lineWidth: 1.5)
                        .padding(.horizontal, -4)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Theme.background)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.purple))
                        .offset(x: 6)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }
}
