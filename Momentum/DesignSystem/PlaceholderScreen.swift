import SwiftUI

/// A calm, on-brand placeholder for screens not yet built (Phase 0 shell).
/// Monochrome base with a single, sparse iridescent accent behind the glyph.
struct PlaceholderScreen: View {
    let title: String
    let symbol: String
    let note: String

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: Theme.Space.lg) {
                ZStack {
                    IridescentView(intensity: 0.45)
                        .frame(width: 96, height: 96)
                        .clipShape(Circle())
                        .opacity(0.9)
                    Image(systemName: symbol)
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(Theme.ink)
                }
                Text(note)
                    .font(.rounded(Theme.FontSize.body, weight: .regular))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.xl)
            }
        }
        .navigationTitle(title)
    }
}

#Preview {
    NavigationStack {
        PlaceholderScreen(title: "Today", symbol: "bolt.heart",
                          note: "Your one calm instruction lands here.")
    }
}
