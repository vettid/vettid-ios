import Foundation

/// `pad` (VAULT-MESSAGING 0.83.6 §10.19.5, "Sizes that do not depend on the choice"): every JSON object a vote message
/// carries with a `choice_id` in it also carries `pad`, ASCII `0` characters to the number of 32 minus the byte length of
/// that `choice_id` (its UTF-8 bytes, not its escaped JSON form), and empty for a `choice_id` longer than 32 bytes. Senders
/// write it exactly so; a receiver never checks it or requires it (an exception to §5.3), so nothing here reads one.
/// Mirrors vettid-android `VotePad`.
public enum VotePad {
    /// The longest `choice_id` padded to (BALLOT-PROTOCOL §8.5: 1 to 32 bytes).
    public static let width = 32

    /// The `pad` for [choiceID].
    public static func of(_ choiceID: String) -> String { of(Array(choiceID.utf8)) }

    /// The `pad` for a `choice_id` of these UTF-8 bytes.
    public static func of(_ choiceID: [UInt8]) -> String { String(repeating: "0", count: max(width - choiceID.count, 0)) }
}
