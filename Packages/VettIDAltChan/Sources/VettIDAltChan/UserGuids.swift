import Foundation

/// The member's `user_guid` (VAULT-MESSAGING §6.7.1, §11.4, §11.11.7, §11.12.1): 1–128 printable ASCII characters
/// (0x21–0x7E), so that it fits the signing strings of the unlock, the enrollment and the recovery. The one check for every
/// `user_guid` that enters the app (the setup code's redeem, the recovery claims, a transfer's `device.paired`) and for the
/// stored value the unlock and the flows that lock first read (`userGuidUsable`): any other value is no `user_guid` (fail
/// closed). The enrollment and a recovery's open read the stored value without it: it entered through the check. Mirrors
/// vettid-android `UserGuids`.
public enum UserGuids {
    public static let maxLength = 128

    public static func valid(_ g: String) -> Bool { printable(g, maxLength: maxLength) }

    /// 1–[maxLength] printable ASCII characters (0x21–0x7E): the rule of a `user_guid` and of a recovery QR's vault id.
    static func printable(_ s: String, maxLength: Int) -> Bool {
        let b = Array(s.utf8)
        return (1...maxLength).contains(b.count) && b.allSatisfy { (0x21...0x7E).contains($0) }
    }
}
