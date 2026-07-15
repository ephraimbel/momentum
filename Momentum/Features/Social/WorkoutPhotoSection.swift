import SwiftUI
import PhotosUI
import UIKit

/// Attach photos to a workout, Strava-style (docs/SOCIAL-LAYER.md) — up to `Workout.photoCap`,
/// swipeable when there's more than one. Shown on the post-workout summary (editable) and read-only
/// in history. Images are downscaled before persisting so each blob stays small; they appear on the
/// workout's feed post as a carousel. Legacy single-photo workouts are folded into the multi-photo
/// set on their first photo edit here.
struct WorkoutPhotoSection: View {
    @Bindable var workout: Workout
    var canEdit: Bool = false
    @Environment(\.modelContext) private var context
    @State private var picked: [PhotosPickerItem] = []
    @State private var choosingSource = false
    @State private var showingLibrary = false
    @State private var showingCamera = false

    private var photosData: [Data] { workout.orderedPhotosData }
    private var remaining: Int { Workout.photoCap - photosData.count }
    private static var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            if !photosData.isEmpty {
                PhotoCarousel(photosData: photosData, height: 240)
            }
            if canEdit {
                if photosData.isEmpty {
                    addButton
                } else {
                    thumbnailStrip
                }
            }
        }
        .onChange(of: picked) { _, items in Task { await load(items) } }
        // Take a photo right there or pull from the library (user ask 2026-07-11) — the dialog is
        // skipped when there's no camera (Simulator, iPad without one) and the library opens direct.
        .confirmationDialog("Add photos", isPresented: $choosingSource, titleVisibility: .hidden) {
            Button("Take photo") { showingCamera = true }
            Button("Choose from library") { showingLibrary = true }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showingLibrary, selection: $picked,
                      maxSelectionCount: max(remaining, 0), matching: .images)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { image in append(image) }
                .ignoresSafeArea()
        }
    }

    private func addPhotos() {
        #if DEBUG
        // The system Photos picker is out-of-process on the Simulator (XCUITest can't reliably drive
        // it), so under the core-flow E2E flag a tap attaches a bundled demo image directly — the
        // real append path, just without the picker — so the photo → save → feed → grid flow is testable.
        if ProcessInfo.processInfo.arguments.contains("--ui-test-run4"),
           let url = Bundle.main.url(forResource: "demo-avatar", withExtension: "jpg"),
           let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
            append(img)
            return
        }
        #endif
        if Self.cameraAvailable { choosingSource = true } else { showingLibrary = true }
    }

    // MARK: Add (empty state)

    private var addButton: some View {
        Button { addPhotos() } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "camera").font(.system(size: 16, weight: .semibold))
                Text("Add photos").font(.rounded(Theme.FontSize.body, weight: .semibold))
            }
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity).frame(height: 56)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [5])))
        }
        .buttonStyle(.plain)
    }

    // MARK: Manage (thumbnails + add tile)

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(Array(photosData.enumerated()), id: \.offset) { index, data in
                    thumbnail(data, index: index)
                }
                if remaining > 0 {
                    Button { addPhotos() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                            .frame(width: 56, height: 56)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.surface))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [5])))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add photo")
                }
            }
            .padding(.top, 2)   // room for the remove badge overhang
        }
    }

    private func thumbnail(_ data: Data, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().scaledToFill()
                } else {
                    Theme.surface
                }
            }
            .frame(width: 56, height: 56).clipped()
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
            Button { remove(at: index) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 18, height: 18).background(Circle().fill(.black.opacity(0.55)))
            }
            .padding(2)
            .accessibilityLabel("Remove photo \(index + 1)")
        }
    }

    /// A camera capture lands exactly like a picked photo: downscaled, appended in order, saved.
    private func append(_ image: UIImage) {
        guard remaining > 0, let raw = image.jpegData(compressionQuality: 0.9) else { return }
        migrateLegacyIfNeeded()
        let order = (workout.photos.map(\.order).max() ?? -1) + 1
        workout.photos.append(WorkoutPhoto(order: order, data: Self.downscaled(raw)))
        try? context.save()
        Haptics.success()
    }

    // MARK: Mutations (all edits run on the multi-photo set — legacy folds in first)

    private func load(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        migrateLegacyIfNeeded()
        var order = (workout.photos.map(\.order).max() ?? -1) + 1
        // Cap enforced here regardless of what the picker allowed.
        for item in items.prefix(max(0, Workout.photoCap - workout.photos.count)) {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            workout.photos.append(WorkoutPhoto(order: order, data: Self.downscaled(data)))
            order += 1
        }
        picked = []
        try? context.save()
        Haptics.success()
    }

    private func remove(at index: Int) {
        migrateLegacyIfNeeded()
        let ordered = workout.photos.sorted { $0.order < $1.order }
        guard ordered.indices.contains(index) else { return }
        let photo = ordered[index]
        workout.photos.removeAll { $0.id == photo.id }
        context.delete(photo)
        for (i, p) in workout.photos.sorted(by: { $0.order < $1.order }).enumerated() { p.order = i }
        try? context.save()
        Haptics.medium()
    }

    /// Fold the pre-multi-photo single blob into `photos` (one-time, on first edit — display-only
    /// paths keep reading the legacy field untouched via `orderedPhotosData`).
    private func migrateLegacyIfNeeded() {
        guard let legacy = workout.photoData, workout.photos.isEmpty else { return }
        workout.photos.append(WorkoutPhoto(order: 0, data: legacy))
        workout.photoData = nil
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

/// The system camera, presented full screen — a capture lands through `onCapture` exactly like a
/// library pick. Guarded by `isSourceTypeAvailable(.camera)` at the call site (Simulator has none).
private struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
