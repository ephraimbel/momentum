import SwiftUI
import SwiftData

/// "Something hurts" — the athlete tells the coach where and how bad, and the plan responds on the
/// spot (ENDURANCE-FOCUS §8.2). Three beats in one sheet: area → severity → what we changed (with the
/// red flags said plainly). Never a diagnosis; never shame.
struct InjuryReportSheet: View {
    let profile: UserProfile?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var area: InjuryArea?
    @State private var severity: InjurySeverity?
    @State private var outcome: InjuryResponse.Outcome?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if let outcome {
                        outcomeView(outcome)
                    } else {
                        Text("Where does it hurt?")
                            .font(.serif(28, weight: .semibold)).foregroundStyle(Theme.ink)
                        areaGrid
                        if area != nil {
                            Text("How bad is it?")
                                .font(.serif(22, weight: .semibold)).foregroundStyle(Theme.ink)
                                .padding(.top, Theme.Space.xs)
                            severityCards
                        }
                    }
                }
                .padding(Theme.Space.lg)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background)
            .navigationTitle(outcome == nil ? "Report an issue" : "Plan adjusted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if outcome == nil { Button("Cancel") { dismiss() } }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if outcome != nil {
                    OversizedButton(title: "Got it") { dismiss() }
                        .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm)
                        .background(Theme.background)
                } else if let area, let severity {
                    OversizedButton(title: "Adjust my plan") {
                        guard let profile else { dismiss(); return }
                        withAnimation(Motion.standard) {
                            outcome = InjuryResponse.report(area: area, severity: severity,
                                                            profile: profile, in: context)
                        }
                        Haptics.success()   // the plan adjusted — same beat as the check-in's Done
                    }
                    .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm)
                    .background(Theme.background)
                }
            }
        }
    }

    private var areaGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.sm), GridItem(.flexible())],
                  spacing: Theme.Space.sm) {
            ForEach(InjuryArea.allCases) { a in
                let on = area == a
                Button {
                    Haptics.selection()
                    withAnimation(Motion.lively) { area = a }
                } label: {
                    Text(a.label)
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .foregroundStyle(on ? .white : Theme.ink)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background {
                            Capsule().fill(on ? AnyShapeStyle(Theme.purple) : AnyShapeStyle(Theme.surface))
                            if !on { Capsule().stroke(Theme.hairline) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var severityCards: some View {
        VStack(spacing: Theme.Space.sm) {
            ForEach(InjurySeverity.allCases) { s in
                SelectionCard(title: s.label, subtitle: s.subtitle, isSelected: severity == s) {
                    withAnimation(Motion.lively) { severity = s }
                }
            }
        }
    }

    private func outcomeView(_ o: InjuryResponse.Outcome) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(o.headline).font(.serif(27, weight: .semibold)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(o.detail).font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // The straight talk — general management + when to see a professional. Not a diagnosis.
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                // Calm monochrome, not brand lavender — see TodayView.injuryBanner.
                Image(systemName: "stethoscope").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                    .frame(width: 32, height: 32).background(Circle().fill(Theme.surface))
                Text(o.guidance).font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.md)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
            Text("Injuries happen to every runner — this protects your season, not just your week. Tell us when you're feeling better and we'll ease you back in.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
