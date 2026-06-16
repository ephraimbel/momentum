import SwiftUI
import PhotosUI
import UIKit

/// Attach a photo to a workout, Strava-style (docs/SOCIAL-LAYER.md). Shown on the post-workout
/// summary (editable) and read-only in history. The image is downscaled before persisting so the blob
/// stays small; it appears on the workout's feed post.
struct WorkoutPhotoSection: View {
    @Bindable var workout: Workout
    var canEdit: Bool = false
    @Environment(\.modelContext) private var context
    @State private var picked: PhotosPickerItem?

    var body: some View {
        Group {
            if let data = workout.photoData, let ui = UIImage(data: data) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: ui).resizable().scaledToFill()
                        .frame(maxWidth: .infinity).frame(height: 240).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    if canEdit { changeMenu }
                }
            } else if canEdit {
                PhotosPicker(selection: $picked, matching: .images) {
                    HStack(spacing: Theme.Space.sm) {
                        Image(systemName: "camera").font(.system(size: 16, weight: .semibold))
                        Text("Add a photo").font(.rounded(Theme.FontSize.body, weight: .semibold))
                    }
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [5])))
                }
            }
        }
        .onChange(of: picked) { _, item in Task { await load(item) } }
    }

    private var changeMenu: some View {
        Menu {
            PhotosPicker("Replace photo", selection: $picked, matching: .images)
            Button("Remove photo", role: .destructive) { workout.photoData = nil; try? context.save(); Haptics.medium() }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(Circle().fill(.black.opacity(0.4)))
        }
        .padding(Theme.Space.sm)
        .accessibilityLabel("Photo options")
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        workout.photoData = Self.downscaled(data)
        try? context.save()
        Haptics.success()
    }

    /// Downscale to ≤1080px on the long edge as JPEG so the stored blob stays small.
    static func downscaled(_ data: Data, maxDimension: CGFloat = 1080, quality: CGFloat = 0.8) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image.jpegData(compressionQuality: quality) ?? data }
        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1                                  // points == pixels → predictable blob size
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: quality) ?? data
    }
}
