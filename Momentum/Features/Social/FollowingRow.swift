import SwiftUI

/// The top of the community home (owner call 2026-08-25, the Share Aura structure in our theme):
/// a "Find people" field, then the people you follow as ringed faces — "Your day" first, then
/// everyone who trained in the last 24h, then the rest. The ring IS the presence signal
/// (`PresenceRing`): quiet ink normally, animated iridescence once they have posted. Tapping a ringed face opens their day in
/// the full-bleed pager, so a "story" is just the post seen through a 24h window — no second
/// content type, nothing that expires off the profile grid.
///
/// Wraps with `FlowLayout` (the vertical-only rule, 2026-08-20): never a horizontal scroller.
/// Two rows at most; the overflow collapses into a "+N" face that opens the full following list.
struct FollowingRow: View {
    struct Person: Identifiable {
        let handle: String
        /// The caption under the face — a first name, or "Your day" for the viewer.
        let label: String
        /// The athlete's full name. The AVATAR reads this, never `label`: a monogram built from a
        /// first name ("T") contradicts the same person's monogram everywhere else ("TB"), and
        /// building one from the viewer's caption produced a "YD" face for a photo-less athlete.
        let fullName: String
        let ringed: Bool
        /// Their newest post — orders the row (freshest first), the way a story tray reads.
        var lastActive: Date? = nil
        var avatarData: Data? = nil
        var imageName: String? = nil
        var preset: AvatarPreset? = nil
        var id: String { handle }
    }

    let you: Person
    let people: [Person]
    var onFind: () -> Void
    var onYou: () -> Void
    var onPerson: (Person) -> Void
    var onMore: () -> Void

    /// Blocked athletes never appear here, whatever the host hands over. Blocking now unfollows
    /// too, so this is the second lock rather than the only one — but a face that survived a
    /// block (an older install's data) would be the most visible way for a block to look ignored.
    @Environment(ModerationStore.self) private var moderation

    private let faceSize: CGFloat = 64
    /// 4 faces per row on a 393pt canvas at this size + label width; two rows minus "Your day"
    /// and the overflow face.
    private let maxPeople = 6

    private var visiblePeople: [Person] { people.filter { !moderation.isBlocked($0.handle) } }

    private var shown: [Person] {
        let sorted = visiblePeople.sorted { a, b in
            if a.ringed != b.ringed { return a.ringed }
            return (a.lastActive ?? .distantPast) > (b.lastActive ?? .distantPast)
        }
        return Array(sorted.prefix(maxPeople))
    }
    private var overflow: Int { max(0, visiblePeople.count - maxPeople) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            findField
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Following")
                    .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                FlowLayout(spacing: Theme.Space.md - 2) {
                    face(you, action: onYou)
                    ForEach(shown) { person in
                        face(person) { onPerson(person) }
                    }
                    if overflow > 0 {
                        moreFace
                    } else if visiblePeople.isEmpty {
                        findFace
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
    }

    // MARK: Find people

    /// A capsule that reads as a search field but is a door: the real field lives in the
    /// in-place search face (the same one the header magnifier opens).
    private var findField: some View {
        HStack(spacing: Theme.Space.sm) {
            Button(action: onFind) {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                    Text("Find people")
                        .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    Spacer()
                }
                .padding(.horizontal, Theme.Space.md)
                .frame(height: 44)
                .raised(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Find people")
            Button(action: onFind) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .momentumGlass(in: Circle())
            }
            .buttonStyle(PressableScaleStyle(scale: 0.94))
            .accessibilityLabel("Find athletes to follow")
        }
    }

    // MARK: Faces

    private func face(_ person: Person, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                PresenceRing(active: person.ringed, lineWidth: 2.5, gap: 2.5) {
                    AvatarView(photo: person.avatarData, name: person.fullName, size: faceSize,
                               imageName: person.imageName, preset: person.preset)
                }
                Text(person.label)
                    .font(.rounded(Theme.FontSize.label, weight: .semibold))
                    .foregroundStyle(person.ringed ? Theme.ink : Theme.inkTertiary)
                    .lineLimit(1)
                    // The caption sits in a fixed column so the faces stay on a grid; at the
                    // largest accessibility sizes that clipped the viewer's own "Your day" to
                    // "Your…". Shrink a little before truncating.
                    .minimumScaleFactor(0.75)
                    .frame(width: faceSize + 8)
            }
        }
        .buttonStyle(PressableScaleStyle(scale: 0.95))
        .accessibilityLabel(person.ringed ? "\(person.label), trained today" : person.label)
    }

    private var moreFace: some View {
        Button(action: onMore) {
            VStack(spacing: 6) {
                Text("+\(overflow)")
                    .font(.display(18, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                    .frame(width: faceSize, height: faceSize)
                    .background(Circle().fill(Theme.surface))
                    .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                    .padding(2.5)
                Text("More")
                    .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .buttonStyle(PressableScaleStyle(scale: 0.95))
        .accessibilityLabel(overflow == 1 ? "1 more person you follow"
                                          : "\(overflow) more people you follow")
    }

    /// The empty-follows nudge, in the row itself: one obvious next step, no lecture.
    private var findFace: some View {
        Button(action: onFind) {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                    .frame(width: faceSize, height: faceSize)
                    .background(Circle().fill(Theme.surface))
                    .overlay(Circle().stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .padding(2.5)
                Text("Find")
                    .font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .buttonStyle(PressableScaleStyle(scale: 0.95))
        .accessibilityLabel("Find athletes to follow")
    }
}
