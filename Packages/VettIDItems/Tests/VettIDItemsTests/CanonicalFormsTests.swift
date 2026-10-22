import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDItems

// The cases are one per line.
// swiftlint:disable line_length

/// One stored form per value kind (VAULT-MESSAGING §10.7 "Canonical forms" and "Phone values", 0.55.0; IOS-PLAN §4.8): the
/// cases of ANDROID-PLAN "Items: phone values and the tag preview", byte for byte.
@Suite struct CanonicalFormsTests {
    private func valid(_ kind: String, _ s: String) -> Bool { ItemChecks.valueProblems(kind, .text(s)).isEmpty }

    // MARK: - Phone values

    @Test func aPossibleNumberIsStoredInE164WithAndWithoutAPlus() {
        #expect(PhoneInput.stored("+44 20 7946 0958", region: "US") == "+442079460958")
        #expect(PhoneInput.stored("+442079460958", region: nil) == "+442079460958")
        #expect(PhoneInput.stored("020 7946 0958", region: "GB") == "+442079460958")
        #expect(PhoneInput.stored("02079460958", region: "GB") == "+442079460958")
        #expect(PhoneInput.stored("6502530000", region: "US") == "+16502530000")
        #expect(PhoneInput.stored("(650) 253-0000", region: "US") == "+16502530000")
        #expect(PhoneInput.stored("+1 650-253-0000", region: "GB") == "+16502530000")
        #expect(PhoneInput.stored("030123456", region: "DE") == "+4930123456")
        #expect(PhoneInput.stored("+4930123456", region: "US") == "+4930123456")
        // The region decides how the digits are read: a possible number of the region it is typed in.
        #expect(PhoneInput.stored("6502530000", region: "GB") == "+446502530000")
    }

    @Test func aNumberThatDoesNotParseIsStoredAsItsDialableCharacters() {
        // No `+` and no region: the number is not read (the "unknown region" path).
        #expect(PhoneInput.stored("6502530000", region: nil) == "6502530000")
        #expect(PhoneInput.stored("555 12", region: "US") == "55512")
        #expect(PhoneInput.stored("(555) 12", region: "US") == "55512")
        #expect(PhoneInput.stored("+1 (555) 12", region: "US") == "+155512")
        #expect(PhoneInput.stored("+999 1234", region: "US") == "+9991234")
    }

    @Test func aLocalOnlyNumberGetsTheFallbackForm() {
        // 253-0000 is a number of the US that is dialled locally only (`IS_POSSIBLE_LOCAL_ONLY`).
        #expect(PhoneInput.stored("253-0000", region: "US") == "2530000")
        #expect(PhoneInput.doubtful("253-0000", region: "US"))
    }

    @Test func aNumberLongerThanFifteenDigitsIsCutToFifteen() {
        #expect(PhoneInput.stored("+1234567890123456789", region: "US") == "+123456789012345")
        #expect(PhoneInput.stored("12345678901234567890", region: nil) == "123456789012345")
        #expect(PhoneInput.stored("12345678901234567890", region: "US").filter(\.isNumber).count <= 15)
    }

    @Test func textWithoutADigitIsEmpty() {
        for t in ["", " ", "+", "call me", "()-"] { #expect(PhoneInput.stored(t, region: "US") == "", "\(t)") }
        #expect(!PhoneInput.doubtful("", region: "US") && !PhoneInput.doubtful("+", region: "US"))
    }

    @Test func noStoredPhoneHoldsASpaceOrPunctuationAndEveryOneIsValid() {
        let typed = ["+44 20 7946 0958", "020 7946 0958", "(650) 253-0000", "+1 (555) 12", "55512", "1.2.3.4.5", "+44 (0)20 7946 0958", "00442079460958", "011 44 20 7946 0958"]
        for t in typed {
            for region in ["US", "GB", nil] as [String?] {
                let s = PhoneInput.stored(t, region: region)
                #expect(s.allSatisfy { $0.isNumber || $0 == "+" }, "\(t) \(region ?? "nil")")
                #expect(valid(FieldKinds.phone, s) || s.isEmpty, "\(t) \(region ?? "nil")")
                // Storing a stored number changes nothing.
                #expect(PhoneInput.stored(s, region: region) == s, "\(t) \(region ?? "nil")")
            }
        }
        // An international call prefix and a trunk zero are read as a number does.
        #expect(PhoneInput.stored("00442079460958", region: "GB") == "+442079460958")
        #expect(PhoneInput.stored("011 44 20 7946 0958", region: "US") == "+442079460958")
        #expect(PhoneInput.stored("+44 (0)20 7946 0958", region: "US") == "+442079460958")
    }

    @Test func anExtensionIsNeverStored() {
        for t in ["+44 20 7946 0958 x123", "+44 20 7946 0958 X123", "+44 20 7946 0958 ext. 123", "+44 20 7946 0958;ext=123", "+44 20 7946 0958,123", "+44 20 7946 0958 #123", "+44 20 7946 0958 EXT 123", "+44 20 7946 0958 Ext.123"] {
            #expect(PhoneInput.stored(t, region: "US") == "+442079460958", "\(t)")
            #expect(PhoneInput.hasExtension(t), "\(t)")
        }
        // An unparsed number keeps its digits, the extension's digits never glued on.
        #expect(PhoneInput.stored("123 ext 4", region: "US") == "123")
        #expect(PhoneInput.stored("123 ext 4", region: nil) == "123")
        #expect(!PhoneInput.hasExtension("+44 20 7946 0958") && !PhoneInput.hasExtension(""))
        #expect(PhoneInput.hasExtension("123 ext 4"))
    }

    @Test func aMarkerNeedsADigitBeforeIt() {
        // VAULT-MESSAGING 0.55.1 (ANDROID-PLAN 0.1.66): these hold no extension.
        for t in ["Fax: +44 20 7946 0958", "Text 555 0100", "#123", "x123", "ext. 5", ",123", "Text 6502530000"] { #expect(!PhoneInput.hasExtension(t), "\(t)") }
        // A `+` before the first digit counts, wherever it is.
        #expect(PhoneInput.stored("Fax: +44 20 7946 0958", region: "US") == "+442079460958")
        #expect(PhoneInput.raw("Fax: +44 20 7946 0958") == "+442079460958")
        #expect(PhoneInput.stored("Text +1 650 253 0000", region: "US") == "+16502530000")
        #expect(PhoneInput.stored("Text 555 0100", region: "US") == "5550100")
        #expect(PhoneInput.stored("#123", region: "US") == "123")
        #expect(PhoneInput.stored("x123", region: "US") == "123")
        // A `+` after a digit is not a leading one.
        #expect(PhoneInput.raw("12+34") == "1234")
        // The marker text stays as typed until the save, and typing on changes nothing held.
        for typed in [",123", "#123", "ext. 123", "x123"] {
            let held = PhoneInput.edit("+442079460958" + typed)
            #expect(held == "+442079460958" + typed, "\(typed)")
            #expect(PhoneInput.stored(held, region: "US") == "+442079460958")
            #expect(PhoneInput.edit(held) == held)
        }
    }

    @Test func theExtensionStaysInTheEditTextUntilTheFieldIsSaved() {
        #expect(PhoneInput.edit("+44 20 7946 0958 x123") == "+442079460958x123")
        #expect(PhoneInput.edit("020 7946 0958;ext=12") == "02079460958;ext=12")
        #expect(PhoneInput.hasExtension(PhoneInput.edit("+44 20 7946 0958 x1")))
        // Characters typed before any marker are filtered; the extension is as typed (a letter in it too).
        #expect(PhoneInput.edit("+44a 20") == "+4420")
        #expect(PhoneInput.mask("+442079460958x123", region: "US").hasSuffix(" x123"))
    }

    @Test func aStoredSpacedNumberIsShownAndNotRewrittenUntilItsFieldIsSaved() {
        // Written by an earlier app (0.54.0 on staging): shown as every phone value is.
        #expect(PhoneInput.display("+44 20 7946 0958", region: "GB") == "020 7946 0958")
        #expect(PhoneInput.display("+44 20 7946 0958", region: "US") == "+44 20 7946 0958")
        #expect(PhoneInput.display("+442079460958", region: "GB") == "020 7946 0958")
        #expect(PhoneInput.display("+442079460958", region: "US") == "+44 20 7946 0958")
        #expect(PhoneInput.display("+16502530000", region: "US") == "(650) 253-0000")
        #expect(PhoneInput.display("+16502530000", region: "GB") == "+1 650-253-0000")
        // What the library does not read is shown as stored.
        #expect(PhoneInput.display("55512", region: "US") == "55512" && PhoneInput.display("", region: "US") == "")
        #expect(valid(FieldKinds.phone, "+44 20 7946 0958"))
    }

    @Test func theAsYouTypeFormatIsDrawnOverTheDigits() {
        var held = ""
        for c in "6502530000" { held = PhoneInput.edit(held + String(c)) }
        #expect(held == "6502530000")
        #expect(PhoneInput.mask(held, region: "US") == "(650) 253-0000")
        #expect(PhoneInput.mask("+442079460958", region: "US") == "+44 20 7946 0958")
        #expect(PhoneInput.mask("02079460958", region: "GB") == "020 7946 0958")
        #expect(PhoneInput.mask("6502530000", region: nil) == "6502530000")
        #expect(PhoneInput.mask("", region: "US") == "")
    }

    @Test func theDigitsAreCutToFifteenBeforeTheyAreRead() {
        // As vettid-android: `raw` takes 15 digits, then `stored` parses them.
        #expect(PhoneInput.stored("+49 12345678901234", region: "DE") == "+491234567890123")
        #expect(PhoneInput.stored("9712345678901234", region: "AE") == "+971234567890123")
        #expect(PhoneInput.stored("+4303456789012345", region: "AT") == "+43345678901234")
    }

    @Test func theHintFollowsValidityNotPossibility() {
        // As vettid-android's `doubtful` (libphonenumber `isValidNumber`).
        let doubtful: [(String, String)] = [("555 555 5555", "US"), ("+1 555 555 5555", "US"), ("876 123 4567", "JM"), ("054-123-4567", "IL"), ("0549 123456", "SM"), ("+882 1234 5678 90", "US"), ("55512", "US")]
        for (t, r) in doubtful { #expect(PhoneInput.doubtful(t, region: r), "\(t) \(r)") }
        for (t, r) in [("6502530000", "US"), ("+442079460958", "US"), ("020 7946 0958", "GB"), ("", "US")] { #expect(!PhoneInput.doubtful(t, region: r), "\(t) \(r)") }
        #expect(PhoneInput.doubtful("6502530000", region: nil))
        // A possible number that is not valid is still stored in E.164.
        #expect(PhoneInput.stored("555 555 5555", region: "US") == "+15555555555")
    }

    @Test func aNumberThatIsNotValidIsShownAsStoredAndTheCountryCodeDrawsInternationalFormat() {
        #expect(PhoneInput.display("+15555555555", region: "US") == "+15555555555")
        #expect(PhoneInput.mask("+16502530000", region: "DE") == "+1 650-253-0000")
        #expect(PhoneInput.mask("+1650", region: "DE") == "+1 650")
        #expect(PhoneInput.mask("+16502", region: "DE") == "+1 650-2")
        #expect(PhoneInput.mask("6502", region: "US") == "650-2")
        #expect(PhoneInput.mask("030123456", region: "DE") == "030 123456")
        #expect(PhoneInput.mask("+4930123456", region: "US") == "+49 30 123456")
    }

    @Test func deletingOnlyDrawnSeparatorsDeletesTheDigitBeforeThem() {
        let shown = "(650) 253-0000"
        // Backspace over the space after ")", over ")", over "-" and over "(".
        #expect(PhoneInput.afterDeletion(shown: shown, typed: "(650)253-0000") == "(65)253-0000")
        #expect(PhoneInput.afterDeletion(shown: shown, typed: "(650 253-0000") == "(65 253-0000")
        #expect(PhoneInput.afterDeletion(shown: shown, typed: "(650) 2530000") == "(650) 250000")
        // A digit deleted, a paste, an insertion and an extension are as typed.
        #expect(PhoneInput.afterDeletion(shown: shown, typed: "(650) 253-000") == "(650) 253-000")
        #expect(PhoneInput.afterDeletion(shown: shown, typed: "(650) 253-00001") == "(650) 253-00001")
        #expect(PhoneInput.afterDeletion(shown: "(650) 253-0000 x1", typed: "(650) 253-0000x1") == "(650) 253-0000x1")
        // Nothing before the separator to delete.
        #expect(PhoneInput.afterDeletion(shown: "(650", typed: "650") == "650")
        // The edit text that results has one digit less.
        let after = PhoneInput.afterDeletion(shown: "(650) 253", typed: "(650)253")
        #expect(PhoneInput.edit(after) == "65253")
    }

    // MARK: - The other kinds

    @Test func numbersAreStoredAsTypedTrimmedWithOneLeadingPlusDropped() {
        // VAULT-MESSAGING 0.55.2: a code such as 007 is not changed.
        let cases = [("007", "007"), (" 1.0 ", "1.0"), ("+5", "5"), ("-0", "-0"), ("0.50", "0.50"), ("+-5", "-5"), ("-0.0", "-0.0"), ("\u{00A0}42\u{3000}", "42"), ("100", "100")]
        for (typed, stored) in cases {
            #expect(CanonicalForms.number(typed) == stored, "\(typed)")
            #expect(valid(FieldKinds.number, stored), "\(typed)")
            #expect(CanonicalForms.number(stored) == stored)
        }
        // Still refused by the grammar, with the existing message.
        for t in ["5.", ".5", "++5", "-", "1e5", "abc"] { #expect(!valid(FieldKinds.number, CanonicalForms.number(t)), "\(t)") }
        #expect(CanonicalForms.number("++5") == "+5")
    }

    @Test func datesKeepTheirForm() {
        #expect(CanonicalForms.date("2031-04-30", month: false) == "2031-04-30")
        #expect(CanonicalForms.date("2031-04", month: true) == "2031-04")
        #expect(CanonicalForms.date("2031-04-30", month: true) == "2031-04")
        // A day is never invented.
        #expect(CanonicalForms.date("2031-04", month: false) == "2031-04")
    }

    @Test func emailsAreTrimmedAndTheirDomainLowerCased() {
        #expect(CanonicalForms.email("  Sam.Smith@Example.COM \n") == "Sam.Smith@example.com")
        #expect(CanonicalForms.email("A@B.c") == "A@b.c")
        // After the last `@`.
        #expect(CanonicalForms.email("\"a@B\"@Example.org") == "\"a@B\"@example.org")
        #expect(CanonicalForms.email("no-at") == "no-at")
        // Only ASCII letters change case.
        #expect(CanonicalForms.email("a@ÉXAMPLE.com") == "a@Éxample.com")
        // White space is Unicode White_Space: a no-break space and an ideographic space are trimmed too.
        #expect(CanonicalForms.email("\u{00A0}a@B.c\u{3000}") == "a@b.c")
    }

    @Test func urlsGetTheirSchemeAndHostLowerCased() {
        #expect(CanonicalForms.url("HTTP://Example.com/A") == "http://example.com/A")
        #expect(CanonicalForms.url("  HTTPS://User:Pw@Example.COM:8080/Path?Q=1#Frag ") == "https://User:Pw@example.com:8080/Path?Q=1#Frag")
        #expect(CanonicalForms.url("ftp://Host") == "ftp://host")
        #expect(CanonicalForms.url("https://[::1]:80/X") == "https://[::1]:80/X")
        #expect(CanonicalForms.url("MAILTO:a@b.c") == "mailto:a@b.c")
        #expect(CanonicalForms.url("Tel:+442079460958") == "tel:+442079460958")
        #expect(CanonicalForms.url("SMS:+15550100") == "sms:+15550100")
        #expect(CanonicalForms.url("localhost:8080/x") == "https://localhost:8080/x")
        #expect(CanonicalForms.url("Example.com/A") == "https://example.com/A")
        #expect(CanonicalForms.url("") == "")
        for s in ["http://example.com/A", "mailto:a@b.c", "https://localhost:8080/x"] { #expect(valid(FieldKinds.url, s)) }
    }

    @Test func aBareSecretBecomesAnOtpauthUri() {
        let secret = "JBSWY3DPEHPK3PXP"
        #expect(CanonicalForms.otp("jbsw y3dp ehpk 3pxp", label: "Bank") == "otpauth://totp/Bank?secret=\(secret)&algorithm=SHA1&digits=6&period=30")
        #expect(CanonicalForms.otp("\(secret)====", label: "Bank") == "otpauth://totp/Bank?secret=\(secret)&algorithm=SHA1&digits=6&period=30")
        // The label as UTF-8, every byte but A-Za-z0-9-._~ as upper-case %XX.
        #expect(CanonicalForms.percentEncoded("Work: 2FA é") == "Work%3A%202FA%20%C3%A9")
        #expect(CanonicalForms.percentEncoded("a-b_c.d~e") == "a-b_c.d~e")
        #expect(CanonicalForms.percentEncoded("a/b?c#d&e=f+g%h") == "a%2Fb%3Fc%23d%26e%3Df%2Bg%25h")
        #expect(CanonicalForms.otp(secret, label: "Work: 2FA é") == "otpauth://totp/Work%3A%202FA%20%C3%A9?secret=\(secret)&algorithm=SHA1&digits=6&period=30")
        #expect(valid(FieldKinds.otp, CanonicalForms.otp(secret, label: "Work: 2FA é")))
        // Not a base32 secret: left for the check to refuse.
        #expect(CanonicalForms.otp("short", label: "Bank") == "short")
    }

    @Test func anOtpauthUriKeepsItsParametersAndHasItsSecretCanonical() {
        #expect(CanonicalForms.otp("otpauth://totp/VettID:sam?issuer=VettID&secret=jbsw y3dp=ehpk3pxp&digits=8", label: "x") == "otpauth://totp/VettID:sam?issuer=VettID&secret=JBSWY3DPEHPK3PXP&digits=8")
        #expect(CanonicalForms.otp("OTPAUTH://totp/A?secret=jbswy3dpehpk3pxp", label: "x") == "otpauth://totp/A?secret=JBSWY3DPEHPK3PXP")
        let same = "otpauth://totp/VettID:sam?secret=JBSWY3DPEHPK3PXP&issuer=VettID"
        #expect(CanonicalForms.otp(same, label: "x") == same)
    }

    @Test func anAddressIsTrimmedAndCollapsed() {
        let a = AddressValue(street: "  12   High \t Street ", street2: "   ", city: " London\u{00A0}\u{00A0}Town ", region: " greater  london", postalCode: " sw1a  1aa ", country: " gb ")
        let c = CanonicalForms.address(a)
        #expect(c == AddressValue(street: "12 High Street", street2: "", city: "London Town", region: "greater london", postalCode: "SW1A 1AA", country: "GB"))
        #expect(CanonicalForms.address(c) == c)
        #expect(ItemChecks.valueProblems(FieldKinds.address, .address(c)).isEmpty)
        // No case change but the postal code and the country; ASCII only.
        #expect(CanonicalForms.address(AddressValue(city: "ÉCOLE", postalCode: "é1")).postalCode == "é1")
    }

    @Test func textIsTrimmedAndPasswordsAndMultilineAreNot() {
        let t = DraftField(label: "  Note  ", kind: FieldKinds.text, text: "\t a  b \u{2003}")
        #expect(CanonicalForms.field(t, touched: true, region: nil).text == "a  b" && CanonicalForms.field(t, touched: true, region: nil).label == "Note")
        let p = DraftField(label: "Pw", kind: FieldKinds.password, text: "  pass word  ")
        #expect(CanonicalForms.field(p, touched: true, region: nil).text == "  pass word  ")
        let m = DraftField(label: "Memo", kind: FieldKinds.multiline, text: "  a\n b  \n")
        #expect(CanonicalForms.field(m, touched: true, region: nil).text == "  a\n b  \n")
        // The name is trimmed at both ends and otherwise as typed; the notes as typed.
        let d = CanonicalForms.draft(ItemDraft(name: "  My  Item \n", notes: "  as  typed \n"), original: nil, region: nil)
        #expect(d.name == "My  Item" && d.notes == "  as  typed \n")
    }

    @Test func canonicalisingTwiceChangesNothingAndEveryResultPassesTheTable() {
        let fields = [
            DraftField(label: "N", kind: FieldKinds.number, text: "-007.50"), DraftField(label: "D", kind: FieldKinds.date, text: "2031-04-30"),
            DraftField(label: "E", kind: FieldKinds.email, text: " A@B.C "), DraftField(label: "U", kind: FieldKinds.url, text: "Example.com/A"),
            DraftField(label: "P", kind: FieldKinds.phone, text: "020 7946 0958 x1"), DraftField(label: "O", kind: FieldKinds.otp, text: "jbswy3dpehpk3pxp"),
            DraftField(label: "A", kind: FieldKinds.address, address: AddressValue(street: " 1  Main ", postalCode: "ab1 2cd", country: "gb")),
            DraftField(label: "T", kind: FieldKinds.text, text: " t "),
        ]
        let once = CanonicalForms.draft(ItemDraft(name: " Item ", fields: fields), original: nil, region: "GB")
        let twice = CanonicalForms.draft(once, original: nil, region: "GB")
        #expect(once == twice)
        #expect(ItemChecks.check(once).ok)
        #expect(once.fields.map(\.text) == ["-007.50", "2031-04-30", "A@b.c", "https://example.com/A", "+442079460958", "otpauth://totp/O?secret=JBSWY3DPEHPK3PXP&algorithm=SHA1&digits=6&period=30", "", "t"])
    }

    // MARK: - Only what the member edited

    @Test func aFieldTheMemberDidNotTouchIsSentExactlyAsStored() {
        let stored = [
            DraftField(fieldID: "f1", label: " Odd ", kind: FieldKinds.text, text: " padded "), DraftField(fieldID: "f2", label: "N", kind: FieldKinds.number, text: "1.0"),
            DraftField(fieldID: "f3", label: "U", kind: FieldKinds.url, text: "HTTP://Example.com/A"), DraftField(fieldID: "f4", label: "P", kind: FieldKinds.phone, text: "+44 20 7946 0958"),
            DraftField(fieldID: "f5", label: "S", kind: FieldKinds.otp, kept: true),
        ]
        let original = ItemDraft(name: " Name ", fields: stored)
        #expect(CanonicalForms.draft(original, original: original, region: "GB") == original)
        // Editing one field gives that field its canonical form and no other.
        var edited = original
        edited.fields[1].text = "2.50"
        edited.fields[3].text = "+44 20 7946 0958 x1"
        let out = CanonicalForms.draft(edited, original: original, region: "GB")
        #expect(out.fields[0] == stored[0] && out.fields[2] == stored[2] && out.fields[4] == stored[4])
        #expect(out.fields[1].text == "2.50" && out.fields[3].text == "+442079460958" && out.name == " Name ")
        // A field added is the member's: canonical.
        edited.fields.append(DraftField(label: " New ", kind: FieldKinds.url, text: "Example.com"))
        #expect(CanonicalForms.draft(edited, original: original, region: "GB").fields[5].text == "https://example.com")
        #expect(CanonicalForms.draft(edited, original: original, region: "GB").fields[5].label == "New")
        // A value kept (never revealed) stays kept even when the field is relabelled.
        var relabelled = original
        relabelled.fields[4].label = " Seed "
        let kept = CanonicalForms.draft(relabelled, original: original, region: nil).fields[4]
        #expect(kept.kept && kept.text == "" && kept.label == "Seed")
    }

    @Test func theCanonicalResultIsCheckedAgainstTheTableAndTheSizeLimit() {
        // A value that is not a decimal or an address of the table is refused, as before.
        let bad = ItemDraft(name: "X", fields: [DraftField(label: "N", kind: FieldKinds.number, text: "1e5")])
        #expect(ItemChecks.check(CanonicalForms.draft(bad, original: nil, region: nil)).fieldProblems[0] == [.valueInvalid])
        // The size is counted on the canonical form: an otpauth URI is longer than its secret.
        let secret = String(repeating: "A", count: 256)
        let sized = ItemDraft(name: "X", sensitivity: .critical, fields: (0..<40).map { DraftField(label: "OTP \($0)", kind: FieldKinds.otp, text: secret) })
        let before = ItemChecks.check(sized)
        let after = ItemChecks.check(CanonicalForms.draft(sized, original: nil, region: nil))
        #expect(before.size <= ItemChecks.maxCriticalBytes && !before.problems.contains(.tooLarge))
        #expect(after.size > ItemChecks.maxCriticalBytes && after.problems.contains(.tooLarge))
    }
}

/// The save of the edit screen sends the canonical form of what the member edited, and the rest as stored.
@MainActor
@Suite struct CanonicalSaveTests {
    let f = EditFixture()

    private func item() -> ItemDetail {
        ItemDetail(
            itemID: "i1", version: 1, name: "Contact", category: "contact", sensitivity: .data, tags: [],
            fields: [
                ItemFieldView(fieldID: "f1", label: "Phone", kind: FieldKinds.phone, value: .text("+44 20 7946 0958")),
                ItemFieldView(fieldID: "f2", label: "Site", kind: FieldKinds.url, value: .text("HTTP://Example.com/A")),
                ItemFieldView(fieldID: "f3", label: "Count", kind: FieldKinds.number, value: .text("1.0")),
            ],
            revealed: true
        )
    }

    private func loaded() async -> ItemEditViewModel {
        f.items.add(item())
        let vm = ItemEditViewModel(itemID: "i1", items: f.items, sharing: f.sharing, connections: f.connections, impactDelay: .zero, region: "GB")
        await vm.settle()
        return vm
    }

    @Test func untouchedFieldsAreSentAsStoredAndTheEditedOneCanonically() async throws {
        let vm = await loaded()
        vm.setName("Contact card")
        vm.save()
        await vm.settle()
        #expect(try #require(f.stored("i1")).fields.map(\.value) == [.text("+44 20 7946 0958"), .text("HTTP://Example.com/A"), .text("1.0")])
        let again = await loaded()
        again.setFieldText(0, "020 7946 0958 x9")
        again.setFieldText(1, "HTTP://Example.com/A ")
        again.save()
        await again.settle()
        #expect(try #require(f.stored("i1")).fields.map(\.value) == [.text("+442079460958"), .text("http://example.com/A"), .text("1.0")])
    }

    @Test func theChecksSeeTheCanonicalForm() async {
        let vm = await loaded()
        // A trailing space is not a valid email, but it is trimmed on save: no problem is shown for it.
        vm.setFieldText(2, "007.50")
        #expect(vm.state.check.ok)
    }
}

// swiftlint:enable line_length
