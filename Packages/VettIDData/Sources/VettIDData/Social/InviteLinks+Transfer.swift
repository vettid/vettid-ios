import Foundation
import VettIDCrypto

// The old phone's transfer code, on the new phone (VAULT-MESSAGING §6.7.1: the pairing QR, kind `p`, TTL 10 minutes).
extension InviteLinks {
    /// What a scanned or pasted text holds, for a direct transfer to this phone (§6.7.1). Mirrors vettid-android
    /// `InviteLinks.TransferParsed`.
    public enum TransferParsed: Equatable, Sendable {
        /// The old phone's transfer code: [link] is the pairing link (kind `p`).
        case ok(link: String, exp: Date)
        /// A valid VettID code of another kind (a connection invitation, a desktop or agent pairing).
        case notATransfer
        case expired
        case invalid
    }

    /// Parses the old phone's transfer QR (the compact JSON) or its pasted link (§6.7.1: pairing kind `p`), at [now], in
    /// every form ``parse(_:now:)`` accepts.
    public static func parseTransfer(_ text: String, now: Date = Date()) -> TransferParsed {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let q = candidates(t).lazy.compactMap(decode).first, let link = try? q.link() else { return .invalid }
        let exp = Date(timeIntervalSince1970: TimeInterval(q.exp))
        if q.kind != .app { return .notATransfer }
        if exp <= now { return .expired }
        return .ok(link: link, exp: exp)
    }
}
