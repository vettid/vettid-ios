import Foundation
import VettIDCrypto

/// A sealed result of the alternate channel could not be opened or parsed, or a scanned code is not one. The message
/// names the failure only. Mirrors vettid-android `AltResultException`.
public struct AltResultError: Error, Equatable, CustomStringConvertible {
    public let what: String

    public init(_ what: String) { self.what = what }

    public var description: String { "alternate channel: \(what)" }
}

/// The recovery QR the portal shows and the new app scans (§11.11.2): `{"v":1,"t":"r","vault_id","recovery_id",
/// "code"}`, parsed as strictly as vettid-vault's `ParseRecoveryQR` (and the code's alphabet checked too). Mirrors
/// vettid-android `RecoveryCode`.
public struct RecoveryCode: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let vaultID: String
    public let recoveryID: String
    public let code: String
    /// The QR's member API origin (0.15.0): compared exactly with the app's own, never contacted; nil when absent.
    public let api: String?

    public init(vaultID: String, recoveryID: String, code: String, api: String? = nil) {
        self.vaultID = vaultID
        self.recoveryID = recoveryID
        self.code = code
        self.api = api
    }

    /// The code itself is never printed.
    public var description: String { "RecoveryCode(\(vaultID), \(recoveryID))" }
    public var debugDescription: String { description }
    /// Nothing for `dump` and the debugger to show.
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    public static func parseQR(_ b: [UInt8]) throws -> RecoveryCode {
        do {
            let o = try StrictJson.parseObject(b)
            guard try o.uint("v", min: 1, max: 1) == 1, try o.string("t") == "r" else { throw AltResultError("recovery QR") }
            return try checked(
                RecoveryCode(
                    vaultID: try o.string("vault_id"),
                    recoveryID: try o.string("recovery_id"),
                    code: try o.string("code"),
                    api: try o.optString("api")
                )
            )
        } catch let e as AltResultError {
            throw e
        } catch {
            throw AltResultError("recovery QR")
        }
    }

    /// [c] when its code, recovery id and vault id have the forms a recovery QR's must have.
    static func checked(_ c: RecoveryCode) throws -> RecoveryCode {
        guard RecoveryCodes.isValid(c.code), Ulid.isValid(c.recoveryID), validVaultID(c.vaultID) else {
            throw AltResultError("recovery QR")
        }
        return c
    }

    /// A scanned QR's text (the compact JSON), or nil when it is not a recovery QR.
    public static func parseScanned(_ text: String) -> RecoveryCode? {
        try? parseQR(Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    /// As the enclave's `validVaultID`: 1–128 printable ASCII characters.
    private static func validVaultID(_ s: String) -> Bool {
        (1...128).contains(s.utf8.count) && s.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }
}

/// The recovery code's form (§11.11.2): 20 random bytes as 32 Crockford base32 characters (`0-9A-HJKMNP-TV-Z`, upper
/// case, no padding); and its typed form (§11.11.10), which the portal shows under the QR as 12 groups of four:
///
/// ```
/// typed = locator (12) || code (32) || check (4)
/// check = the first 20 bits of
///         SHA-256("vettid/vms/2/recovery-typed-check" || 0x00 || api || 0x00 || locator || code),
///         as 4 characters of the alphabet (most significant 5 bits first)
/// ```
///
/// Mirrors vettid-android `RecoveryCodes`.
public enum RecoveryCodes {
    public static let length = 32
    public static let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    public static let group = 4
    private static let alphabetBytes = Set(alphabet.utf8)
    private static let alphabetChars = Array(alphabet)

    /// A typed recovery code's locator (VAULT-MESSAGING §11.11.10): the member API's stand-in for (`vault_id`,
    /// `recovery_id`) at the claim, 12 characters of the alphabet (60 random bits).
    public static let locatorLength = 12
    public static let checkLength = 4
    public static let typedLength = locatorLength + length + checkLength
    public static let typedGroups = typedLength / group
    private static let typedCheckLabel = "vettid/vms/2/recovery-typed-check"
    private static let bitsPerChar = 5
    private static let charMask = 31

    /// Why a typed character was refused in the field (§11.11.10 step 1): never guessed, never sent.
    public enum Refused: Equatable, Sendable {
        /// `U` is not in the alphabet and is not mapped: "Check whether it is a V."
        case letterU
        /// Anything else that is neither a digit nor a letter of the alphabet, a look-alike or a separator.
        case other
    }

    /// What typed or pasted text holds: [text] the canonical characters so far (at most ``typedLength``; a forty-ninth
    /// is ignored), and, when a character was refused, [refused] with [refusedGroup] (1 to 12), the group it would have
    /// gone into. Refused characters are dropped, never replaced. Never printed.
    public struct TypedInput: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let text: String
        public let refused: Refused?
        public let refusedGroup: Int

        public init(text: String, refused: Refused? = nil, refusedGroup: Int = 0) {
            self.text = text
            self.refused = refused
            self.refusedGroup = refusedGroup
        }

        /// Groups of four that are complete.
        public var groups: Int { text.count / RecoveryCodes.group }

        public var complete: Bool { text.count == RecoveryCodes.typedLength }

        public var description: String { "TypedInput(\(text.count) characters, refused=\(refused.map { "\($0)" } ?? "nil"))" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: [:]) }
    }

    public static func isLocator(_ s: String) -> Bool {
        s.utf8.count == locatorLength && s.utf8.allSatisfy(alphabetBytes.contains)
    }

    public static func isValid(_ code: String) -> Bool {
        code.utf8.count == length && code.utf8.allSatisfy(alphabetBytes.contains)
    }

    /// One character as the canonical form has it, nil for a separator (dropped), or `.refused`: spaces, hyphens and
    /// line breaks are dropped, letters upper-cased, and the Crockford look-alikes read as digits (I and L as 1, O as
    /// 0), which the canonical form never contains. `U` is never mapped. Read one Unicode scalar at a time, as Android
    /// reads one UTF-16 unit, so that a combining mark is refused on its own. Every non-ASCII letter is refused, also
    /// those Android's upper-casing would map into the alphabet (`ı`, `ſ`): §11.11.10 step 1 names only the ASCII
    /// look-alikes (chosen; not in the spec).
    private enum Canonical { case char(Character), separator, refused(Refused) }

    private static func canonical(_ ch: Unicode.Scalar) -> Canonical {
        switch ch {
        case " ", "-", "\t", "\n", "\r", "\u{00A0}": return .separator
        default: break
        }
        guard ch.isASCII else { return .refused(.other) }
        let b = UInt8(ch.value)
        let up = Character(Unicode.Scalar(("a"..."z").contains(ch) ? b - 0x20 : b))
        switch up {
        case "I", "L": return .char("1")
        case "O": return .char("0")
        case "U": return .refused(.letterU)
        default: return alphabet.contains(up) ? .char(up) : .refused(.other)
        }
    }

    private static func normalize(_ typed: String, length n: Int) -> String? {
        var out = ""
        for ch in typed.unicodeScalars {
            switch canonical(ch) {
            case .separator: continue
            case .refused: return nil
            case .char(let c): out.append(c)
            }
            if out.count > n { return nil }
        }
        return out.count == n ? out : nil
    }

    /// A typed code (the 32 characters alone) in its canonical form, or nil when it is not one.
    public static func normalize(_ typed: String) -> String? { normalize(typed, length: length) }

    /// The typed form (§11.11.10) in its canonical 48 characters, or nil: the same rules; `U` is never mapped.
    public static func normalizeTyped(_ typed: String) -> String? { normalize(typed, length: typedLength) }

    /// The typed form as a field takes it, character by character (§11.11.10 step 1): what is accepted so far and the
    /// first character that was refused, if any.
    public static func typedInput(_ raw: String) -> TypedInput {
        var out = ""
        var refused: Refused?
        var refusedGroup = 0
        for ch in raw.unicodeScalars {
            if out.count == typedLength { break }
            switch canonical(ch) {
            case .separator: continue
            case .char(let c): out.append(c)
            case .refused(let r):
                if refused == nil {
                    refused = r
                    refusedGroup = out.count / group + 1
                }
            }
        }
        return TypedInput(text: out, refused: refused, refusedGroup: refusedGroup)
    }

    /// The member API origin as the check hashes it: the portal's own origin, no trailing slash, lower case.
    public static func origin(_ api: String) -> String { trimmingSlashes(api).lowercased() }

    /// [api] without its trailing slashes.
    static func trimmingSlashes(_ api: String) -> String {
        var s = Substring(api)
        while s.hasSuffix("/") { s = s.dropLast() }
        return String(s)
    }

    /// The 4 check characters for [api] (a member API origin), [locator] and [code] in canonical form. They hold no
    /// secret (anyone can compute them for a guess): they catch typing mistakes and another environment's code before
    /// anything is sent. Throws when [locator] or [code] is not in canonical form.
    public static func typedCheck(api: String, locator: String, code: String) throws -> String {
        guard isLocator(locator), isValid(code) else { throw AltResultError("typed check") }
        let h = Bytes.sha256(Array("\(typedCheckLabel)\u{0}\(origin(api))\u{0}\(locator)\(code)".utf8))
        let bits = (Int(h[0]) << 12) | (Int(h[1]) << 4) | (Int(h[2]) >> 4)
        return String((0..<checkLength).reversed().map { alphabetChars[(bits >> ($0 * bitsPerChar)) & charMask] })
    }

    /// The characters in groups of four (`ABCD EFGH …`).
    public static func grouped(_ code: String) -> String {
        let chars = Array(code)
        return stride(from: 0, to: chars.count, by: group)
            .map { String(chars[$0..<min($0 + group, chars.count)]) }
            .joined(separator: " ")
    }
}

/// A typed recovery code whose check characters matched this app's member API origin (VAULT-MESSAGING §11.11.10 step
/// 2): the [locator] to claim with and the [code] for the enclave. Only ``parse(_:api:)`` makes one, so a string that
/// fails the check can never reach the API. The check characters are verified and dropped; nothing here is ever stored
/// or logged. Mirrors vettid-android `TypedRecoveryCode`.
public struct TypedRecoveryCode: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let locator: String
    public let code: String

    private init(locator: String, code: String) {
        self.locator = locator
        self.code = code
    }

    /// The same ``RecoveryCode`` a scan of this recovery's QR produces, from the claim's answer (§11.11.10 steps 3 and
    /// 4): everything after it is the scanned path. [api] is this app's member API origin.
    public func recoveryCode(claimed: Claimed, api: String) throws -> RecoveryCode {
        guard let vaultID = claimed.vaultID, let recoveryID = claimed.recoveryID else { throw AltResultError("recovery claim") }
        let api = RecoveryCodes.trimmingSlashes(api)
        return try RecoveryCode.checked(RecoveryCode(vaultID: vaultID, recoveryID: recoveryID, code: code, api: api))
    }

    public var description: String { "TypedRecoveryCode(…)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// What typed text turned out to be.
    public enum Parsed: Equatable, Sendable {
        /// 48 characters whose check matches: the code may be claimed.
        case ok(TypedRecoveryCode)
        /// 48 valid characters whose check does not match this app's origin: a typing mistake, or a code of another
        /// environment's account site. Input validation, not a wrong code: nothing is sent or counted.
        case badCheck
        /// Exactly the 32 characters of a bare code (an account page from before MEMBER-API 2.4.0).
        case bareCode
        /// Not 48 characters of the alphabet (too few, too many, or a character the code never contains).
        case notTyped
    }

    /// [typed] as the member typed or pasted it; [api] is this app's own built-in member API origin.
    public static func parse(_ typed: String, api: String) -> Parsed {
        guard let t = RecoveryCodes.normalizeTyped(typed) else {
            return RecoveryCodes.normalize(typed) != nil ? .bareCode : .notTyped
        }
        let chars = Array(t)
        let locator = String(chars[0..<RecoveryCodes.locatorLength])
        let code = String(chars[RecoveryCodes.locatorLength..<(RecoveryCodes.locatorLength + RecoveryCodes.length)])
        let check = String(chars[(RecoveryCodes.locatorLength + RecoveryCodes.length)...])
        // Nothing secret is compared: anyone can compute the check characters for a guess.
        let matches = (try? RecoveryCodes.typedCheck(api: api, locator: locator, code: code)) == check
        return matches ? .ok(TypedRecoveryCode(locator: locator, code: code)) : .badCheck
    }
}
