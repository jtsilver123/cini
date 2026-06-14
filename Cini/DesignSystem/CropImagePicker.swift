import SwiftUI
import UIKit

/// Native square crop for avatars: UIImagePickerController's built-in
/// editing gives Apple's familiar pan/zoom-to-square crop and returns a
/// square image — no custom gesture math, and exactly what people expect
/// when setting a profile photo.
struct CropImagePicker: UIViewControllerRepresentable {
    var onCropped: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = true   // the square crop UI
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CropImagePicker
        init(_ parent: CropImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let cropped = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            parent.dismiss()
            if let cropped { parent.onCropped(cropped) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// Square-fill, resize to 512, JPEG — the one avatar processing path,
/// shared by onboarding and edit-profile. Draw-based so UIImage
/// orientation (portrait selfies) is respected; no cgImage pixel math.
enum AvatarImage {
    static func jpeg(from image: UIImage, side: CGFloat = 512) -> Data? {
        let target = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.jpegData(withCompressionQuality: 0.82) { _ in
            // Aspect-FILL the square and center — the crop UI already
            // squares it, and avatars are circle-clipped anyway.
            let scale = max(side / image.size.width, side / image.size.height)
            let w = image.size.width * scale
            let h = image.size.height * scale
            image.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
    }
}
