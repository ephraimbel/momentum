import SwiftUI

/// A single shimmering placeholder line. Standardizes the ad-hoc loading rectangles (e.g. the
/// `cornerRadius: 6` skeleton in `AIReadCard`) onto `Radius.chip`. Reduce-Motion holds it static.
struct SkeletonLine: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep: CGFloat = -1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
        return shape
            .fill(Theme.hairline)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        shape.fill(
                            LinearGradient(colors: [.clear, Color.white.opacity(0.55), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: geo.size.width)
                        .offset(x: sweep * geo.size.width)
                    }
                }
            }
            .clipShape(shape)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { sweep = 1 }
            }
    }
}

/// Wraps content in a redacted placeholder while loading. Pair with `SkeletonLine` for bespoke rows.
struct Skeleton<Content: View>: View {
    let isLoading: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .redacted(reason: isLoading ? .placeholder : [])
    }
}
