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
public struct RecoveryCode: Equatable, Sendable, CustomStringConvertible {
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
/// case, no padding). Typing it (0.25.0, §11.11.10) comes with the recovery screens. Mirrors the code-form part of
/// vettid-android `RecoveryCodes`.
public enum RecoveryCodes {
    public static let length = 32
    public static let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    public static let group = 4
    private static let alphabetBytes = Set(alphabet.utf8)

    /// A typed recovery code's locator (VAULT-MESSAGING §11.11.10): 12 characters of the alphabet.
    public static let locatorLength = 12

    public static func isLocator(_ s: String) -> Bool {
        s.utf8.count == locatorLength && s.utf8.allSatisfy(alphabetBytes.contains)
    }

    public static func isValid(_ code: String) -> Bool {
        code.utf8.count == length && code.utf8.allSatisfy(alphabetBytes.contains)
    }

    /// One character as the canonical form has it, nil for a separator (dropped), or `.refused`: spaces, hyphens and
    /// line breaks are dropped, letters upper-cased, and the Crockford look-alikes read as digits (I and L as 1, O as
    /// 0), which the canonical form never contains. `U` is never mapped.
    private enum Canonical { case char(Character), separator, refused }

    private static func canonical(_ ch: Character) -> Canonical {
        switch ch {
        case " ", "-", "\t", "\n", "\r", "\u{00A0}": return .separator
        default: break
        }
        guard ch.isASCII, let up = ch.uppercased().first else { return .refused }
        switch up {
        case "I", "L": return .char("1")
        case "O": return .char("0")
        default: return alphabet.contains(up) ? .char(up) : .refused
        }
    }

    /// A typed code (the 32 characters alone) in its canonical form, or nil when it is not one.
    public static func normalize(_ typed: String) -> String? {
        var out = ""
        for ch in typed {
            switch canonical(ch) {
            case .separator: continue
            case .refused: return nil
            case .char(let c): out.append(c)
            }
            if out.count > length { return nil }
        }
        return out.count == length ? out : nil
    }

    /// The characters in groups of four (`ABCD EFGH …`).
    public static func grouped(_ code: String) -> String {
        let chars = Array(code)
        return stride(from: 0, to: chars.count, by: group)
            .map { String(chars[$0..<min($0 + group, chars.count)]) }
            .joined(separator: " ")
    }
}
