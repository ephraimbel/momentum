import SwiftUI

/// A personal-record badge. When `celebrate` is set, a holographic sweep crosses the badge once
/// (PRD §6.2 "PR" row) — the earned iridescent moment. Meaning is always carried by the text too
/// (accessibility: iridescence is never the sole signal).
struct PRBadge: View {
    let text: String
    var celebrate: Bool = false

    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "rosette")
            Text(text)
        }
        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, 6)
        .background {
            Capsule().fill(Theme.surface)
            Capsule().stroke(Theme.hairline, lineWidth: 1)
        }
        .overlay {
            if celebrate && !reduceMotion {
                Capsule()
                    .fill(
                        LinearGradient(colors: [.clear] + Theme.iridescent + [.clear],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .opacity(0.7)
                    .mask(Capsule())
                    .offset(x: sweep ? 140 : -140)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(Capsule())
        .onAppear {
            guard celebrate, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.6)) { sweep = true }
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        PRBadge(text: "Bench e1RM PR", celebrate: true)
    }
}
