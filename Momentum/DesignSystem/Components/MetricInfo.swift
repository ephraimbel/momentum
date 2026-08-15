import SwiftUI

/// A plain-words explanation of a metric — what it is, how we compute it, and how to read it.
/// The single content type behind every chart's "ⓘ" affordance, so "how we calculate" reads
/// consistently across the whole Progress page. Content lives in `MetricExplainers`.
struct MetricExplainer: Identifiable, Equatable, Sendable {
    let id: String
    let title: String            // "Fitness & Freshness"
    let tagline: String          // one-line summary shown under the title
    /// Optional formula/method, rendered in a monospaced pill (e.g. "e1RM = weight × (1 + reps/30)").
    var formula: String? = nil
    let sections: [Section]      // what it is · how we work it out · how to read it
    var footnote: String? = nil  // e.g. "Not medical advice."
    /// The published basis for the calculation/claim, rendered as a tappable citation at the foot
    /// of the sheet (App Review 1.4.1: citations must live where the health information is shown).
    var source: Source? = nil

    struct Section: Equatable, Sendable {
        let heading: String
        let body: String
    }

    struct Source: Equatable, Sendable {
        let label: String   // "Foster C, et al. J Strength Cond Res. 2001."
        let url: URL

        init(_ label: String, _ urlString: String) {
            self.label = label
            self.url = URL(string: urlString) ?? URL(string: "https://pubmed.ncbi.nlm.nih.gov")!
        }
    }
}

/// The "ⓘ" button that sits in a chart card's corner. Self-contained — owns its own sheet state,
/// so a card just drops it into its header with no plumbing.
struct MetricInfoButton: View {
    let explainer: MetricExplainer
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("How \(explainer.title) is calculated")
        .sheet(isPresented: $showing) {
            MetricDetailSheet(explainer: explainer)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// The tap-to-open detail sheet (Aura-style): the metric explained in full, cleanly. Big title,
/// an optional formula pill, then what-it-is / how-we-work-it-out / how-to-read-it sections that
/// stagger in.
struct MetricDetailSheet: View {
    let explainer: MetricExplainer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(explainer.title)
                            .font(.display(26, weight: .black)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(explainer.tagline)
                            .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let formula = explainer.formula {
                        Text(formula)
                            .font(.system(.footnote, design: .monospaced).weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                .fill(Theme.surface).overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.hairline)))
                    }

                    ForEach(Array(explainer.sections.enumerated()), id: \.offset) { i, section in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(section.heading.uppercased())
                                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                                .foregroundStyle(Theme.inkTertiary)
                            Text(section.body)
                                .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : 8)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.4).delay(0.05 * Double(i)), value: shown)
                    }

                    if let footnote = explainer.footnote {
                        Text(footnote)
                            .font(.rounded(Theme.FontSize.caption, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                            .padding(.top, Theme.Space.xs)
                    }

                    if let source = explainer.source {
                        Link(destination: source.url) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("SOURCE")
                                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                                    .foregroundStyle(Theme.inkTertiary)
                                HStack(alignment: .top, spacing: 5) {
                                    Text(source.label)
                                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                                        .foregroundStyle(Theme.inkSecondary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Theme.inkTertiary)
                                        .padding(.top, 2)
                                }
                            }
                            .padding(Theme.Space.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                .fill(Theme.surface).overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.hairline)))
                        }
                        .accessibilityLabel("Source: \(source.label). Opens in your browser.")
                    }
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold).foregroundStyle(Theme.ink)
                }
            }
        }
        .onAppear { shown = reduceMotion ? true : false; withAnimation { shown = true } }
    }
}
