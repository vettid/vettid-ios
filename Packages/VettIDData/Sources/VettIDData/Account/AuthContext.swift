import Foundation

/// A challenge's `context`, a note, a memo or a reason is another party's own words (VAULT-MESSAGING §10.4, shown in full):
/// cleaned by ``AccountNames`` (VAULT-MESSAGING 0.76.0 §10.8 "Showing received text") so that it cannot reorder or hide
/// anything. Unlike a name it keeps its line breaks. Mirrors vettid-android `AuthContext`.
public enum AuthContext {
    /// [s] with every break one LF, Cc and Cf removed (ZWJ and ZWNJ stay), tabs as spaces, each line trimmed and no empty
    /// line at either end; "" when nothing shows.
    public static func plain(_ s: String) -> String { AccountNames.cleanedLines(s) ?? "" }

    /// ``plain(_:)`` with each line in its own isolate (FSI … PDI, §10.8 step 5), for next to other text; nil when nothing
    /// shows.
    public static func isolated(_ s: String) -> String? { AccountNames.cleanedLines(s).map(AccountNames.isolateLines) }

    /// The first line that shows something, isolated, for a list row's second line (§10.8 step 6); nil when none does.
    public static func firstLineIsolated(_ s: String) -> String? { AccountNames.firstLineIsolated(s) }

    /// A message's full text for its bubble: breaks as LF, LRM, RLM and ALM kept, each line isolated; "" when empty.
    public static func bubble(_ s: String) -> String {
        let t = AccountNames.cleanedMessage(s)
        return t.isEmpty ? t : AccountNames.isolateLines(t)
    }
}
