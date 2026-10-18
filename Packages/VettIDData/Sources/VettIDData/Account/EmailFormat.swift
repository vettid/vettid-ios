import Foundation

/// A plausible email address for the typed setup code (the API decides; this only guards typos). The pattern is
/// Android's, with Java's ASCII `\s` spelled out. Mirrors vettid-android `EmailFormat`.
public enum EmailFormat {
    private static let max = 254
    private static let pattern = #"^[^@ \t\n\x0B\f\r]{1,64}@[^@ \t\n\x0B\f\r]+\.[^@ \t\n\x0B\f\r]{2,}$"#

    public static func isPlausible(_ email: String) -> Bool {
        guard email.utf16.count <= max, let re = try? Regex(pattern) else { return false }
        return email.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: re.matchingSemantics(.unicodeScalar)) != nil
    }
}
