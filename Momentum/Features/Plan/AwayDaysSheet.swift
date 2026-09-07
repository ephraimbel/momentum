import SwiftUI

/// "I'm away these days" — the week-shaped edit (2026-09-05).
///
/// A trip or a bad stretch takes days, not sessions, and the board could only move one session at a
/// time. Pick the days you are out and the week's work rearranges itself around them
/// (`PlanWeekEdit.awayPlacements`): each session moves to the nearest free day, ties going forward,
/// and anything with nowhere to land stays where it is and is named plainly rather than stacked
/// onto a day that is already busy.
///
/// Nothing is deleted here. The sheet only ever moves work, and it says exactly what it did.
struct AwayDaysSheet: View {
    let days: [Date]
    /// Which day indices already hold planned work — those read as the ones worth protecting.
    let daysWithSessions: Set<Int>
    var onApply: (Set<Int>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var away: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        dayRow(index: index, day: day)
                    }
                }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, Theme.Space.xs)
                .padding(.bottom, Theme.Space.xl)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) { applyBar }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("I'm away")
                    .font(.display(30, weight: .black)).foregroundStyle(Theme.ink)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.surface))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            Text("Pick the days you're out. Your sessions move to the nearest free day in the week, and nothing gets doubled up.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.lg)
        .padding(.bottom, Theme.Space.md)
    }

    private func dayRow(index: Int, day: Date) -> some View {
        let isAway = away.contains(index)
        let hasWork = daysWithSessions.contains(index)
        return Button {
            Haptics.selection()
            withAnimation(Motion.selection) {
                if isAway { away.remove(index) } else { away.insert(index) }
            }
        } label: {
            HStack(spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(day.formatted(.dateTime.weekday(.wide)))
                        .font(.rounded(Theme.FontSize.body, weight: .bold))
                        .foregroundStyle(isAway ? Theme.inkTertiary : Theme.ink)
                    Text(hasWork ? day.formatted(.dateTime.month().day()) + " · has a session"
                                 : day.formatted(.dateTime.month().day()) + " · open")
                        .font(.rounded(Theme.FontSize.label, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: isAway ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isAway ? Theme.purple : Theme.inkTertiary.opacity(0.5))
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(isAway ? Theme.purpleTint : Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(isAway ? Theme.purple.opacity(0.3) : Theme.hairline)
        }
        .accessibilityLabel("\(day.formatted(.dateTime.weekday(.wide).month().day())), \(hasWork ? "has a session" : "open")")
        .accessibilityValue(isAway ? "Away" : "Here")
    }

    private var applyBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            OversizedButton(title: away.isEmpty ? "Pick a day" : "Move my week around it",
                            isEnabled: !away.isEmpty) {
                onApply(away)
                dismiss()
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.md)
            .padding(.bottom, Theme.Space.sm)
        }
        .background(Theme.background)
    }
}
