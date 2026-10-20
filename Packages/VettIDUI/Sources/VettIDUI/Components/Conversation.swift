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
