import SwiftUI

// The History segment's furniture (2026-08-28 refinement pass, the paywall's level of finish):
// a summary card that says something the list below can't, a sport filter that stays out of the
// way until it's useful, sticky month headers, and one row treatment for every sport.

// MARK: - This month

/// The page's opening statement: how far this month, how that compares with last month, and the
/// three facts that complete the picture. Deliberately NOT a repeat of the month header below it
/// (the current month's header drops its summary line for exactly this reason) — the comparison,
/// the moving time and the PR count are all new information.
struct HistorySummaryCard: View {
    let digest: HistoryDigest
    let title: String
    var distanceUnit: DistanceUnit = .auto
    var animate: Bool = true

    private var hasDistance: Bool { digest.meters > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.4)
                    .foregroundStyle(Theme.inkTertiary)
                Spacer(minLength: Theme.Space.sm)
                if let delta = digest.distanceDeltaFraction, abs(delta) >= 0.01 { deltaChip(delta) }
            }
            headline
            factsRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .raised(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Distance leads when there is any; a strength-only month leads with its sessions instead of
    /// printing a proud "0 mi".
    @ViewBuilder private var headline: some View {
        let far = Formatters.wholeDistance(meters: digest.meters, unit: distanceUnit)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(String(hasDistance ? far.value : digest.sessions))
                .font(.display(38, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(hasDistance ? far.unit : (digest.sessions == 1 ? "session" : "sessions"))
                .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.inkTertiary)
        }
    }

    private var factsRow: some View {
        var facts: [String] = []
        if hasDistance { facts.append("\(digest.sessions) session\(digest.sessions == 1 ? "" : "s")") }
        if digest.seconds > 0 { facts.append(Formatters.compactDuration(s: digest.seconds)) }
        if digest.prs > 0 { facts.append("\(digest.prs) PR\(digest.prs == 1 ? "" : "s")") }
        return HStack(spacing: 6) {
            ForEach(Array(facts.enumerated()), id: \.offset) { i, fact in
                if i > 0 {
                    Text("·").font(.rounded(Theme.FontSize.caption, weight: .bold)).foregroundStyle(Theme.inkTertiary)
                }
                Text(fact)
                    .font(.rounded(Theme.FontSize.caption, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
            }
            if facts.isEmpty {
                Text("Nothing logged yet this month")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.8)
    }

    /// Up is green, down is quiet grey — never red. A down month is a taper, an illness, a life;
    /// the no-shame rule (CLAUDE.md) applies to the numbers too.
    private func deltaChip(_ delta: Double) -> some View {
        let up = delta >= 0
        return HStack(spacing: 2) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 9, weight: .black))
            Text("\(Int((abs(delta) * 100).rounded()))%")
                .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
        }
        .foregroundStyle(up ? MetricColor.positive : Theme.inkTertiary)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill((up ? MetricColor.positive : Theme.inkTertiary).opacity(0.12)))
        .accessibilityLabel(up ? "Up \(Int((abs(delta) * 100).rounded())) percent on last month"
                               : "Down \(Int((abs(delta) * 100).rounded())) percent on last month")
    }
}

// MARK: - Sport filter

/// The sport chips. Wraps (the vertical-only rule — never a horizontal scroller), shows a count
/// beside each sport, and hides itself entirely for a single-sport athlete.
struct HistoryFilterChips: View {
    let options: [(filter: HistoryFilter, count: Int)]
    @Binding var selection: HistoryFilter

    var body: some View {
        if options.count > 2 {
            FlowLayout(spacing: Theme.Space.sm) {
                ForEach(options, id: \.filter.id) { option in
                    chip(option.filter, option.count)
                }
            }
        }
    }

    private func chip(_ filter: HistoryFilter, _ count: Int) -> some View {
        let on = selection == filter
        return Button {
            guard !on else { return }
            Haptics.selection()
            withAnimation(.smooth(duration: 0.28)) { selection = filter }
        } label: {
            HStack(spacing: 5) {
                Text(filter.title)
                    .font(.rounded(Theme.FontSize.caption, weight: .bold))
                Text("\(count)")
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).monospacedDigit()
                    // `Theme.background`, never a literal white: `Theme.ink` inverts in dark
                    // mode, so white-on-ink rendered white-on-near-white there (unreadable).
                    .foregroundStyle(on ? Theme.background.opacity(0.65) : Theme.inkTertiary)
            }
            .foregroundStyle(on ? Theme.background : Theme.ink)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background {
                if on { Capsule().fill(Theme.ink) }
                else { Capsule().fill(Theme.surface).overlay(Capsule().stroke(Theme.hairline)) }
            }
        }
        .buttonStyle(PressableScaleStyle(scale: 0.96))
        .accessibilityLabel("\(filter.title), \(count) session\(count == 1 ? "" : "s")")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Month header

/// A sticky month divider. The current month drops its summary (the card above already said it);
/// every other month carries what it came to, PRs included.
struct HistoryMonthHeader: View {
    let title: String
    let summary: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text(title.uppercased())
                .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                .foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: Theme.Space.sm)
            if let summary {
                Text(summary)
                    .font(.rounded(Theme.FontSize.label, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, Theme.Space.xs)
        .padding(.vertical, 6)
        // Sticky headers scroll OVER the rows below them, so the strip must be opaque — a
        // translucent header let route thumbnails smear through it.
        .background(Theme.background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(summary ?? "")
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Row

/// One logged session. The same shape for every sport: a media tile, what it was, when it was,
/// and the numbers that matter — the first one in ink because it's the one you came to read.
struct HistoryRow: View {
    let title: String
    let subtitle: String
    let stats: [String]
    let isPR: Bool
    let thumb: AnyView

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            thumb
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.xs) {
                    Text(title)
                        .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if isPR {
                        Text("PR")
                            .font(.rounded(9, weight: .black)).tracking(0.4).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(IridescentMaterial()).opacity(0.85))
                    }
                }
                Text(subtitle)
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1)
                if !stats.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(stats.enumerated()), id: \.offset) { i, s in
                            if i > 0 {
                                Text("·").font(.rounded(Theme.FontSize.caption, weight: .bold))
                                    .foregroundStyle(Theme.inkTertiary)
                            }
                            Text(s)
                                .font(.rounded(Theme.FontSize.caption, weight: i == 0 ? .bold : .semibold))
                                .monospacedDigit()
                                .foregroundStyle(i == 0 ? Theme.ink : Theme.inkSecondary)
                        }
                    }
                    .padding(.top, 2)
                    .lineLimit(1).minimumScaleFactor(0.85)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.inkTertiary.opacity(0.7))
        }
        .padding(.vertical, Theme.Space.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(subtitle). \(stats.joined(separator: ", "))\(isPR ? ". Personal record." : "")")
        .accessibilityAddTraits(.isButton)
    }
}
