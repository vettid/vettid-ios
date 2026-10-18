import Foundation
import VettIDCrypto

/// The setup code the account portal issues (VAULT-MESSAGING §11.12.1, 0.15.0): a QR (or the same-device Universal
/// Link) carrying a 128-bit secret, or an 8-symbol code typed with the member's email. The app redeems it with its app
/// key; it never signs in. Mirrors vettid-android `SetupCodes`.
public enum SetupCodes {
    /// The typed code's alphabet: no 0, 1, I, L or O.
    public static let alphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
    public static let length = 8
    public static let secretLength = 22
    /// The Universal Link path on the account host (`https://<account host>/vault/enroll/#s=<secret>`).
    public static let linkPath = "/vault/enroll/"
    static let maxInput = 1024
    static let group = 4
    static let type = "e"
    private static let alphabetSet = Set(alphabet)
    private static let separators: Set<Character> = [" ", "-", "\t", "\u{00A0}"]

    /// What a scanned QR or an opened link turned out to be.
    public enum Scanned: Equatable, Sendable, CustomStringConvertible {
        /// A setup QR for this app's member API: [secret] is redeemed.
        case secret(String)
        /// A setup or recovery QR made by another environment's portal ([api], compared exactly; never contacted).
        case otherEnvironment(String)
        /// Not a setup code.
        case notACode

        public var description: String {
            switch self {
            case .secret: "Secret(…)"
            case .otherEnvironment(let api): "OtherEnvironment(\(api))"
            case .notACode: "NotACode"
            }
        }
    }

    public static func isSecret(_ s: String) -> Bool {
        s.utf8.count == secretLength && s.utf8.allSatisfy { c in
            (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || (0x30...0x39).contains(c) || c == 0x2D || c == 0x5F
        }
    }

    /// A scanned QR's text: `{"v":1,"t":"e","api":"<origin>","s":"<secret>"}`. [api] is this build's member API origin,
    /// compared exactly with the QR's `api` (an identifier, never an address the app connects to).
    public static func parseScanned(_ text: String, api: String) -> Scanned {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.utf8.count <= maxInput, let o = try? StrictJson.parseObject(Array(t.utf8)) else { return .notACode }
        guard (try? o.uint("v", min: 1, max: 1)) == 1, (try? o.string("t")) == type,
              let qrAPI = try? o.string("api"), let secret = try? o.string("s")
        else { return .notACode }
        guard isSecret(secret) else { return .notACode }
        return qrAPI == origin(api) ? .secret(secret) : .otherEnvironment(qrAPI)
    }

    /// The same-device Universal Link `https://<account host>/vault/enroll/#s=<secret>` (§11.12.1): accepted only from
    /// [api]'s own host, the secret in the fragment.
    public static func parseLink(_ link: String, api: String) -> String? {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.utf8.count <= maxInput, let u = URLComponents(string: s), let own = URLComponents(string: api) else { return nil }
        guard u.scheme == own.scheme, u.host == own.host, u.port == own.port, u.percentEncodedPath == linkPath,
              let frag = u.percentEncodedFragment
        else { return nil }
        guard let part = frag.split(separator: "&").first(where: { $0.hasPrefix("s=") }) else { return nil }
        let secret = String(part.dropFirst(2))
        return isSecret(secret) ? secret : nil
    }

    /// Whether [link] is a setup Universal Link of any form (to route it; ``parseLink(_:api:)`` decides whether it is
    /// accepted).
    public static func isSetupLink(_ link: String) -> Bool {
        URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines))?.percentEncodedPath == linkPath
    }

    /// A typed code in its canonical form (spaces and hyphens dropped, upper case, 8 symbols of ``alphabet``), or nil
    /// when it is not one: the app refuses it before anything is sent.
    public static func normalize(_ typed: String) -> String? {
        var out = ""
        for ch in typed {
            if separators.contains(ch) { continue }
            guard ch.isASCII, let c = ch.uppercased().first, alphabetSet.contains(c) else { return nil }
            out.append(c)
            if out.count > length { return nil }
        }
        return out.count == length ? out : nil
    }

    /// Whether [typed] holds a character a code never contains (0, 1, I, L, O or another symbol).
    public static func hasForeignCharacter(_ typed: String) -> Bool {
        typed.contains { ch in
            guard !separators.contains(ch) else { return false }
            guard ch.isASCII, let c = ch.uppercased().first else { return true }
            return !alphabetSet.contains(c)
        }
    }

    /// For display: `XXXX-XXXX`.
    public static func grouped(_ code: String) -> String {
        stride(from: 0, to: code.count, by: group).map { i -> String in
            let start = code.index(code.startIndex, offsetBy: i)
            return String(code[start..<code.index(start, offsetBy: min(group, code.count - i))])
        }.joined(separator: "-")
    }

    /// The member's email as the API compares it: trimmed, lower case.
    public static func normalizeEmail(_ email: String) -> String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// The origin of an API base URL (`https://host[:port]`), as the QR's `api` names it.
    public static func origin(_ api: String) -> String {
        var s = api
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
