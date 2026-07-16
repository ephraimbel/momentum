import SwiftUI

/// Recovery Hub — the shared cold-start pieces (docs/RECOVERY-HUB-PLAN.md §5, empty block).
/// Day one must already look like the product: connecting Health is one elegant row (never a
/// re-nag), zero-data charts render as designed *specimens*, and the education is always one tap
/// away. Calm everywhere — never a warning triangle, never yellow.

// MARK: - Shared card chrome

extension View {
    /// The hub's card chrome — the same surface/hairline pairing as the Progress cards, so the
    /// Health segment reads as one family with Trends.
    func healthCard() -> some View {
        padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.hairline)))
    }
}

// MARK: - ConnectRow (the acquisition hook)

/// One elegant Apple-Health connect affordance: the Health mark, one sentence, one button.
/// Shown once prominently (default), then as a slim footer row (`compact`) — never re-nags (§5).
/// The action is injected; the segment wires it to `HealthService.requestAuthorization()`.
struct ConnectRow: View {
    /// The slim footer variant for after the first prominent showing.
    var compact: Bool = false
    var connecting: Bool = false
    let onConnect: () -> Void

    var body: some View {
        if compact { footerRow } else { prominentCard }
    }

    private var prominentCard: some View {
        HStack(spacing: Theme.Space.md) {
            healthMark
            Text("This page runs on a wearable — Apple Watch, Garmin, Oura, or Whoop — connected through Apple Health. Connect it and your sleep, HRV, and resting heart rate start shaping your readiness automatically.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onConnect) {
                Text(connecting ? "Connecting…" : "Connect")
                    .font(.rounded(Theme.FontSize.caption, weight: .bold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, Theme.Space.sm)
                    .background(Capsule().fill(Theme.ink))
            }
            .buttonStyle(.plain)
            .disabled(connecting)
            .opacity(connecting ? 0.6 : 1)
        }
        .healthCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connect Apple Health")
        .accessibilityHint("Your sleep, HRV, and resting heart rate start shaping your readiness automatically")
    }

    private var footerRow: some View {
        Button(action: onConnect) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.like)
                Text("Connect Apple Health for HRV & sleep-based readiness")
                    .font(.rounded(Theme.FontSize.label, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(connecting)
        .accessibilityLabel("Connect Apple Health")
    }

    /// The Apple Health mark: the white tile + warm heart, drawn native (no bundled asset).
    private var healthMark: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.white)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.hairline))
            .overlay(Image(systemName: "heart.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.like))
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)
    }
}

// MARK: - SpecimenOverlay (designed empty state)

/// Renders chart/card content as a designed specimen: the data ghosts to hairline-gray at 8%,
/// a small-caps EXAMPLE tag sits on top, and one teaching line explains what will live here.
/// "Day one already looks like the product" (§5) — never a blank rectangle.
struct SpecimenOverlay<Content: View>: View {
    let teaching: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ZStack(alignment: .topTrailing) {
                content()
                    .grayscale(1)
                    .opacity(0.08)                 // ghost data — hairline gray, §5
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Text("EXAMPLE")
                    .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.5)
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.surface)
                        .overlay(Capsule().stroke(Theme.hairline)))
            }
            Text(teaching)
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example. \(teaching)")
    }
}

extension View {
    /// Wrap any chart/card body as a cold-start specimen with one teaching line (§5).
    func specimen(_ teaching: String) -> some View {
        SpecimenOverlay(teaching: teaching) { self }
    }
}

// MARK: - Wearable disclaimer

/// The honest hardware disclaimer — always visible at the page's end, whatever the connection
/// state: this page's depth comes from a wearable writing to Apple Health, and without one
/// readiness still works (training load + check-ins), just with less signal. Plain words, no
/// warning triangle — expectation-setting, never an error.
struct WearableFootnote: View {
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Text("Sleep and vitals need a wearable — Apple Watch, Garmin, Oura, or Whoop — connected to Apple Health. Without one, readiness still works from your training load and daily check-ins.")
                .font(.rounded(Theme.FontSize.label, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.sm)
            MetricInfoButton(explainer: MetricExplainers.whereDataComesFrom)
        }
        .padding(.horizontal, Theme.Space.xs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - LearnCard ("How this works")

/// The hub's education anchor — two rows opening the full explainer sheets: how the score is
/// built, and where the data arrives from (Apple Health as the single aggregator). Education is
/// always free (§8).
struct LearnCard: View {
    @State private var presented: MetricExplainer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("How this works")
                .font(.rounded(Theme.FontSize.headline, weight: .bold))
                .foregroundStyle(Theme.ink)
                .padding(.bottom, Theme.Space.sm)
            row("How readiness is scored", icon: "gauge.with.needle",
                explainer: MetricExplainers.readiness)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            row("Where this data comes from", icon: "heart.text.square",
                explainer: MetricExplainers.whereDataComesFrom)
        }
        .healthCard()
        .sheet(item: $presented) { explainer in
            MetricDetailSheet(explainer: explainer)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func row(_ title: String, icon: String, explainer: MetricExplainer) -> some View {
        Button { presented = explainer } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 24)
                Text(title)
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .padding(.vertical, Theme.Space.sm + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the full explanation")
    }
}

// MARK: - Previews

#Preview("Connect + Learn") {
    VStack(spacing: Theme.Space.md) {
        ConnectRow(onConnect: {})
        ConnectRow(compact: true, onConnect: {})
        LearnCard()
        Text("42").font(.display(40)).monospacedDigit()
            .frame(maxWidth: .infinity, minHeight: 80)
            .healthCard()
            .specimen("Your morning readiness will land here after your first night of data.")
    }
    .padding()
    .background(Theme.background)
}
