import Testing
import VettIDData

/// The PIN and password rules, release R's password rules and the delete phrase, with their texts. Mirrors
/// vettid-android `PoliciesTest`.
@Suite struct PoliciesTests {
    @Test func pinRules() {
        #expect(PinPolicy.check("") == .notDigits)
        #expect(PinPolicy.check("12a456") == .notDigits)
        #expect(PinPolicy.check("١٢٣٤٥٦") == .notDigits) // ASCII digits only (§11.3)
        #expect(PinPolicy.check("4821") == .tooShort)
        #expect(PinPolicy.check(String(repeating: "4", count: 16) + String(repeating: "9", count: 17)) == .tooLong)
        #expect(PinPolicy.check("000000") == .repeated)
        #expect(PinPolicy.check("123456") == .sequence)
        #expect(PinPolicy.check("987654") == .sequence)
        #expect(PinPolicy.check("890123") == .sequence)
        #expect(PinPolicy.check("454545") == .pattern)
        #expect(PinPolicy.check("846846") == .pattern)
        #expect(PinPolicy.check("696969") == .common)
        #expect(PinPolicy.check("97531086") == nil)
        #expect(PinPolicy.check("402817") == nil)
        // The spec allows 32 digits.
        #expect(PinPolicy.check("5" + String(String(repeating: "40281795", count: 4).dropFirst())) == nil)
    }

    @Test func passwordRules() {
        #expect(PasswordPolicy.check("short1!") == .tooShort)
        #expect(PasswordPolicy.check(String(repeating: "x", count: 1025)) == .tooLong)
        // Counted in UTF-8 bytes.
        #expect(PasswordPolicy.check(String(repeating: "é", count: 513)) == .tooLong)
        #expect(PasswordPolicy.check("Tab\tInside-Password-1") == .controlCharacters)
        #expect(PasswordPolicy.check("password") == .tooWeak)
        #expect(PasswordPolicy.check("12345678901") == .tooWeak)
        #expect(PasswordPolicy.check("9753108642975310", pin: "9753108642975310") == .sameAsPin)
        #expect(PasswordPolicy.check("correct horse battery staple (test)") == nil)
        #expect(PasswordPolicy.check("Tr0ub4dor&3x!") == nil)
    }

    @Test func strengthGrows() {
        #expect(PasswordPolicy.strength("abc") == .tooShort)
        #expect(PasswordPolicy.strength("aaaaaaaaaa") == .weak)
        #expect(PasswordPolicy.strength("Tr0ub4dor&3x!") >= .good)
        #expect(PasswordPolicy.strength("correct horse battery staple (test)") == .strong)
    }

    @Test func deletePhrase() {
        #expect(DeletePhrase.matches(" delete my vault "))
        #expect(!DeletePhrase.matches("Delete my vault"))
        // Kotlin's trim(): U+001F is white space, U+0085 is not.
        #expect(DeletePhrase.matches("\u{1F}delete my vault\u{3000}\u{2028}"))
        #expect(!DeletePhrase.matches("\u{85}delete my vault"))
    }

    /// VAULT-MESSAGING §11.14.7 on the phone, in the vault's order, with the app's own limits first.
    @Test func releaseRPasswordRules() {
        #expect(PasswordRule.check("", pin: nil) == .short)
        #expect(PasswordRule.check("elevenchars", pin: nil) == .short)
        #expect(PasswordRule.check("zzzzzzzzzzzzzzzz", pin: nil) == .repeated)
        #expect(PasswordRule.check("password1234", pin: nil) == .common)
        #expect(PasswordRule.check("PASSWORD1234", pin: nil) == .common)
        #expect(PasswordRule.check("975310864208", pin: "975310864208") == .sameAsPin)
        #expect(PasswordRule.check("123456789123", pin: nil) == .guessable)
        #expect(PasswordRule.check("correct horse battery staple (test)", pin: nil) == .ok)
        #expect(PasswordRule.check("correct horse battery staple (test)", pin: "") == .ok)
        #expect(PasswordRule.check("Tab\tInside-Password-1", pin: nil) == .controlCharacters)
        #expect(PasswordRule.check(String(repeating: "é", count: 513), pin: nil) == .tooLong)
        // Characters, not bytes: twelve two-byte letters are long enough.
        #expect(PasswordRule.check("éàüöñçøåæßðþ", pin: nil) != .short)
        #expect(PasswordRule.ok.passes)
        #expect(!PasswordRule.guessable.passes)
    }

    @Test func theVaultsReasons() {
        #expect(PasswordRule.fromVault("short") == .short)
        #expect(PasswordRule.fromVault("repeated") == .repeated)
        #expect(PasswordRule.fromVault("common") == .common)
        #expect(PasswordRule.fromVault("same_as_pin") == .sameAsPin)
        #expect(PasswordRule.fromVault("guessable") == .guessable)
        #expect(PasswordRule.fromVault("something_new") == .vaultRefused)
        #expect(PasswordRule.fromVault(nil) == .vaultRefused)
        #expect(!PasswordRule.vaultRefused.passes)
    }

    /// The texts are Android's (`core/data` strings), word for word.
    @Test func theTextsAreAndroids() {
        #expect(PinPolicy.Problem.tooShort.message == "Use at least 6 digits.")
        #expect(PinPolicy.Problem.tooLong.message == "Use at most 32 digits.")
        #expect(PinPolicy.Problem.tooShort.messageArg == PinPolicy.minLength)
        #expect(PinPolicy.Problem.sequence.messageArg == nil)
        #expect(PinPolicy.Problem.sequence.message == "Avoid runs like 123456.")
        #expect(PasswordPolicy.Problem.controlCharacters.message == "Remove tabs and other control characters.")
        #expect(PasswordPolicy.Strength.tooShort.label == "Too short")
        #expect(PasswordRule.sameAsPin.message == "Don't use your PIN as your password.")
        #expect(PasswordRule.vaultRefused.message == "This password is not strong enough.")
        #expect(PasswordRule.tooLong.message == PasswordPolicy.Problem.tooLong.message)
        #expect(PasswordRule.guessable.hint == "Avoid names, dates and keyboard runs.")
        #expect(PasswordRule.ok.hint == nil)
        #expect(Set(PinPolicy.Problem.allCases.map(\.message)).count == PinPolicy.Problem.allCases.count)
        #expect(Set(PasswordRule.allCases.map(\.message)).count == PasswordRule.allCases.count)
        #expect(Set(PasswordPolicy.Strength.allCases.map(\.label)).count == PasswordPolicy.Strength.allCases.count)
    }
}
