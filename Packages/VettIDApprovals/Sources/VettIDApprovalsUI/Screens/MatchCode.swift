#if os(iOS)
import SwiftUI
import VettIDUI

/// A sign-in's match code (VAULT-MESSAGING 0.79.0 §10.4, IOS-PLAN §4.14): "Match code", the digits in large type, and the
/// instruction to compare them with the sign-in screen. It looks like a fact, never like a verification: no check mark,
/// shield, success colour or "verified" word, since a site that relays the real sign-in page shows the same number.
/// VoiceOver reads the block as "Match code 4 2", the digits one by one. Mirrors ANDROID-PLAN §4 "Sign-in match code".
struct MatchCodeBlock: View {
    @Environment(\.vettIDColors) private var colors
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                FactLabel(ApprovalsStrings.matchCodeLabel)
                Text(code)
                    .font(.system(.largeTitle, weight: .bold).monospacedDigit())
                    .tracking(Spacing.s)
                    .foregroundStyle(colors.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Self.spoken(code)))
            .accessibilityIdentifier("match_code")
            Text(ApprovalsStrings.matchCodeInstruction(code))
                .vettIDFont(.bodyMedium)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("match_code_instruction")
        }
        .padding(.bottom, Spacing.l)
    }

    /// "Match code 4 2": the digits apart, each marked to be spelled out (the spaces between them are not), so that 42 is
    /// never read as "forty-two".
    static func spoken(_ code: String) -> AttributedString {
        let digits = code.map(String.init).joined(separator: " ")
        var text = AttributedString(ApprovalsStrings.matchCodeSpoken(digits))
        guard let range = text.range(of: digits) else { return text }
        var i = range.lowerBound
        while i < range.upperBound {
            let next = text.characters.index(after: i)
            if text.characters[i] != " " { text[i..<next].accessibilitySpeechSpellsOutCharacters = true }
            i = next
        }
        return text
    }
}
#endif
