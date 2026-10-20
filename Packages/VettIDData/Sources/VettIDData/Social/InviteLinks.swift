import Foundation
import VettIDCrypto

/// Invitation links and QR codes (VAULT-MESSAGING §6.4, 0.10.2). The QR code holds the compact JSON payload; the bare
/// link is its unpadded base64url; a connection invitation is shared as the URL `<r>/connect#<link>` on the invitation's
/// own relay (`r` in the payload), and the relay's page offers `vettid://connect#<link>`. The app accepts every form, also
/// inside a longer text (a URL whose fragment, query value or last path segment is the link, or a message with the link
/// on a line of its own). The host of a URL is never trusted: the payload's `r` decides the relay, and only the bare
/// payload is passed to the vault. The Universal Link `https://relay.vettid.org/connect` and the scheme `vettid://connect`
/// open the app (IOS-PLAN §6.8). Mirrors vettid-android `InviteLinks` (the transfer codes of §6.7.1 come with the
/// transfer, IOS-PLAN §8 I3).
public enum InviteLinks {
    /// What a pasted or scanned text holds.
    public enum Parsed: Equatable, Sendable {
        /// A connection invitation: [link] is what `connection.invite.accept` takes.
        case ok(link: String, exp: Date)
        /// A valid VettID code of another kind (a device pairing or transfer).
        case notAConnection
        case expired
        case invalid
    }

    /// The custom scheme of the relay page's "Open in VettID" link (§6.4).
    public static let scheme = "vettid"

    /// The path every relay serves its `/connect` page on (§6.4).
    public static let connectPath = "/connect"

    /// The invitation URL `<r>/connect#<link>` (§6.4) for a connection link, built from the payload's own relay `r`; nil
    /// for a link that does not parse or is not a connection.
    public static func url(_ link: String) -> String? {
        guard let q = try? InviteQr.parseLink(link), q.kind == .connection, let canonical = try? q.link() else { return nil }
        var relay = Substring(q.relay)
        while relay.hasSuffix("/") { relay = relay.dropLast() }
        return relay + connectPath + "#" + canonical
    }

    /// Whether an opened URL is meant for the connect flow: `vettid://connect#…`, or an `https` URL whose path is
    /// `/connect` (any host: the payload inside decides, §6.4).
    public static func isConnectURL(_ s: String) -> Bool {
        guard let u = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        switch u.scheme?.lowercased() {
        case scheme:
            let host = u.host ?? u.path.split(separator: "/").first.map(String.init)
            return host?.lowercased() == "connect"
        case "https", "http":
            var path = Substring(u.percentEncodedPath)
            while path.hasSuffix("/") { path = path.dropLast() }
            return path == connectPath
        default:
            return false
        }
    }

    /// The QR content for a link: the compact JSON payload (§6.4).
    public static func qrPayload(_ link: String) throws -> String {
        guard let s = String(bytes: try InviteQr.parseLink(link).marshal(), encoding: .utf8) else { throw CryptoError.format("qr") }
        return s
    }

    /// The invitation's expiry, from a link.
    public static func expiry(_ link: String) throws -> Date {
        Date(timeIntervalSince1970: TimeInterval(try InviteQr.parseLink(link).exp))
    }

    /// What [text] holds, at [now].
    public static func parse(_ text: String, now: Date = Date()) -> Parsed {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let q = candidates(t).lazy.compactMap(decode).first, let link = try? q.link() else { return .invalid }
        let exp = Date(timeIntervalSince1970: TimeInterval(q.exp))
        if q.kind != .connection { return .notAConnection }
        if exp <= now { return .expired }
        return .ok(link: link, exp: exp)
    }

    private static func decode(_ s: String) -> InviteQr? {
        s.hasPrefix("{") ? try? InviteQr.parse(Array(s.utf8)) : try? InviteQr.parseLink(s)
    }

    /// The runs of base64url characters long enough to be a link.
    private static var linkChars: Regex<Substring> { /[A-Za-z0-9_\-]{40,}/ }

    /// The texts to try, in order: the whole text, without white space, the fragment (and its last `=` value), the last
    /// `=` value, the last path segment, then every long run of link characters.
    private static func candidates(_ t: String) -> [String] {
        var out = [t]
        if t.hasPrefix("{") { return out }
        let noSpace = String(t.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        if noSpace != t { out.append(noSpace) }
        if let f = after(noSpace, "#"), !f.isEmpty {
            out.append(f)
            out.append(after(f, "=") ?? f)
        }
        if let v = after(noSpace, "="), !v.isEmpty { out.append(v) }
        var trimmed = Substring(noSpace)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        let segment = after(String(trimmed), "/") ?? String(trimmed)
        if !segment.isEmpty { out.append(segment) }
        out += t.matches(of: linkChars).map { String($0.output) }
        return out
    }

    /// What follows the last [c] in [s]; nil without one.
    private static func after(_ s: String, _ c: Character) -> String? {
        s.lastIndex(of: c).map { String(s[s.index(after: $0)...]) }
    }
}
