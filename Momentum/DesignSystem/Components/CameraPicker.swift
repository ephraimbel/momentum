import SwiftUI
import UIKit

/// The system camera, presented full screen — a capture lands through `onCapture` exactly like a
/// library pick. Guarded by `CameraPicker.isAvailable` at the call site (the Simulator has none, and
/// presenting it there shows a black screen with no way back).
///
/// Shared rather than per-feature: the workout photo section and the share composer both capture a
/// still the same way, and a second private copy would be a second place to fix an orientation or
/// dismissal bug.
struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

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
            // `.editedImage` first so a capture the athlete cropped in the system UI is respected.
            if let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage) {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
