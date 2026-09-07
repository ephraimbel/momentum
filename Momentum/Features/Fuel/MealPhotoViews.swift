import SwiftUI

/// A meal's photo at the size a surface needs, decoded once through `ImageDownsampler`'s cache and
/// never at full resolution in a list (2026-09-07). The journal row draws it at 48 pt, the detail
/// sheet at the card's width; both read the same stored bytes.
struct MealPhotoView: View {
    let data: Data
    /// The longest side, in points; scaled for the screen inside.
    var maxPoints: CGFloat
    var cornerRadius: CGFloat = 10
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.hairline)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: data.count) {
            let decoded = await ImageDownsampler.thumbnail(data, maxPixel: maxPoints * displayScale)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.crossfade) { image = decoded }
        }
        .accessibilityLabel("Meal photo")
    }
}
