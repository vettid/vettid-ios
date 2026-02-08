import SwiftUI
import PhotosUI

// MARK: - Profile Photo Capture

/// Wraps UIImagePickerController for camera + photo library access
/// with crop/resize to square and compression for vault storage.
struct ProfilePhotoCapture: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImageCaptured: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.allowsEditing = true
        picker.delegate = context.coordinator
        if sourceType == .camera {
            picker.cameraDevice = .front
        }
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImageCaptured: onImageCaptured, onCancel: onCancel)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImageCaptured: (UIImage) -> Void
        let onCancel: () -> Void

        init(onImageCaptured: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImageCaptured = onImageCaptured
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            if let image = image {
                onImageCaptured(image)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - Profile Photo Helper

enum ProfilePhotoHelper {
    /// Maximum dimension for profile photos
    static let maxDimension: CGFloat = 512

    /// Maximum file size in bytes (100KB)
    static let maxFileSize = 100_000

    /// Crop and resize image to a square
    static func cropToSquare(_ image: UIImage) -> UIImage {
        let size = min(image.size.width, image.size.height)
        let origin = CGPoint(
            x: (image.size.width - size) / 2,
            y: (image.size.height - size) / 2
        )
        let cropRect = CGRect(origin: origin, size: CGSize(width: size, height: size))

        guard let cgImage = image.cgImage?.cropping(to: cropRect) else {
            return image
        }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Resize image to fit within maxDimension
    static func resize(_ image: UIImage, maxDimension: CGFloat = ProfilePhotoHelper.maxDimension) -> UIImage {
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension else { return image }

        let scale = maxDimension / max(size.width, size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Compress image to JPEG with quality reduction until under maxFileSize
    static func compress(_ image: UIImage, maxFileSize: Int = ProfilePhotoHelper.maxFileSize) -> Data? {
        var quality: CGFloat = 0.8
        while quality > 0.1 {
            if let data = image.jpegData(compressionQuality: quality),
               data.count <= maxFileSize {
                return data
            }
            quality -= 0.1
        }
        // Last resort: lowest quality
        return image.jpegData(compressionQuality: 0.1)
    }

    /// Process a captured image: crop, resize, and compress
    static func processProfilePhoto(_ image: UIImage) -> Data? {
        let cropped = cropToSquare(image)
        let resized = resize(cropped)
        return compress(resized)
    }

    /// Encode photo data to base64 for NATS transmission
    static func encodeToBase64(_ data: Data) -> String {
        data.base64EncodedString()
    }
}

// MARK: - Profile Photo Picker Sheet

/// A sheet that offers camera or photo library selection
struct ProfilePhotoPickerSheet: View {
    let onImageSelected: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var showCamera = false
    @State private var showPhotoLibrary = false
    @State private var selectedPhotoItem: PhotosPickerItem?

    var body: some View {
        NavigationView {
            List {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                }

                Button {
                    showPhotoLibrary = true
                } label: {
                    Label("Choose from Library", systemImage: "photo.on.rectangle")
                }

                Button(role: .destructive) {
                    // Signal removal by passing a 1x1 clear image
                    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
                    let clearImage = renderer.image { ctx in
                        UIColor.clear.setFill()
                        ctx.fill(CGRect(origin: .zero, size: CGSize(width: 1, height: 1)))
                    }
                    onImageSelected(clearImage)
                    dismiss()
                } label: {
                    Label("Remove Photo", systemImage: "trash")
                }
            }
            .navigationTitle("Profile Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                ProfilePhotoCapture(
                    sourceType: .camera,
                    onImageCaptured: { image in
                        onImageSelected(image)
                        dismiss()
                    },
                    onCancel: {
                        showCamera = false
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showPhotoLibrary) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Text("Select Photo")
                }
                .onChange(of: selectedPhotoItem) { newItem in
                    Task {
                        if let data = try? await newItem?.loadTransferable(type: Data.self),
                           let uiImage = UIImage(data: data) {
                            onImageSelected(uiImage)
                            await MainActor.run { dismiss() }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
