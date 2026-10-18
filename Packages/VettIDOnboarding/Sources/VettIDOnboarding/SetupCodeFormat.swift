import Foundation

/// The typed setup code as its field shows it: upper case, in groups of four (`XXXX-XXXX`), the separator only once a
/// fifth character follows, as vettid-android `TypedCodeTransformation` groups the typed recovery code. iOS has no
/// visual transformation for a text field, so the text itself is regrouped; ``SetupCodes`` ignores the hyphens.
/// Characters a code never contains are kept, so the field shows what was typed and the code is refused before
/// anything is sent. (Chosen; vettid-android shows the setup code as typed.)
public enum SetupCodeFormat {
    static let group = 4
    private static let separators: Set<Character> = [" ", "-", "\t", "\u{00A0}"]

    public static func grouped(_ typed: String) -> String {
        var out = ""
        var n = 0
        for ch in typed where !separators.contains(ch) {
            if n > 0 && n % group == 0 { out.append("-") }
            out.append(ch.isASCII ? Character(ch.uppercased()) : ch)
            n += 1
        }
        return out
    }
}
