#if os(iOS)
import SwiftUI
import VettIDData
import VettIDDevices
import VettIDUI

/// A string as ANDROID-PLAN 0.1.137 AA8 "How a string is shown" draws it: in full in a monospace box, left to right and isolated,
/// an escaped code point in a highlighted box, spaces marked, characters outside printable ASCII highlighted with the look-alike
/// line under it. The approvals of AA8 use it too (``VettIDApprovals``'s run and proxy screens). Mirrors vettid-android `ShownStringBox`.
public struct ShownStringBox: View {
    @Environment(\.vettIDColors) private var colors
    let text: String
    let identifier: String

    /// [identifier]: the box's accessibility identifier (tests find it by it).
    public init(_ text: String, identifier: String = "shown_string") {
        self.text = text
        self.identifier = identifier
    }

    public var body: some View {
        let pieces = ShownString.pieces(text)
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(shown(pieces))
                .vettIDFont(.bodyMedium)
                .monospaced()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.s)
                .overlay(RoundedRectangle(cornerRadius: VettIDShape.small).stroke(colors.outline))
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(pieces))
                .accessibilityIdentifier(identifier)
            if ShownString.lookalike(pieces) {
                Text(ItemWaysStrings.waysStringLookalike)
                    .vettIDFont(.bodySmall)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .accessibilityIdentifier("shown_string_lookalike")
            }
        }
    }

    /// The string between the left-to-right isolate and override, so that it keeps its logical order and cannot reorder what is
    /// around it.
    private func shown(_ pieces: [ShownPiece]) -> AttributedString {
        var out = AttributedString("\u{2066}\u{202D}")
        func add(_ s: String, background: ThemeColor? = nil, color: ThemeColor? = nil) {
            var a = AttributedString(s)
            if let background { a.backgroundColor = background.color }
            if let color { a.foregroundColor = color.color }
            out.append(a)
        }
        if pieces.isEmpty { add(ItemWaysStrings.waysStringEmpty, background: colors.warning.opacity(0.25), color: colors.onSurface) }
        for p in pieces {
            switch p {
            case .text(let t, let plain):
                if plain { add(t) } else { add(t, background: colors.secondaryContainer, color: colors.onSecondaryContainer) }
            case .escape(let cp): add(ShownPiece.label(cp), background: colors.warning.opacity(0.25), color: colors.onSurface)
            case .space: add("·", color: colors.outline)
            }
        }
        add("\u{202C}\u{2069}")
        return out
    }

    /// What VoiceOver says: the text, each escape as "escaped character U+202E".
    private func spoken(_ pieces: [ShownPiece]) -> String {
        if pieces.isEmpty { return ItemWaysStrings.waysStringEmpty }
        return pieces.map { p -> String in
            switch p {
            case .text(let t, _): t
            case .escape(let cp): " " + ItemWaysStrings.waysStringEscaped(ShownPiece.label(cp)) + " "
            case .space: " "
            }
        }.joined()
    }
}
#endif
