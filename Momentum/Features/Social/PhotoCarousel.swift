import SwiftUI
import UIKit

/// Swipeable photo pager for a post's attached photos (Strava-style carousel). A single photo
/// renders plain — same frame, no page dots. Shared by the feed media block, the reading view, and
/// the workout photo section so photos look identical everywhere.
struct PhotoCarousel: View {
    let photosData: [Data]
    var height: CGFloat = 200

    var body: some View {
        Group {
            if photosData.count > 1 {
                TabView {
                    ForEach(Array(photosData.enumerated()), id: \.offset) { _, data in
                        photo(data)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .indexViewStyle(.page(backgroundDisplayMode: .interactive))
                .accessibilityLabel("Photos, \(photosData.count)")
            } else if let first = photosData.first {
                photo(first)
                    .accessibilityLabel("Photo")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func photo(_ data: Data) -> some View {
        Group {
            if let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Theme.surface
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
    }
}
