import SwiftUI
import UIKit

// MARK: - Profile Photo Helper

enum ProfilePhotoHelper {
    /// Maximum dimension for profile photos
    static let maxDimension: CGFloat = 512

    /// Maximum file size in bytes (100KB)
    static let maxFileSize = 100_000

    /// Crop image to a centered square.
    ///
    /// `CGImage.cropping(to:)` operates in raw pixel coordinates and
    /// ignores `UIImage.scale`. Computing the rect from `image.size`
    /// (which is in points) produced a rect 1/4 the intended area on
    /// 2x devices and 1/9 on 3x — landing roughly in the top-left of
    /// the actual pixel buffer instead of the center. Compute the rect
    /// from the `cgImage` pixel dimensions so the crop matches what
    /// the user framed.
    static func cropToSquare(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let pixelWidth = CGFloat(cg.width)
        let pixelHeight = CGFloat(cg.height)
        let side = min(pixelWidth, pixelHeight)
        let origin = CGPoint(
            x: (pixelWidth - side) / 2,
            y: (pixelHeight - side) / 2
        )
        let cropRect = CGRect(origin: origin, size: CGSize(width: side, height: side))

        guard let cropped = cg.cropping(to: cropRect) else {
            return image
        }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
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

    /// Horizontally flip an image, baking the mirror into pixels with
    /// `.up` orientation so downstream crop/resize/JPEG steps preserve
    /// it. Used to undo the un-mirroring iOS does on front-camera
    /// captures (the preview is mirrored, the saved frame is not).
    static func horizontallyMirrored(_ image: UIImage) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.translateBy(x: image.size.width, y: 0)
            cg.scaleBy(x: -1, y: 1)
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// Encode photo data to base64 for NATS transmission
    static func encodeToBase64(_ data: Data) -> String {
        data.base64EncodedString()
    }
}

// MARK: - Profile Photo Picker Sheet

/// Camera-only profile photo picker. The "Choose from Library"
/// option was removed deliberately — profile photos are identity
/// photos and must be taken live, not imported.
struct ProfilePhotoPickerSheet: View {
    let onImageSelected: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var showCamera = false

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
                // Android-parity custom camera (mirrored preview,
                // circular framing guide, no system editor) — replaces
                // UIImagePickerController, which showed the un-mirrored
                // frame during cropping and confused the user.
                ProfilePhotoCameraView(
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
        }
        .presentationDetents([.medium])
    }
}
