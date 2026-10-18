import Foundation
import Testing
@testable import VettIDAltChan
import VettIDCrypto

/// The typed recovery code (VAULT-MESSAGING §11.11.10): normalization, the check characters against §16's vector, and
/// the ``RecoveryCode`` a typed entry gives, which must be the scanned one's. Every value is the spec's public TEST ONLY
/// vector or made up. Mirrors vettid-android `RecoveryTypedTest`.
struct RecoveryTypedTests {
    private let production = "https://account.vettid.org"
    private let staging = "https://account.staging.vettid.org"

    // §16, TEST ONLY.
    private let locator = "7ZK3M9QX2HTD"
    private let code = "CDEFGHJKMNPQRSTVWXYZ0123456789AB"
    private var typed: String { locator + code + "V3A1" }
    private let grouped = "7ZK3 M9QX 2HTD CDEF GHJK MNPQ RSTV WXYZ 0123 4567 89AB V3A1"

    private func ok(_ text: String, api: String? = nil) throws -> TypedRecoveryCode {
        guard case .ok(let c) = TypedRecoveryCode.parse(text, api: api ?? production) else { throw AltResultError("not ok") }
        return c
    }

    private func replacing(_ s: String, _ a: Character, _ b: Character) -> String { String(s.map { $0 == a ? b : $0 }) }

    @Test func theCheckCharactersMatchTheSpecsVectorForBothOrigins() throws {
        #expect(try RecoveryCodes.typedCheck(api: production, locator: locator, code: code) == "V3A1")
        #expect(try RecoveryCodes.typedCheck(api: staging, locator: locator, code: code) == "J5JH")
        // The hashed bytes: the 33-byte label, 0x00, the origin, 0x00, the 44 characters; the first 20 bits.
        let label = Array("vettid/vms/2/recovery-typed-check".utf8)
        let bytes = label + [0] + Array(production.utf8) + [0] + Array((locator + code).utf8)
        #expect(bytes.count == 33 + 1 + production.utf8.count + 1 + 44)
        let digest = "d8d41816e4cf5ac83a89a6472d2ab0b63197207dc80e77e77bd95f50214ae1c4"
        #expect(Bytes.hex(Bytes.sha256(bytes)) == digest)
        // The origin in the portal's form: no trailing slash, lower case.
        #expect(try RecoveryCodes.typedCheck(api: production + "/", locator: locator, code: code) == "V3A1")
        #expect(try RecoveryCodes.typedCheck(api: "https://Account.VettID.org", locator: locator, code: code) == "V3A1")
        #expect(RecoveryCodes.grouped(typed) == grouped)
        #expect(RecoveryCodes.typedLength == 48)
        #expect(RecoveryCodes.typedGroups == 12)
        let short = String(locator.dropLast())
        #expect(throws: AltResultError.self) { try RecoveryCodes.typedCheck(api: production, locator: short, code: code) }
        #expect(throws: AltResultError.self) { try RecoveryCodes.typedCheck(api: production, locator: locator, code: code.lowercased()) }
    }

    @Test func typedTextIsNormalizedToThe48CanonicalCharacters() {
        #expect(RecoveryCodes.normalizeTyped(typed) == typed)
        #expect(RecoveryCodes.normalizeTyped(typed.lowercased()) == typed, "case")
        #expect(RecoveryCodes.normalizeTyped(grouped) == typed, "spaces")
        #expect(RecoveryCodes.normalizeTyped(replacing(grouped, " ", "-")) == typed, "hyphens")
        let spaced = " " + grouped.replacingOccurrences(of: " 0123", with: "\r\n0123\t")
            .replacingOccurrences(of: " V3A1", with: "\u{00A0}V3A1") + "\n"
        #expect(RecoveryCodes.normalizeTyped(spaced) == typed, "line breaks, tabs, a no-break space")
        // Crockford's look-alikes, which the canonical form never contains: I and L read as 1, O as 0, in either case.
        let alike = replacing(replacing(grouped, "1", "I"), "0", "O")
        #expect(alike.contains("I") && alike.contains("O"))
        #expect(RecoveryCodes.normalizeTyped(alike) == typed)
        #expect(RecoveryCodes.normalizeTyped(replacing(replacing(grouped, "1", "l"), "0", "o")) == typed)
        #expect(RecoveryCodes.normalizeTyped(replacing(grouped, "1", "L")) == typed)
        #expect(RecoveryCodes.normalizeTyped(replacing(grouped, "1", "i")) == typed)
        // U is not in the alphabet and is never mapped; any other character is refused the same way.
        #expect(RecoveryCodes.normalizeTyped(replacing(typed, "V", "U")) == nil)
        #expect(RecoveryCodes.normalizeTyped(replacing(typed, "V", "u")) == nil)
        for c in ["!", ".", "_", "/", "é", "Ω", "٣"] {
            #expect(RecoveryCodes.normalizeTyped(String(typed.dropLast()) + c) == nil, "\(c)")
        }
        // Lengths.
        #expect(RecoveryCodes.normalizeTyped("") == nil)
        #expect(RecoveryCodes.normalizeTyped(String(typed.dropLast())) == nil)
        #expect(RecoveryCodes.normalizeTyped(typed + "0") == nil)
        #expect(RecoveryCodes.normalizeTyped(code) == nil, "the bare code")
        // The bare code's own rule is unchanged.
        #expect(RecoveryCodes.normalize(RecoveryCodes.grouped(code.lowercased()).replacingOccurrences(of: " ", with: "-")) == code)
        #expect(RecoveryCodes.normalize(typed) == nil)
        #expect(RecoveryCodes.isLocator(locator))
        #expect(!RecoveryCodes.isLocator(locator.lowercased()))
        #expect(!RecoveryCodes.isLocator(locator + "0"))
        #expect(!RecoveryCodes.isLocator("7ZK3M9QX2HTU"))
    }

    @Test func theFieldTakesWhatIsValidAndNamesTheFirstRefusedCharactersGroup() {
        let empty = RecoveryCodes.typedInput("")
        #expect(empty.text.isEmpty && empty.refused == nil && empty.groups == 0)

        let part = RecoveryCodes.typedInput("7zk3-m9qx 2h")
        #expect(part.text == "7ZK3M9QX2H" && part.refused == nil && part.groups == 2 && !part.complete)

        #expect(RecoveryCodes.typedInput("iLoO").text == "1100", "look-alikes are read as typed")

        // A U is dropped, not guessed to be a V: the 13th character would have gone into group 4.
        let u = RecoveryCodes.typedInput(locator + "u")
        #expect(u.text == locator && u.refused == .letterU && u.refusedGroup == 4)
        #expect(RecoveryCodes.typedInput("U").refusedGroup == 1)
        #expect(RecoveryCodes.typedInput("7ZKU").refusedGroup == 1)
        #expect(RecoveryCodes.typedInput("7ZK3U").refusedGroup == 2)

        let other = RecoveryCodes.typedInput("7ZK3 M9!X")
        #expect(other.text == "7ZK3M9X" && other.refused == .other && other.refusedGroup == 2)

        // The first refused character is the one named; the valid ones of a paste are kept.
        let both = RecoveryCodes.typedInput("7ZK3 ?9QU 2HTD")
        #expect(both.text == "7ZK39Q2HTD" && both.refused == .other && both.refusedGroup == 2)

        let full = RecoveryCodes.typedInput(grouped.lowercased())
        #expect(full.text == typed && full.complete && full.groups == 12)
        // A forty-ninth character is ignored, whatever it is.
        for extra in ["0", "U", "!", "ABCD"] {
            let more = RecoveryCodes.typedInput(typed + extra)
            #expect(more.text == typed && more.refused == nil, "\(extra)")
        }
        #expect(!full.description.contains("7ZK3"), "the characters are never printed")
    }

    @Test func onlyAStringWhoseCheckMatchesThisAppsOriginBecomesACode() throws {
        let c = try ok(grouped.lowercased())
        #expect(c.locator == locator && c.code == code)
        #expect(try ok(typed) == c)
        #expect(try ok(typed).hashValue == c.hashValue)
        #expect(!"\(c)".contains(locator) && !String(reflecting: c).contains(code), "never printed")
        #expect(try ok(typed, api: production + "/") == c)

        // A staging string is refused by a production build, and the other way round (§11.11.10).
        let stagingTyped = locator + code + "J5JH"
        #expect(TypedRecoveryCode.parse(stagingTyped, api: production) == .badCheck)
        #expect(TypedRecoveryCode.parse(typed, api: staging) == .badCheck)
        #expect(try ok(stagingTyped, api: staging) == c)

        // One mistyped character anywhere: in the locator, in the code, in the check characters.
        let chars = Array(typed)
        for i in [0, 11, 12, 43, 44, 47] {
            var wrong = chars
            wrong[i] = chars[i] == "Z" ? "Y" : "Z"
            #expect(TypedRecoveryCode.parse(String(wrong), api: production) == .badCheck, "position \(i)")
        }
        // Two groups swapped.
        let swapped = String(chars[4..<8]) + String(chars[0..<4]) + String(chars[8...])
        #expect(TypedRecoveryCode.parse(swapped, api: production) == .badCheck)

        // Lengths and characters: not a typed code at all.
        #expect(TypedRecoveryCode.parse("", api: production) == .notTyped)
        #expect(TypedRecoveryCode.parse(String(typed.dropLast()), api: production) == .notTyped)
        #expect(TypedRecoveryCode.parse(typed + "0", api: production) == .notTyped)
        #expect(TypedRecoveryCode.parse(replacing(typed, "V", "U"), api: production) == .notTyped)
        // The bare 32 characters an account page showed before MEMBER-API 2.4.0.
        #expect(TypedRecoveryCode.parse(code, api: production) == .bareCode)
        #expect(TypedRecoveryCode.parse(RecoveryCodes.grouped(code).lowercased(), api: production) == .bareCode)
    }

    @Test func aTypedCodeGivesTheSameRecoveryCodeAsTheScannedQrOfThatRecovery() throws {
        let vid = "0123456789abcdef0123456789abcdef"
        let rid = "01JA0RECVERY0000000000001X"
        let qr = #"{"v":1,"t":"r","api":"\#(production)","vault_id":"\#(vid)","recovery_id":"\#(rid)","code":"\#(code)"}"#
        let scanned = try #require(RecoveryCode.parseScanned(qr))
        let claimed = Claimed(userGuid: "guid-1", emailHint: "s***@example.org", vaultID: vid, recoveryID: rid)
        let fromTyped = try ok(typed).recoveryCode(claimed: claimed, api: production)
        #expect(fromTyped == scanned)
        #expect(fromTyped.api == scanned.api)
        #expect(try ok(typed).recoveryCode(claimed: claimed, api: production + "/") == scanned)

        // An answer without the identifiers (an API before 2.4.0), or with ones a QR could not carry, is not used.
        let t = try ok(typed)
        #expect(throws: AltResultError.self) {
            try t.recoveryCode(claimed: Claimed(userGuid: "guid-1", emailHint: "", vaultID: nil, recoveryID: rid), api: production)
        }
        #expect(throws: AltResultError.self) {
            try t.recoveryCode(claimed: Claimed(userGuid: "guid-1", emailHint: "", vaultID: vid, recoveryID: nil), api: production)
        }
        #expect(throws: AltResultError.self) {
            try t.recoveryCode(claimed: Claimed(userGuid: "guid-1", emailHint: "", vaultID: vid, recoveryID: "not-a-ulid"), api: production)
        }
        #expect(throws: AltResultError.self) {
            try t.recoveryCode(claimed: Claimed(userGuid: "guid-1", emailHint: "", vaultID: "", recoveryID: rid), api: production)
        }
    }

    /// Read one scalar at a time, as Android reads one UTF-16 unit: a combining mark is refused on its own, the letter
    /// before it kept. Non-ASCII letters that upper-case into the alphabet are refused too (chosen; not in the spec).
    @Test func combiningMarksAndNonASCIILettersAreRefused() {
        #expect(RecoveryCodes.normalizeTyped(String(typed.dropLast()) + "A\u{0301}") == nil)
        let mark = RecoveryCodes.typedInput("7ZK3A\u{0301}B")
        #expect(mark.text == "7ZK3AB" && mark.refused == .other && mark.refusedGroup == 2)
        for c in ["\u{0131}", "\u{017F}"] { // ı, ſ: Android upper-cases them to I and S
            #expect(RecoveryCodes.normalizeTyped(String(typed.dropLast()) + c) == nil)
            #expect(RecoveryCodes.typedInput(c).refused == .other)
        }
        #expect(RecoveryCodes.normalizeTyped(grouped.replacingOccurrences(of: " 0123", with: "\r\n0123")) == typed, "CR LF")
    }

    /// Neither `dump`, the debugger's mirror nor `String(reflecting:)` shows a code or a locator.
    @Test func codesAreNeverDumped() throws {
        let c = try ok(typed)
        let input = RecoveryCodes.typedInput(typed)
        let qr = RecoveryCode(vaultID: "v", recoveryID: "01JA0RECVERY0000000000001X", code: code)
        for value in [c, input, qr] as [Any] {
            var dumped = ""
            dump(value, to: &dumped)
            for text in [dumped, String(reflecting: value), "\(value)"] {
                #expect(!text.contains(code) && !text.contains(locator), "\(type(of: value))")
            }
        }
    }
}
