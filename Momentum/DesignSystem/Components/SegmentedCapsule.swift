import SwiftUI

/// The house segmented control — ONE capsule language for every "pick a window / pick a view"
/// switcher in the app.
///
/// Before this existed the Progress family shipped three of them: the page bar (ink-filled pill,
/// hairline track), the trend range picker (ink-filled pill, no track stroke), and Balance's
/// 7D/30D (surface-filled pill, ink text) — three different answers to the same question, often
/// visible in the same scroll. One control, one answer.
///
/// The selection is a single pill carried between segments by `matchedGeometryEffect`, so a tap
/// reads as the pill *moving* rather than one capsule blinking off and another on — the detail
/// that separates a native-feeling control from a styled button row. Transform-only (§ animate
/// transforms, never layout); under Reduce Motion the pill simply appears in its new home.
///
/// Accessibility is built in rather than remembered per call site: every segment is a button with
/// the `.isSelected` trait, so VoiceOver announces which window is active — the page bar used to
/// expose none of that.
struct SegmentedCapsule<Value: Hashable>: View {
    /// Page-width bar (Trends · Health · History) vs the compact window pickers (1W · 1M · 3M).
    enum Scale {
        case page, compact

        var height: CGFloat? { self == .page ? 32 : nil }
        var trackPadding: CGFloat { self == .page ? 3 : 2 }
        var itemSpacing: CGFloat { self == .page ? 3 : 2 }
        var horizontalPadding: CGFloat { self == .page ? 0 : 9 }
        var verticalPadding: CGFloat { self == .page ? 0 : 4 }
        var fills: Bool { self == .page }
    }

    let items: [Value]
    @Binding var selection: Value
    var scale: Scale = .page
    /// The visible text for a segment.
    let title: (Value) -> String
    /// A spoken label when the visible text is an abbreviation ("1M" → "Last month").
    var spokenLabel: ((Value) -> String)? = nil
    /// Runs after the selection commits — for side effects the caller owns (clearing a pinned
    /// scrub point, re-windowing a cache). Never for the selection itself.
    var onChange: ((Value) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill

    var body: some View {
        HStack(spacing: scale.itemSpacing) {
            ForEach(items, id: \.self) { item in
                segment(item)
            }
        }
        .padding(scale.trackPadding)
        .background {
            Capsule().fill(Theme.surface)
            Capsule().stroke(Theme.hairline)
        }
    }

    private func segment(_ item: Value) -> some View {
        let on = item == selection
        return Button {
            guard !on else { return }
            Haptics.selection()
            withAnimation(reduceMotion ? nil : Motion.reversible) { selection = item }
            onChange?(item)
        } label: {
            Text(title(item))
                .font(.rounded(Theme.FontSize.caption, weight: .bold)).monospacedDigit()
                .lineLimit(1).fixedSize(horizontal: scale == .compact, vertical: false)
                .foregroundStyle(on ? .white : Theme.inkSecondary)
                .padding(.horizontal, scale.horizontalPadding)
                .padding(.vertical, scale.verticalPadding)
                .frame(maxWidth: scale.fills ? .infinity : nil)
                .frame(height: scale.height)
                .background {
                    // One pill, carried between segments — the selected cell owns it and the
                    // namespace slides it. Every other cell draws nothing.
                    if on {
                        // Lavender marks selected (rebrand 2026-08-16) — ink pills act, the
                        // brand color says "you are here". White label holds 4.3:1 on #7C63F0
                        // in both appearances (the hex doesn't re-anodize in dark).
                        Capsule().fill(Theme.purple)
                            .matchedGeometryEffect(id: "segmented.pill", in: pill)
                    }
                }
                // Without an explicit shape only the glyphs are hittable on unselected segments —
                // dead tap zones across most of the capsule.
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenLabel?(item) ?? title(item))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Session-scoped entrance

/// Remembers which entrance cascades have already played this app session.
///
/// `reveal(_:)` staggers a section into place with a fade + lift — a welcome. But Progress
/// destroys and rebuilds a whole segment on every Trends → History → Trends flip, so the welcome
/// replayed *every single time*, and a page the athlete visits ten times a day spent a second
/// fading itself in on each visit. An entrance is a greeting, not a toll: it plays once, then the
/// content is simply there.
@MainActor
enum RevealOnce {
    private static var seen: Set<String> = []

    /// True the first time an id is asked about, false forever after (this session).
    static func claim(_ id: String) -> Bool { seen.insert(id).inserted }

    /// Data resets clear the ledger so a fresh start gets its welcome back.
    static func reset() { seen.removeAll() }
}
