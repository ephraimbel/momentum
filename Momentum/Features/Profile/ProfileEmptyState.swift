import SwiftUI

/// The profile before the first workout — the shape of the page to come, not an apology for an
/// empty one (owner call 2026-08-28). Three parts, in the app's own vocabulary:
///
/// 1. **A ghost grid.** The real 3-up tile geometry (3:4, `ProfileGrid.gutter`) drawn as faint ink
///    and faded out downward — day one already looks like the product, the same reasoning behind
///    the Health hub's specimen charts. It is obviously a placeholder, never mistakeable for data:
///    no numbers, no EXAMPLE badge needed because there is nothing here to misread.
/// 2. **One line that names what happens next**, and the athlete's own planned session when the
///    coach has already written one — a just-onboarded athlete HAS a plan, so "log something" is
///    the wrong ask when we can say what today is.
/// 3. **One primary action.** An ink pill (the CTA law — lavender is never a primary fill) that
///    lands on Today, where Start and Log both live. One door, no dead end.
///
/// Deliberately NOT iridescent: iridescence is earned, and an empty profile has earned nothing
/// yet. It is the one screen in the app where the restraint is the point.
struct ProfileEmptyState: View {
    /// Today's prescription, when the plan has one — its brief rides under the headline.
    var plannedBrief: String?
    /// What the primary button says it will do ("Start run" / "Start workout").
    var startTitle: String = "Start your first workout"
    let onStart: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// Rows of ghost tiles. TWO, not three: the grid is a backdrop, and at three rows (~480pt on
    /// a 6.1") it pushed the headline and the button below the fold — an empty state whose call to
    /// action you have to scroll to find is worse than the flat card it replaced.
    private static let ghostRows = 2

    var body: some View {
        ZStack {
            ghostGrid
            copyBlock
        }
        .frame(maxWidth: .infinity)
        .onAppear { appeared = true }
        .accessibilityElement(children: .contain)
    }

    // MARK: The grid to come

    private var ghostGrid: some View {
        GeometryReader { geo in
            let gutter = ProfileGrid.gutter
            let tile = (geo.size.width - gutter * 2) / 3
            VStack(spacing: gutter) {
                ForEach(0..<Self.ghostRows, id: \.self) { row in
                    HStack(spacing: gutter) {
                        ForEach(0..<3, id: \.self) { col in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Theme.ink.opacity(0.055))
                                .frame(width: tile, height: tile * 4 / 3)
                                .opacity(appeared ? 1 : 0)
                                .scaleEffect(appeared ? 1 : 0.94)
                                .animation(reduceMotion ? nil
                                           : .easeOut(duration: 0.45).delay(0.04 * Double(row * 3 + col)),
                                           value: appeared)
                        }
                    }
                }
            }
            // The grid recedes into the page rather than stopping on a hard edge — the copy sits
            // in the quiet it leaves behind.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                         .init(color: .black.opacity(0.30), location: 0.55),
                                         .init(color: .clear, location: 1.0)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .frame(height: ghostHeight)
        .accessibilityHidden(true)
    }


    /// Three rows of 3:4 tiles at a third of the screen's width, plus the gutters.
    private var ghostHeight: CGFloat {
        let width = UIScreen.main.bounds.width - Theme.Space.md * 2
        let tile = (width - ProfileGrid.gutter * 2) / 3
        return tile * 4 / 3 * CGFloat(Self.ghostRows) + ProfileGrid.gutter * CGFloat(Self.ghostRows - 1)
    }

    // MARK: What happens next

    private var copyBlock: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "figure.run")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Theme.surface))
                .overlay(Circle().stroke(Theme.hairline))
                .reveal(0.10)

            Text("Your story starts here")
                .font(.display(22, weight: .black)).foregroundStyle(Theme.ink)
                .reveal(0.14)

            Text(plannedBrief.map { "Today: \($0). Finish it and your grid, streak, muscle map and records all begin." }
                 ?? "Your first workout fills this grid — and your distance, streak, muscle map and records with it.")
                .font(.rounded(Theme.FontSize.caption, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.md)
                .reveal(0.18)

            OversizedButton(title: startTitle, systemImage: "play.fill", action: onStart)
                .padding(.top, Theme.Space.xs)
                .padding(.horizontal, Theme.Space.lg)
                .reveal(0.22)
        }
        .padding(.vertical, Theme.Space.lg)
        .padding(.horizontal, Theme.Space.md)
    }
}
