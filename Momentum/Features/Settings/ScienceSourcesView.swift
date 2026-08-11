import SwiftUI

/// The sports-science bibliography (App Review 1.4.1: apps with health/medical calculations must
/// cite their sources, and the citations must be easy to find). Every deterministic engine that
/// encodes published science is listed here with its source, and each row links straight to it.
/// Reached from Settings → Data & Privacy → "Science & sources" and the Settings colophon.
struct ScienceSourcesView: View {
    @Environment(\.openURL) private var openURL

    private struct Source: Identifiable {
        var id: String { title }
        let title: String    // what momentum computes
        let citation: String // the published source
        let url: String
    }

    private struct Group: Identifiable {
        var id: String { heading }
        let heading: String
        let sources: [Source]
    }

    private let groups: [Group] = [
        Group(heading: "TRAINING PACES & PLAN", sources: [
            Source(title: "Training paces & race equivalence (VDOT)",
                   citation: "Daniels J. Daniels' Running Formula, 4th ed. Human Kinetics, 2021.",
                   url: "https://us.humankinetics.com/products/daniels-running-formula-4th-edition"),
            Source(title: "Weekly volume ramp guardrail (acute:chronic workload)",
                   citation: "Gabbett TJ. The training–injury prevention paradox. Br J Sports Med. 2016;50:273–280.",
                   url: "https://pubmed.ncbi.nlm.nih.gov/26758673/"),
            Source(title: "Session training load (RPE × duration)",
                   citation: "Foster C, et al. A new approach to monitoring exercise training. J Strength Cond Res. 2001;15(1):109–115.",
                   url: "https://pubmed.ncbi.nlm.nih.gov/11708692/"),
            Source(title: "Fitness · Fatigue · Form (CTL / ATL / TSB)",
                   citation: "Banister EW. Modeling elite athletic performance. In: Physiological Testing of the High-Performance Athlete. Human Kinetics, 1991.",
                   url: "https://www.trainingpeaks.com/learn/articles/the-science-of-the-performance-manager/"),
        ]),
        Group(heading: "HEART RATE & RECOVERY", sources: [
            Source(title: "Heart-rate zones from heart-rate reserve",
                   citation: "Karvonen MJ, Kentala E, Mustala O. The effects of training on heart rate. Ann Med Exp Biol Fenn. 1957;35(3):307–315.",
                   url: "https://pubmed.ncbi.nlm.nih.gov/13470504/"),
            Source(title: "HRV & resting heart rate as recovery signals",
                   citation: "Plews DJ, et al. Training adaptation and heart rate variability in elite endurance athletes. Sports Med. 2013;43(9):773–781.",
                   url: "https://pubmed.ncbi.nlm.nih.gov/23852425/"),
            Source(title: "Sleep & athletic performance",
                   citation: "Walsh NP, et al. Sleep and the athlete: narrative review and 2021 expert consensus recommendations. Br J Sports Med. 2021;55:356–368.",
                   url: "https://pubmed.ncbi.nlm.nih.gov/33144349/"),
        ]),
        Group(heading: "RUNNING METRICS", sources: [
            Source(title: "Grade-adjusted pace",
                   citation: "Minetti AE, et al. Energy cost of walking and running at extreme uphill and downhill slopes. J Appl Physiol. 2002;93(3):1039–1046.",
                   url: "https://pubmed.ncbi.nlm.nih.gov/12183501/"),
            Source(title: "Calorie estimate — energy cost of running",
                   citation: "Margaria R, et al. Energy cost of running. J Appl Physiol. 1963;18:367–370.",
                   url: "https://pubmed.ncbi.nlm.nih.gov/13932993/"),
            Source(title: "Calorie estimate — MET values for other sports",
                   citation: "Ainsworth BE, et al. 2011 Compendium of Physical Activities. Med Sci Sports Exerc. 2011;43(8):1575–1581.",
                   url: "https://pubmed.ncbi.nlm.nih.gov/21681120/"),
        ]),
        Group(heading: "FUELING", sources: [
            Source(title: "Carbohydrate during long sessions (30–90 g/h)",
                   citation: "Jeukendrup A. A step towards personalized sports nutrition: carbohydrate intake during exercise. Sports Med. 2014;44(S1):25–33.",
                   url: "https://pubmed.ncbi.nlm.nih.gov/24791914/"),
            Source(title: "Daily energy, carbohydrate & protein floors",
                   citation: "Thomas DT, Erdman KA, Burke LM. Position of the Academy of Nutrition and Dietetics, Dietitians of Canada, and the American College of Sports Medicine: Nutrition and Athletic Performance. Med Sci Sports Exerc. 2016;48(3):543–568.",
                   url: "https://pubmed.ncbi.nlm.nih.gov/26891166/"),
            Source(title: "Fluid & sodium replacement",
                   citation: "Sawka MN, et al. American College of Sports Medicine position stand: Exercise and fluid replacement. Med Sci Sports Exerc. 2007;39(2):377–390.",
                   url: "https://pubmed.ncbi.nlm.nih.gov/17277604/"),
        ]),
        Group(heading: "STRENGTH", sources: [
            Source(title: "Estimated one-rep max (Epley)",
                   citation: "Epley B. Poundage Chart. Boyd Epley Workout. Lincoln, NE, 1985. Accuracy reviewed in Reynolds JM, et al. J Strength Cond Res. 2006;20(3):584–592.",
                   url: "https://pubmed.ncbi.nlm.nih.gov/16937961/"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                Text("Every number momentum computes — paces, zones, loads, fueling floors — comes from published sports science, encoded as plain deterministic rules. These are the sources.")
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(groups) { group in
                    section(group)
                }
                Text("momentum offers general training and fueling guidance. It is not a medical device and never provides medical advice or a diagnosis. Talk to a physician before starting a new training program, and about anything that feels like more than training fatigue.")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl)
        }
        .background(Theme.background)
        .navigationTitle("Science & sources")
        .navigationBarTitleDisplayMode(.large)
    }

    private func section(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(group.heading)
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.leading, Theme.Space.md)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(group.sources.enumerated()), id: \.element.id) { i, source in
                    if i > 0 {
                        Divider().overlay(Theme.hairline)
                    }
                    row(source)
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)
            }
        }
    }

    private func row(_ source: Source) -> some View {
        Button {
            if let url = URL(string: source.url) { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title)
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                    Text(source.citation)
                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.top, 4)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the source in your browser")
    }
}

#Preview {
    NavigationStack { ScienceSourcesView() }
}
