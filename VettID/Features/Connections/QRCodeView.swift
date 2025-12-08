import SwiftUI
import CoreImage.CIFilterBuiltins

/// View that displays a QR code
struct QRCodeView: View {
    let data: String
    let size: CGFloat

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        if let image = generateQRCode(from: data) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray5))
                .frame(width: size, height: size)
                .overlay {
                    VStack {
                        Image(systemName: "qrcode")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("Unable to generate QR code")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
        }
    }

    private func generateQRCode(from string: String) -> UIImage? {
        filter.message = Data(string.utf8)

        guard let outputImage = filter.outputImage else {
            return nil
        }

        // Scale up the QR code for better quality
        let scale = size / outputImage.extent.width
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
            return UIImage(cgImage: cgImage)
        }

        return nil
    }
}

#if DEBUG
struct QRCodeView_Previews: PreviewProvider {
    static var previews: some View {
        QRCodeView(data: "vettid://invite/ABC123", size: 200)
    }
}
#endif
