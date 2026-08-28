import SwiftUI

/// "What your coach can do" — the quiet disclosure behind the chat's info button. States the
/// coach's full capability surface AND its boundaries in plain words, so trust never rests on
/// guesswork: it reads your data, it proposes changes you confirm, it never computes its own
/// numbers, and everything it applies can be undone.
struct CoachCapabilitiesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    header

                    section("GROUNDED IN YOUR DATA", items: [
                        ("chart.line.uptrend.xyaxis", "How you're trending",
                         "Training load, pace at effort, streaks, records — every answer comes from your actual numbers, never a guess."),
                        ("waveform.path.ecg", "Recovery and readiness",
                         "Reads your load balance and recovery signals and tells you honestly when to push and when to absorb."),
                        ("sparkles", "Your plan, explained",
                         "Ask why your plan looks the way it does and it walks you through every choice, from your own data."),
                    ])

                    section("CHANGES YOUR PLAN — WITH YOUR CONSENT", items: [
                        ("wand.and.stars", "Tune the load",
                         "Ease a brutal week, raise it when you've earned more, or ease target paces so sessions land right."),
                        ("arrow.left.arrow.right", "Reshape the schedule",
                         "Move or clear sessions, change your training days, session length, or equipment."),
                        ("flag.checkered", "Point at a new goal",
                         "Change your goal or race and the plan rebuilds around it, with an honest read on whether the timeline works."),
                        ("bandage.fill", "Train around pain",
                         "Tell it something hurts and the plan protects the area, keeps your fitness, and gates the way back."),
                        ("pause.fill", "Pause for life",
                         "Travel or illness shifts everything later and picks up where you left off."),
                    ])

                    section("THE GROUND RULES", items: [
                        ("checkmark.shield", "Nothing happens silently",
                         "Every change is shown as a card with the exact difference. You tap Apply, or you don't."),
                        ("arrow.uturn.left", "Everything is reversible",
                         "Applied a change and regret it? Undo restores your plan exactly, from the receipt."),
                        ("function", "The engine owns the numbers",
                         "Loads, paces, and volumes come from deterministic training rules. The coach explains them; it never invents them."),
                        ("calendar.badge.exclamationmark", "One structural change a week",
                         "Adaptation stays honest — the coach declines a second reshape and tells you why."),
                        ("cross.case", "Never medical advice",
                         "Guidance from your data only. Sharp pain, swelling, or numbness means a professional, and it will say so."),
                        ("iphone", "On your device",
                         "Answers are computed from your training data right on your iPhone — instant, private, and they work with no signal at all."),
                        ("lock.fill", "Your conversation stays yours",
                         "The chat thread and everything the coach remembers about you live on this device. Clear the thread or forget any note, anytime."),
                    ])
                }
                .padding(Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxl)
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Your coach").font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            BrandMark(size: 44)
            Text("A coach that knows your training")
                .font(.display(24, weight: .black)).foregroundStyle(Theme.ink)
            Text("Ask anything, change anything — always previewed, always yours to confirm, always reversible.")
                .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section(_ title: String, items: [(icon: String, title: String, detail: String)]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title)
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                .foregroundStyle(Theme.inkTertiary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .top, spacing: Theme.Space.md) {
                        Image(systemName: item.icon)
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Theme.background))
                            .overlay(Circle().stroke(Theme.hairline))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                            Text(item.detail)
                                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Theme.Space.md)
                    if i < items.count - 1 {
                        Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, Theme.Space.md + 34 + Theme.Space.md)
                    }
                }
            }
            .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }
}
