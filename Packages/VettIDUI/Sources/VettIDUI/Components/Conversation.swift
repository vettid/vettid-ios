import CoreImage.CIFilterBuiltins
import SwiftUI

/// One message in a conversation (ANDROID-PLAN §4): the member's own messages on the right in a gold fill, the
/// connection's on the left in a card colour. [meta] is the time and, for own messages, the delivery state; the whole
/// bubble reads as one item ([accessibilityLabel]). Mirrors vettid-android `MessageBubble`.
public struct MessageBubble: View {
    @Environment(\.vettIDColors) private var colors
    let text: String
    let outgoing: Bool
    let meta: String
    let accessibilityText: String

    public init(_ text: String, outgoing: Bool, meta: String, accessibilityLabel: String) {
        self.text = text
        self.outgoing = outgoing
        self.meta = meta
        self.accessibilityText = accessibilityLabel
    }

    public var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: outgoing ? 18 : 4,
            bottomTrailingRadius: outgoing ? 4 : 18,
            topTrailingRadius: 18,
            style: .continuous
        )
        let ink = outgoing ? colors.onPrimaryContainer : colors.onSurface
        let metaInk = (outgoing ? colors.onPrimaryContainer : colors.onSurfaceVariant).opacity(0.8)
        HStack(spacing: 0) {
            if outgoing { Spacer(minLength: 0) }
            HStack(spacing: 0) {
                VStack(alignment: .trailing, spacing: Spacing.xxs) {
                    Text(text).vettIDFont(.bodyLarge).foregroundStyle(ink).multilineTextAlignment(.leading)
                    Text(meta).vettIDFont(.labelSmall).foregroundStyle(metaInk)
                }
                .padding(.horizontal, Spacing.m + Spacing.xxs)
                .padding(.vertical, Spacing.s)
                .background(outgoing ? colors.primaryContainer : colors.surfaceContainerHigh, in: shape)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
            }
            // The bubble hugs its text, up to 78 % of the row.
            .containerRelativeFrame(.horizontal, alignment: outgoing ? .trailing : .leading) { width, _ in
                (width - 2 * Spacing.gutter) * 0.78
            }
            if !outgoing { Spacer(minLength: 0) }
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.vertical, Spacing.xxs)
    }
}

/// A day separator in a conversation. Mirrors vettid-android `DayDivider`.
public struct DayDivider: View {
    @Environment(\.vettIDColors) private var colors
    let label: String

    public init(_ label: String) { self.label = label }

    public var body: some View {
        Text(label)
            .vettIDFont(.labelMedium)
            .foregroundStyle(colors.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.m)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The 6-digit safety code (VAULT-MESSAGING §6.3 SAS) in two groups of three, large and monospaced; screen readers
/// hear the digits one by one. Mirrors vettid-android `SafetyCode`.
public struct SafetyCode: View {
    @Environment(\.vettIDColors) private var colors
    let digits: String

    public init(_ code: String) { digits = code.filter(\.isNumber) }

    public var body: some View {
        HStack(spacing: Spacing.l) {
            ForEach(Array(Self.groups(digits).enumerated()), id: \.offset) { _, group in
                Text(verbatim: group)
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .tracking(4)
                    .foregroundStyle(colors.primary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UIStrings.safetyCode(digits.map(String.init).joined(separator: " ")))
    }

    static func groups(_ digits: String) -> [String] {
        stride(from: 0, to: digits.count, by: 3).map { i in
            let start = digits.index(digits.startIndex, offsetBy: i)
            let end = digits.index(start, offsetBy: min(3, digits.count - i))
            return String(digits[start..<end])
        }
    }
}

/// A QR code (an invitation, VAULT-MESSAGING §6.4). Always dark modules on a white card with a quiet zone, in both
/// themes: scanners need that contrast, so these two colours are the one place the palette does not apply.
/// Error correction M. Mirrors vettid-android `QrCode`.
public struct QrCode: View {
    let content: String
    let label: String
    let size: CGFloat

    public init(_ content: String, accessibilityLabel: String, size: CGFloat = 240) {
        self.content = content
        self.label = accessibilityLabel
        self.size = size
    }

    public var body: some View {
        Group {
            if let image = Self.image(content) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Color.white.frame(width: size, height: size)
            }
        }
        .padding(16)
        .background(Color.white, in: VettIDShape.card)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isImage)
    }

    /// The QR code of [content] with error correction M, without the generator's margin; nil if it does not fit.
    static func image(_ content: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // CoreImage adds a one-module margin on every side; the card's padding is the quiet zone.
        let modules = output.extent.insetBy(dx: 1, dy: 1)
        return CIContext().createCGImage(output.cropped(to: modules), from: modules)
    }
}
