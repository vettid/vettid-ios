import Foundation
import VettIDCrypto

/// The vault PIN rules the app enforces when a PIN is chosen (enrollment, PIN change). VAULT-MESSAGING requires 6–32
/// ASCII digits (§11.3); the app asks for at least ``minLength`` and refuses PINs that are guessed first (one repeated
/// digit, straight runs, short repeated patterns, the most common choices). The PIN is guessed only online, through the
/// enclave and its backoff (§11.8), so length beats complexity here. Mirrors vettid-android `PinPolicy`.
public enum PinPolicy {
    public static let minLength = 6
    public static let maxLength = 32
    private static let digits = 10
    private static let maxBlock = 3

    public enum Problem: Equatable, Sendable, CaseIterable { case notDigits, tooShort, tooLong, repeated, sequence, pattern, common }

    private static let commonPins: Set<String> = [
        "123123", "112233", "121212", "123321", "654321", "696969", "159753", "147258", "258369", "102030",
        "111222", "123654", "131313", "520520", "112358", "246810", "135790", "142536", "789456", "456123",
        "100200", "098765", "012345", "123456789", "1234567890", "0123456789", "11223344",
    ]

    /// The first rule [pin] breaks, or nil if it is acceptable.
    public static func check(_ pin: String) -> Problem? {
        let d = pin.unicodeScalars.map { Int($0.value) - 0x30 }
        if d.isEmpty || !d.allSatisfy({ (0...9).contains($0) }) { return .notDigits }
        if d.count < minLength { return .tooShort }
        if d.count > maxLength { return .tooLong }
        if d.allSatisfy({ $0 == d[0] }) { return .repeated }
        if isRun(d, 1) || isRun(d, -1) { return .sequence }
        if commonPins.contains(pin) { return .common }
        if isRepeatedPattern(d) { return .pattern }
        return nil
    }

    /// Every digit is the previous one plus [step] (mod 10): 123456, 890123, 987654.
    private static func isRun(_ d: [Int], _ step: Int) -> Bool {
        (1..<d.count).allSatisfy { i in d[i] == ((d[i - 1] + step) % digits + digits) % digits }
    }

    /// A block of one to three digits repeated: 121212, 123123, 1212121.
    private static func isRepeatedPattern(_ d: [Int]) -> Bool {
        (1...maxBlock).contains { n in d.count >= 2 * n && d.indices.allSatisfy { d[$0] == d[$0 % n] } }
    }
}

/// The credential password (VAULT-MESSAGING §3.5.1: 8–1,024 UTF-8 bytes) and a strength estimate for the meter. The
/// password protects the credential and the critical items when the vault state is ever decrypted (§3.5.8), where it
/// can be guessed offline against Argon2id, so the app asks for a strong one: at least ``Strength/fair`` to continue.
/// Characters are counted as Unicode scalars (Android counts UTF-16 units: the same outside the supplementary planes).
/// Mirrors vettid-android `PasswordPolicy`.
public enum PasswordPolicy {
    public static let minBytes = 8
    public static let maxBytes = 1024
    private static let firstPrintable: UInt32 = 0x20
    private static let del: UInt32 = 0x7F

    public enum Strength: Int, Comparable, Sendable, CaseIterable {
        case tooShort, weak, fair, good, strong

        public static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Problem: Equatable, Sendable, CaseIterable { case tooShort, tooLong, tooWeak, sameAsPin, controlCharacters }

    private static let commonPasswords: Set<String> = [
        "password", "passw0rd", "12345678", "123456789", "qwertyui", "qwerty123", "iloveyou", "sunshine", "princess",
        "football", "baseball", "welcome1", "letmein1", "trustno1", "admin123", "abcd1234", "11111111", "00000000",
        "password1", "password123", "qwertyuiop", "1q2w3e4r", "zaq12wsx", "vettid123", "vettidvault",
    ]

    /// An estimate in five steps from length, character variety and obvious patterns.
    public static func strength(_ password: String) -> Strength { // swiftlint:disable:this cyclomatic_complexity
        // A scoring table.
        if password.utf8.count < minBytes { return .tooShort }
        let s = Array(password.unicodeScalars)
        let unique = Set(s).count
        if commonPasswords.contains(password.lowercased()) || unique <= 2 { return .weak }
        let classes = [
            s.contains { $0.properties.isLowercase },
            s.contains { $0.properties.isUppercase },
            s.contains(where: isDigit),
            s.contains { !isLetterOrDigit($0) },
        ].filter { $0 }.count
        var score = switch s.count {
        case 20...: 3
        case 14...: 2
        case 10...: 1
        default: 0
        }
        score += classes == 4 ? 2 : classes == 3 ? 1 : 0
        if s.filter({ $0 == " " }).count >= 2 && s.count >= 16 { score += 1 } // a passphrase
        if unique < s.count / 3 { score -= 1 }
        if s.allSatisfy(isDigit) { score -= 1 }
        switch score {
        case ...0: return .weak
        case 1: return .fair
        case 2, 3: return .good
        default: return .strong
        }
    }

    /// The first rule [password] breaks, or nil. [pin] is the vault PIN, which must not be reused.
    public static func check(_ password: String, pin: String? = nil) -> Problem? {
        let bytes = password.utf8.count
        if bytes < minBytes { return .tooShort }
        if bytes > maxBytes { return .tooLong }
        if password.unicodeScalars.contains(where: { $0.value < firstPrintable || $0.value == del }) { return .controlCharacters }
        if let pin, password == pin { return .sameAsPin }
        if strength(password) < .fair { return .tooWeak }
        return nil
    }

    /// Java's `Character.isDigit`: the decimal digits of every script.
    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c.properties.generalCategory == .decimalNumber }

    /// Java's `Character.isLetterOrDigit`.
    private static func isLetterOrDigit(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: true
        default: false
        }
    }
}

/// The password rules from release R (VAULT-MESSAGING §11.14.7; ANDROID-PLAN "Passwords"), as the member types: at
/// least 12 characters, not one character repeated, not on the common-password list, not the PIN, and an estimated
/// guessability above the vault's minimum (VettIDCrypto `PasswordRules`, with the app's slightly higher floor). Also the
/// limits every password has: at most 1,024 bytes, and (the app's own) no control characters. They replace
/// ``PasswordPolicy``'s meter for a new password at enrollment, a password change and a reset; the vault's verdict
/// (`weak_password{reason}`) is shown with the same texts (``fromVault(_:)``). Mirrors vettid-android `PasswordRule`.
public enum PasswordRule: Equatable, Sendable, CaseIterable {
    case short
    case repeated
    case common
    case sameAsPin
    case guessable
    case tooLong
    case controlCharacters
    /// The vault refused the password with a reason this app does not know: "This password is not strong enough."
    case vaultRefused
    /// "Strong enough."
    case ok

    private static let firstPrintable: UInt32 = 0x20
    private static let del: UInt32 = 0x7F

    public var passes: Bool { self == .ok }

    /// The first rule [password] breaks (or ``ok``); [pin] is the vault PIN when the screen knows it.
    public static func check(_ password: String, pin: String?) -> PasswordRule {
        let nfc = Passwords.nfc(password)
        if nfc.utf8.count > Passwords.maxBytes { return .tooLong }
        if nfc.unicodeScalars.contains(where: { $0.value < firstPrintable || $0.value == del }) { return .controlCharacters }
        switch PasswordRules.check(nfc, pin: pin?.isEmpty == false ? pin : nil) {
        case nil: return .ok
        case PasswordRules.short: return .short
        case PasswordRules.repeated: return .repeated
        case PasswordRules.common: return .common
        case PasswordRules.sameAsPin: return .sameAsPin
        default: return .guessable
        }
    }

    /// The vault's `weak_password` `reason`; a reason this app does not know (or none) is ``vaultRefused``.
    public static func fromVault(_ reason: String?) -> PasswordRule {
        switch reason {
        case PasswordRules.short: .short
        case PasswordRules.repeated: .repeated
        case PasswordRules.common: .common
        case PasswordRules.sameAsPin: .sameAsPin
        case PasswordRules.guessable: .guessable
        default: .vaultRefused
        }
    }
}

/// The phrase `vault.delete` requires (VAULT-MESSAGING §10.2, §12.5). Mirrors vettid-android `DeletePhrase`.
public enum DeletePhrase {
    public static let phrase = "delete my vault"

    /// Kotlin's `Char.isWhitespace`, which `trim()` drops: the space separators (Zs: U+0020, U+00A0, U+1680,
    /// U+2000–U+200A, U+202F, U+205F, U+3000), U+2028, U+2029, the ASCII controls TAB to CR, and U+001C to U+001F.
    private static let kotlinWhitespace = CharacterSet(
        charactersIn: "\u{20}\u{A0}\u{1680}\u{202F}\u{205F}\u{3000}\u{2028}\u{2029}\t\n\u{0B}\u{0C}\r\u{1C}\u{1D}\u{1E}\u{1F}"
    ).union(CharacterSet(charactersIn: "\u{2000}"..."\u{200A}"))

    public static func matches(_ input: String) -> Bool { input.trimmingCharacters(in: kotlinWhitespace) == phrase }
}
