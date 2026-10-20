import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code (an invitation, VAULT-MESSAGING §6.4), drawn with Core Image. Always dark modules on a white card with a
/// quiet zone, in both themes: scanners need that contrast, so these two colours are the one place the palette does not
/// apply. Error correction M, as vettid-android's; one pixel per module, scaled without interpolation so that every
/// module stays sharp at any size. Mirrors vettid-android `QrCode`.
public struct QrCode: View {
    /// Encoded when the view is made (its parent's redraws, such as an expiry line's, do not remake it); nothing of it is
    /// kept elsewhere once the screen goes.
    let image: CGImage?
    let label: String
    let size: CGFloat

    public init(_ content: String, accessibilityLabel: String, size: CGFloat = 240) {
        image = Self.image(content)
        self.label = accessibilityLabel
        self.size = size
    }

    /// The quiet zone around the modules (vettid-android `QUIET_ZONE`).
    static let quietZone: CGFloat = 16

    public var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .antialiased(false)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Color.white.frame(width: size, height: size)
            }
        }
        .padding(Self.quietZone)
        .background(Color.white, in: VettIDShape.card)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isImage)
    }

    /// The QR code of [content] with error correction M, one pixel per module, without the generator's margin; nil if it
    /// does not fit.
    static func image(_ content: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Core Image adds a one-module margin on every side; the card's padding is the quiet zone.
        let modules = output.extent.insetBy(dx: 1, dy: 1)
        return CIContext().createCGImage(output.cropped(to: modules), from: modules)
    }
}
