import SwiftUI

/// A plan, made legible before it exists or after it is over (docs/PLAN-AND-FUEL-UPGRADE.md §2.2):
/// what it is for, the honest outlook, the commitment in numbers, a typical week, and the phases.
/// Read-only; the caller supplies the actions that belong to where it was opened from (the shelf,
/// the builder). Numbers come from `PlanPreview`, which is built from the same generator output
/// an activation persists, so nothing shown here can differ from the plan.
struct PlanReviewView<Actions: View>: View {
    let title: String
    let status: PlanShelfStatus?
    let blueprint: PlanBlueprint
    let preview: PlanPreview?
    let distanceUnit: DistanceUnit
    @ViewBuilder let actions: () -> Actions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    header
                    PlanPreviewContent(blueprint: blueprint, preview: preview, distanceUnit: distanceUnit)
                    VStack(spacing: Theme.Space.sm) { actions() }
                        .padding(.top, Theme.Space.sm)
                }
                .padding(Theme.Space.lg)
                .padding(.bottom, Theme.Space.xxl)
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("preview").font(.display(20, weight: .bold)).foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
        }
        .presentationDetents([.large])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Space.sm) {
                Text(title)
                    .font(.display(Theme.FontSize.headline, weight: .heavy)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let status {
                    Text(status.label)
                        .font(.rounded(Theme.FontSize.label, weight: .bold)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().stroke(Theme.hairline))
                }
            }
            Text(blueprint.goalLine())
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            if let preview {
                let f = Date.FormatStyle().day().month(.abbreviated).year()
                Text("\(preview.startDate.formatted(f)) to \(preview.endDate.formatted(f)) · \(preview.durationLine)")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

}

/// The preview's cards on their own, so the shelf's review sheet and the builder's last step draw
/// the same commitment from the same numbers.
struct PlanPreviewContent: View {
    let blueprint: PlanBlueprint
    let preview: PlanPreview?
    let distanceUnit: DistanceUnit

    var body: some View {
        if let preview {
            if let outlook = preview.outlook { outlookCard(outlook) }
            commitmentCard(preview)
            if !preview.typicalWeek.isEmpty { typicalWeekCard(preview) }
            if !preview.phases.isEmpty { phasesCard(preview) }
        } else {
            Text("No preview yet. Open the plan to see the week it builds.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
        }
    }

    private func outlookCard(_ outlook: PlanPreview.Outlook) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("OUTLOOK").font(.rounded(10, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            Text(outlook.headline)
                .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(outlook.detail)
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let finish = outlook.realisticFinishS, outlook.isTooShort {
                Text("A realistic finish by race day is about \(PlanFeasibility.hms(finish)).")
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !outlook.options.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(outlook.options.enumerated()), id: \.offset) { index, option in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).").font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                            Text(option).font(.rounded(Theme.FontSize.caption, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(Theme.ink)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func commitmentCard(_ preview: PlanPreview) -> some View {
        let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("THE COMMITMENT").font(.rounded(10, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.md) {
                stat("Runs a week", "\(preview.runsPerWeek)")
                if preview.liftsPerWeek > 0 { stat("Strength a week", "\(preview.liftsPerWeek)") }
                if preview.weeklyTimeS > 0 { stat("Time a week", Formatters.compactDuration(s: preview.weeklyTimeS)) }
                if preview.peakWeekM > 0 {
                    stat("Peak week", Formatters.distance(meters: preview.peakWeekM, unit: distanceUnit),
                         note: "week \(preview.peakWeekNumber) of \(preview.weeks)")
                }
                if preview.longestRunM > 0 {
                    stat("Longest run", Formatters.distance(meters: preview.longestRunM, unit: distanceUnit))
                }
                if let done = preview.completedSessions {
                    stat("Sessions done", "\(done) of \(preview.plannedSessions)")
                } else {
                    stat("Sessions", "\(preview.plannedSessions)")
                }
                if preview.crossTrainingPerWeek > 0 {
                    stat("Cross-training a week", "\(preview.crossTrainingPerWeek)", note: "tracked, not prescribed")
                }
            }
            if preview.firstWeekM > 0, preview.peakWeekM > preview.firstWeekM {
                Text("From \(Formatters.distance(meters: preview.firstWeekM, unit: distanceUnit)) in week 1 to \(Formatters.distance(meters: preview.peakWeekM, unit: distanceUnit)) at the peak. These are planned targets. Your recovery and logged training guide adjustments.")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).monospacedDigit().foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func stat(_ label: String, _ value: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.display(Theme.FontSize.headline, weight: .bold)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label).font(.rounded(Theme.FontSize.label, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
            if let note {
                Text(note).font(.rounded(Theme.FontSize.label, weight: .medium)).monospacedDigit().foregroundStyle(Theme.inkTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func typicalWeekCard(_ preview: PlanPreview) -> some View {
        let symbols = Calendar.current.shortWeekdaySymbols
        let byDay = Dictionary(grouping: preview.typicalWeek, by: \.weekday)
        // Monday-first, the way the Plan board reads.
        let order = [2, 3, 4, 5, 6, 7, 1]
        return VStack(alignment: .leading, spacing: 0) {
            Text("A TYPICAL WEEK").font(.rounded(10, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
                .padding(.bottom, Theme.Space.sm)
            ForEach(order, id: \.self) { weekday in
                HStack(alignment: .top, spacing: Theme.Space.md) {
                    Text(symbols[(weekday - 1) % 7].uppercased())
                        .font(.rounded(Theme.FontSize.label, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                        .frame(width: 36, alignment: .leading)
                    if let days = byDay[weekday], !days.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                                // Title and detail on one line while they fit; stacked otherwise.
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 6) { dayTitle(day); dayDetail(day) }
                                    VStack(alignment: .leading, spacing: 1) { dayTitle(day); dayDetail(day) }
                                }
                            }
                        }
                    } else {
                        Text("Rest").font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
                if weekday != order.last { Divider().overlay(Theme.hairline) }
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func phasesCard(_ preview: PlanPreview) -> some View {
        let total = max(1, preview.phases.reduce(0) { $0 + $1.weeks })
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("PHASES").font(.rounded(10, weight: .bold)).tracking(1.4).foregroundStyle(Theme.inkTertiary)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    // Positional ids: a plan of eight or more weeks repeats "recovery · 1 wk".
                    ForEach(Array(preview.phases.enumerated()), id: \.offset) { _, span in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(fill(for: span.phase))
                            .frame(width: max(3, geo.size.width * CGFloat(span.weeks) / CGFloat(total) - 2))
                    }
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            FlowLayout(spacing: Theme.Space.sm) {
                ForEach(Array(preview.phases.enumerated()), id: \.offset) { _, span in
                    HStack(spacing: 5) {
                        Circle().fill(fill(for: span.phase)).frame(width: 7, height: 7)
                        Text("\(span.phase.label) · \(span.weeks == 1 ? "1 wk" : "\(span.weeks) wks")")
                            .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityLabel(preview.phases.map { "\($0.phase.label) \($0.weeks) weeks" }.joined(separator: ", "))
    }

    /// Monochrome by phase depth: a plan preview is not an achievement, so no iridescence here.
    private func fill(for phase: PlanPhase) -> Color {
        switch phase {
        case .base: Theme.ink.opacity(0.35)
        case .build: Theme.ink.opacity(0.6)
        case .peak: Theme.ink
        case .recovery: Theme.ink.opacity(0.18)
        case .taper: Theme.ink.opacity(0.45)
        }
    }

    private func dayTitle(_ day: PlanPreview.Day) -> some View {
        Text(day.title)
            .font(.rounded(Theme.FontSize.caption, weight: day.isLong || day.isQuality ? .bold : .semibold))
            .foregroundStyle(Theme.ink)
    }

    @ViewBuilder
    private func dayDetail(_ day: PlanPreview.Day) -> some View {
        if let detail = day.detail {
            Text(detail)
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
        }
    }
}
