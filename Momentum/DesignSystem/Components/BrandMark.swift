import SwiftUI

/// The in-app brand element: the app icon (glass runner), clipped to app-icon corners
/// (decision 2026-07-10 — replaces the retired `IridescentOrb` everywhere). One component so
/// every surface renders the mark identically and a future icon swap is a one-asset change.
struct BrandMark: View {
    var size: CGFloat = 44

    var body: some View {
        Image("BrandIcon")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            // Apple's icon curvature (~22.4% of edge) so the mark reads as "the app".
            .clipShape(RoundedRectangle(cornerRadius: size * 0.224, style: .continuous))
            .accessibilityHidden(true)   // decorative — surfaces label themselves
    }
}

#Preview {
    VStack(spacing: 24) {
        BrandMark(size: 96)
        BrandMark(size: 44)
        BrandMark(size: 22)
    }
    .padding()
}
