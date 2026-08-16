import SwiftUI
import SwiftData

/// The "life happens" door (enterprise pass 2026-08-15): sick, traveling, or just swamped — one
/// honest tap reshapes the plan instead of letting it silently rot into missed sessions. Sick and
/// travel pause (every future session shifts; the race date never moves), swamped eases the week
/// ~15%. All three are the athlete's own word, so they bypass the weekly adaptation throttle the
/// same way an injury report does — and each keeps a coaching receipt, so the plan explains itself.
struct LifeHappensSheet: View {
    let profile: UserProfile?

    @Environment(\.modelContext) private var context
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss

    private enum Situation: String, CaseIterable, Identifiable {
        case sick, traveling, swamped
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .sick: "thermometer.variable.and.figure"
            case .traveling: "airplane"
            case .swamped: "clock.badge.exclamationmark"
            }
        }
        var title: String {
            switch self {
            case .sick: "I'm sick"
            case .traveling: "Traveling"
            case .swamped: "Swamped this week"
            }
        }
        var subtitle: String {
            switch self {
            case .sick: "Pause 3 days. Everything shifts forward, nothing is lost."
            case .traveling: "Pause while you're away. Your sessions wait for you."
            case .swamped: "Ease this week about 15%. Showing up small still counts."
            }
        }
    }

    @State private var situation: Situation?
    @State private var travelDays = 3

    private var plan: TrainingPlan? { profile?.plan }
    /// An active pause window (today still inside it).
    private var pausedUntil: Date? {
        guard let until = plan?.pausedUntil,
              Calendar.current.startOfDay(for: Date()) < Calendar.current.startOfDay(for: until)
        else { return nil }
        return until
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text("What's going on?")
                        .font(.serif(28, weight: .semibold)).foregroundStyle(Theme.ink)

                    if let until = pausedUntil {
                        pausedCard(until: until)
                    } else {
                        ForEach(Situation.allCases) { s in
                            situationRow(s)
                        }
                        if situation == .traveling { travelDaysRow }
                    }
                }
                .padding(Theme.Space.lg)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background)
            .navigationTitle("Life happens")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                if pausedUntil == nil {
                    OversizedButton(title: confirmTitle, isEnabled: situation != nil) {
                        apply()
                    }
                    .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm)
                    .background(Theme.background)
                }
            }
        }
        .presentationDetents([.height(560), .large])
    }

    private var confirmTitle: String {
        switch situation {
        case .sick: "Pause 3 days"
        case .traveling: "Pause \(travelDays) days"
        case .swamped: "Ease this week"
        case nil: "Adjust my plan"
        }
    }

    private func situationRow(_ s: Situation) -> some View {
        let on = situation == s
        return Button {
            Haptics.selection()
            withAnimation(Motion.lively) { situation = (on ? nil : s) }
        } label: {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: s.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(on ? Theme.background : Theme.ink)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(s.subtitle).font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if on {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.ink)
                }
            }
            .padding(Theme.Space.md)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(on ? Theme.ink : Theme.hairline, lineWidth: on ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(s.title). \(s.subtitle)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var travelDaysRow: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach([3, 5, 7], id: \.self) { d in
                let on = travelDays == d
                Button { Haptics.selection(); travelDays = d } label: {
                    Text("\(d) days")
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(on ? Theme.background : Theme.ink)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                .fill(on ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.surface))
                            if !on { RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).stroke(Theme.hairline) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pause \(d) days")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Already paused: say so plainly and offer the way back — never stack a second pause.
    private func pausedCard(until: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "pause.circle").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Your plan is paused").font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            Text("Training resumes \(until.formatted(.dateTime.weekday(.wide).month().day())). Feeling ready sooner? Your sessions move back up to meet you.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            Button {
                Haptics.success()
                PlanCoaching.resume(plan, from: Date(), in: context)
                CoachingEvent.record(kind: .moved, headline: "Plan resumed early",
                                     detail: "Your sessions moved back up to meet you. Ease into the first one.",
                                     on: Date(), in: context)
                services.notifications.schedulePlannedReminders(plan)
                dismiss()
            } label: {
                Text("Resume today")
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.ink))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Space.md)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface)
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.hairline)
        }
    }

    private func apply() {
        guard let situation else { return }
        Haptics.success()
        let today = Date()
        switch situation {
        case .sick:
            PlanCoaching.pause(plan, days: 3, from: today, in: context)
            CoachingEvent.record(kind: .recover, headline: "Paused 3 days to get well",
                                 detail: "Every session shifted forward and your race date stays put. Come back when you're ready. Nothing is lost.",
                                 on: today, in: context)
        case .traveling:
            PlanCoaching.pause(plan, days: travelDays, from: today, in: context)
            CoachingEvent.record(kind: .moved, headline: "Paused \(travelDays) days for travel",
                                 detail: "Your sessions shifted to meet you when you're back. Safe travels. The plan waits.",
                                 on: today, in: context)
        case .swamped:
            // Records its own .ease receipt inside.
            PlanCoaching.easeWeek(plan, from: today, in: context)
        }
        services.notifications.schedulePlannedReminders(plan)
        dismiss()
    }
}
