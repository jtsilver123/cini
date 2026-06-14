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
/// shared by onboarding and edit-profile.
enum AvatarImage {
    static func jpeg(from image: UIImage, side: CGFloat = 512) -> Data? {
        // Center-crop to square first (the crop UI already squares it, but
        // belt-and-suspenders for the cancel-then-original path).
        let shortest = min(image.size.width, image.size.height)
        let square = CGRect(
            x: (image.size.width - shortest) / 2,
            y: (image.size.height - shortest) / 2,
            width: shortest, height: shortest)
        let cropped = image.cgImage?.cropping(to: CGRect(
            x: square.minX * image.scale, y: square.minY * image.scale,
            width: square.width * image.scale, height: square.height * image.scale))
            .map { UIImage(cgImage: $0, scale: image.scale, orientation: image.imageOrientation) } ?? image

        let target = CGSize(width: side, height: side)
        let resized = UIGraphicsImageRenderer(size: target).image { _ in
            cropped.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.82)
    }
}
