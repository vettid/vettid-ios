import Foundation
import Testing
import VettIDData
@testable import VettIDItems

/// Formats enforced while typing and on paste (owner request 2026-10-08, VAULT-MESSAGING §10.7 kinds): what each kind lets
/// in, how a paste is normalised, and that what it lets through is what the vault's checks accept. Mirrors vettid-android
/// `FieldInputTest`.
@Suite struct FieldInputTests {
    private func valid(_ kind: String, _ s: String) -> Bool { ItemChecks.valueProblems(kind, .text(s)).isEmpty }

    @Test func numbersTakeDigitsOneMinusAndOnePoint() {
        #expect(FieldInput.number("-3.5") == "-3.5")
        #expect(FieldInput.number("4a2") == "42")
        #expect(FieldInput.number("1-2") == "12")
        #expect(FieldInput.number("1.2.5") == "1.25")
        #expect(FieldInput.number(".5") == "0.5")
        #expect(FieldInput.number("-.5") == "-0.5")
        // A decimal comma is a point; with a point too, commas group thousands (paste).
        #expect(FieldInput.number("3,5") == "3.5")
        #expect(FieldInput.number("1,234.50") == "1234.50")
        #expect(FieldInput.number("1 000 000") == "1000000")
        #expect(FieldInput.number("−7") == "-7")
        #expect(FieldInput.number(String(repeating: "9", count: 40)).count == 32)
        for v in ["-3.5", "42", "0.5", "1234.50"] { #expect(valid(FieldKinds.number, v), "\(v)") }
    }

    @Test func phonesTakeOnlyDigitsSpacesAndPlusMinusBracketsPoint() {
        #expect(FieldInput.phone("+44 (20) 7946-0000.") == "+44 (20) 7946-0000.")
        #expect(FieldInput.phone("+1 555 0100 ext#") == "+1 555 0100 ")
        #expect(FieldInput.phone("call") == "")
        #expect(FieldInput.phone(String(repeating: "1", count: 40)).count == 32)
        #expect(valid(FieldKinds.phone, FieldInput.phone("tel: +44 20 7946 0000")))
        #expect(PhoneInput.stored("+44 20 7946 0958") == "+44 20 7946 0958" && PhoneInput.display("555-12") == "555-12")
    }

    @Test func emailsAndUrlsHoldNoWhiteSpace() {
        #expect(FieldInput.accept(FieldKinds.email, " sam @example.org\n") == "sam@example.org")
        #expect(FieldInput.accept(FieldKinds.url, "https://example.com/ a") == "https://example.com/a")
        #expect(FieldInput.accept(FieldKinds.email, String(repeating: "a", count: 300)).count == 254)
        // Incomplete values say their rule while typing.
        #expect(FieldInput.incomplete(FieldKinds.email, "sam@"))
        #expect(!FieldInput.incomplete(FieldKinds.email, "sam@example.org"))
        #expect(FieldInput.incomplete(FieldKinds.url, "example.com"))
        #expect(!FieldInput.incomplete(FieldKinds.url, ""))
        #expect(!FieldInput.incomplete(FieldKinds.text, "anything"))
    }

    @Test func otpSecretsAreBase32InUpperCaseAndLinksKeepTheirCase() {
        // A key as sites show it: lower case, in groups.
        #expect(FieldInput.otp("jbsw y3dp ehpk 3pxp") == "JBSWY3DPEHPK3PXP")
        #expect(FieldInput.otp("JBSW-Y3DP-EHPK-3PXP") == "JBSWY3DPEHPK3PXP")
        // 0, 1, 8 and 9 are not in the alphabet.
        #expect(FieldInput.otp("A0B1C89") == "ABC")
        #expect(FieldInput.otp("JBSW=Y3DPEHPK3PXP==") == "JBSWY3DPEHPK3PXP==")
        // Typing the scheme stays as typed until it is one; then the link keeps its case.
        #expect(FieldInput.otp("OTP") == "otp")
        let uri = "otpauth://totp/VettID:sam?secret=JBSWY3DPEHPK3PXP&issuer=VettID"
        #expect(FieldInput.otp(uri) == uri)
        #expect(FieldInput.otp("OTPAUTH://totp/VettID:sam?secret=JBSWY3DPEHPK3PXP&issuer=VettID") == uri)
        #expect(valid(FieldKinds.otp, FieldInput.otp(" otpauth://totp/VettID:sam?secret=JBSWY3DPEHPK3PXP ")))
        #expect(valid(FieldKinds.otp, FieldInput.otp("jbsw y3dp ehpk 3pxp")))
    }

    @Test func aCountryIsTwoUpperCaseLetters() {
        #expect(FieldInput.country("de") == "DE")
        #expect(FieldInput.country("u.s.a") == "US")
    }

    @Test func aDateIsTypedAsDigitsAndStoredInTheSpecFormat() {
        var v = ""
        for c in "20310430" { v = DateInput.accept(old: v, typed: DateInput.digits(v) + String(c), monthOnly: false) ?? v }
        #expect(v == "2031-04-30" && valid(FieldKinds.date, v))
        #expect(DateInput.accept(old: "", typed: "2031", monthOnly: false) == "2031")
        #expect(DateInput.accept(old: "2031", typed: "20310", monthOnly: false) == "2031-0")
        // Letters and separators never get in; a ninth digit does not either.
        #expect(DateInput.accept(old: "2031-0", typed: "20310x4", monthOnly: false) == "2031-04")
        #expect(DateInput.accept(old: "2031-04-30", typed: "203104301", monthOnly: false) == "2031-04-30")
    }

    @Test func impossibleDatesAreRefused() {
        #expect(DateInput.accept(old: "2031", typed: "20312", monthOnly: false) == nil) // month 2x
        #expect(DateInput.accept(old: "2031-1", typed: "203113", monthOnly: false) == nil) // month 13
        #expect(DateInput.accept(old: "2031-0", typed: "203100", monthOnly: false) == nil) // month 00
        #expect(DateInput.accept(old: "2031-04", typed: "2031044", monthOnly: false) == nil) // day 4x
        #expect(DateInput.accept(old: "2031-02-3", typed: "20310230", monthOnly: false) == nil) // 30 February
        #expect(DateInput.accept(old: "2030-02-2", typed: "20300229", monthOnly: false) == nil) // not a leap year
        #expect(DateInput.accept(old: "2028-02-2", typed: "20280229", monthOnly: false) == "2028-02-29")
        // Taking a digit out of the middle always works, even if what is left is not a date yet.
        #expect(DateInput.accept(old: "2031-12-31", typed: "2031231", monthOnly: false) == "2031-23-1")
    }

    @Test func aPasteIsNormalised() {
        #expect(DateInput.accept(old: "", typed: "2031-04-30", monthOnly: false) == "2031-04-30")
        #expect(DateInput.accept(old: "", typed: "2031/04/30", monthOnly: false) == "2031-04-30")
        #expect(DateInput.accept(old: "", typed: " 2031.04.30 ", monthOnly: false) == "2031-04-30")
        #expect(DateInput.accept(old: "", typed: "30.04.2031", monthOnly: false) == nil)
    }

    @Test func aMonthAndYearStopsAtTheMonth() {
        #expect(DateInput.accept(old: "2031-04", typed: "20310430", monthOnly: true) == "2031-04")
        #expect(DateInput.accept(old: "", typed: "2031-04-30", monthOnly: true) == "2031-04")
        #expect(valid(FieldKinds.date, "2031-04"))
        #expect(DateInput.month(year: 2031, month: 4) == "2031-04")
        #expect(DateInput.isMonth("2031-04") && !DateInput.isMonth("2031-04-30"))
        #expect(DateInput.yearMonth("2031-04-30")! == (2031, 4) && DateInput.yearMonth("soon") == nil)
    }

    @Test func thePickersResultIsTheSpecFormat() throws {
        // The picker and the stored value go through the same calendar: in the zones furthest from UTC (UTC+14 and
        // UTC-11) the day picked is the day stored.
        for zone in ["UTC", "Pacific/Kiritimati", "Pacific/Pago_Pago", "Asia/Kolkata"] {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = try #require(TimeZone(identifier: zone))
            let day = try #require(DateInput.toPicker("2031-04-30", calendar: c))
            #expect(DateInput.fromPicker(day, calendar: c) == "2031-04-30", "\(zone)")
            #expect(c.dateComponents([.year, .month, .day], from: day) == DateComponents(year: 2031, month: 4, day: 30), "\(zone)")
            #expect(DateInput.toPicker("2031-04", calendar: c).map { DateInput.fromPicker($0, calendar: c) } == "2031-04-01", "\(zone)")
            let early = try #require(c.date(from: DateComponents(year: 5, month: 1, day: 9, hour: 12)))
            #expect(DateInput.fromPicker(early, calendar: c) == "0005-01-09", "\(zone)")
        }
        #expect(DateInput.toPicker("soon") == nil)
    }
}
