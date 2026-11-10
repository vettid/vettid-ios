import Foundation

extension AccountNames {
    /// A comparison key for "could this pass for that name": Default_Ignorable code points removed, every run of White_Space
    /// and U+2800 (it draws as a blank, 0.78.1) one U+0020, NFKC, case-folded, trimmed. Mirrors vettid-android
    /// `AccountNames.lookalikeKey`.
    public static func lookalikeKey(_ s: String) -> String { lookalikeKey(s, dropBrailleBlank: false) }

    /// True when [shown] could pass for the [reserved] name: their ``lookalikeKey(_:)``s match with U+2800 read as a space,
    /// or with U+2800 dropped. So "VettID" with a U+2800 inside passes for "VettID", as "This phone" with U+2800 for its space
    /// passes for "This phone"; a plain "Vett ID" still does not. A false match only adds the role label; a miss lets a name
    /// pose as a reserved one (VAULT-MESSAGING 0.76.0 §10.8; ANDROID-PLAN 0.1.53 AA1). Mirrors vettid-android
    /// `AccountNames.couldPassFor`.
    public static func couldPassFor(_ shown: String, _ reserved: String) -> Bool {
        let key = lookalikeKey(reserved)
        return lookalikeKey(shown) == key || lookalikeKey(shown, dropBrailleBlank: true) == key
    }

    private static func lookalikeKey(_ s: String, dropBrailleBlank: Bool) -> String {
        func strip(_ t: String) -> String {
            var out = String.UnicodeScalarView()
            var space = false
            for u in t.unicodeScalars {
                if u.properties.isDefaultIgnorableCodePoint || (dropBrailleBlank && u == brailleBlank) { continue }
                if u.properties.isWhitespace || u == brailleBlank {
                    space = true
                    continue
                }
                if space, !out.isEmpty { out.append(" ") }
                space = false
                out.append(u)
            }
            return String(out)
        }
        return strip(strip(s).precomposedStringWithCompatibilityMapping).folding(options: .caseInsensitive, locale: nil)
    }
}
