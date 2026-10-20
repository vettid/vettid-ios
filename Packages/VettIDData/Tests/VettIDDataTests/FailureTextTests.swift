import Foundation
import Testing
@testable import VettIDData
@testable import VettIDVault

/// Every failure has its own text, Android's; a `limit` error names its limit (VAULT-MESSAGING §10.1), and the app says
/// which. Mirrors vettid-android `LimitTextTest` (the reading of the error body comes with the guard).
@Suite struct FailureTextTests {
    @Test func everyKindHasItsOwnText() {
        let all = FailureKind.allCases
        #expect(Set(all.map(\.message)).count == all.count)
        #expect(Set(all.map(\.messageKey)).count == all.count)
        // IOS-PLAN §4.4: the texts of the codes the app did not map keep vettid-android's names.
        let vaultCodes: Set = ["vault_credential_required_body", "vault_not_holder", "error_vault_code"]
        #expect(all.allSatisfy { $0.messageKey.hasPrefix("data_failure_") || vaultCodes.contains($0.messageKey) })
        #expect(FailureKind.badPin.message == "That PIN is not correct.")
        #expect(FailureKind.badPin.messageKey == "data_failure_bad_pin")
        #expect(FailureKind.credentialFrozen.messageKey == "data_failure_frozen")
        #expect(FailureKind.setupCodeInvalid.messageKey == "data_failure_setup_code")
        #expect(FailureKind.notSupported.message == "Your vault's software release does not support this yet.")
        #expect(FailureKind.other.message == "Something went wrong. Try again.")
        #expect(FailureKind.deviceSecret.message.hasPrefix("This phone no longer holds the keys of your vault. That happens when"))
        #expect(FailureKind.deviceSecret.message.hasSuffix("The account site tells you which of these applies."))
        #expect(!FailureKind.deviceSecret.message.contains("\n"))
    }

    @Test func everyNameOfTheTableHasItsOwnWords() {
        #expect(VaultLimit.names.count == 27)
        let keys = VaultLimit.names.map { VaultLimit($0, max: 10).text().key }
        #expect(!keys.contains(.failureLimit))
        #expect(Set(keys).count == keys.count)
        #expect(Set(LimitText.Key.allCases.map { LimitText($0, [1, 2]).format() }).count == LimitText.Key.allCases.count)
    }

    @Test func countsAndSizesAreFormatted() {
        #expect(VaultLimit("items", max: 2_000).text() == LimitText(.items, [2_000]))
        // Sizes in kilobytes, rounded up; the refused size first when the vault gives it.
        #expect(VaultLimit("item_size", max: 65_536).text() == LimitText(.itemSize, [64]))
        #expect(VaultLimit("item_size", max: 65_536, size: 70_000).text() == LimitText(.itemSizeOf, [69, 64]))
        #expect(VaultLimit("location_requests", max: 1).text() == LimitText(.locationRequests))
        #expect(
            VaultLimit("item_size", max: 65_536, size: 70_000).message
                == "This item is too large: 69 KB, and an item holds at most 64 KB."
        )
        #expect(VaultLimit("blocks", max: 500).message == "Your block list is full: it holds at most 500 entries.")
        // Android's `%,d`: grouped as the locale groups digits.
        let n = Int64(2_000).formatted()
        #expect(VaultLimit("items", max: 2_000).message == "Your vault is full: it holds at most \(n) items. Delete some first.")
    }

    @Test func aTextWithoutItsArgumentsIsTheGenericText() {
        #expect(LimitText(.items).format() == FailureKind.limit.message)
        #expect(LimitText(.itemSizeOf, [69]).format() == FailureKind.limit.message)
        #expect(LimitText(.locationRequests).format() != FailureKind.limit.message)
        #expect(LimitText(.items).arity == 1 && LimitText(.itemSizeOf).arity == 2 && LimitText(.failureLimit).arity == 0)
    }

    /// Every key of the package's `Localizable.xcstrings` resolves, in the built bundle, to its own non-empty text.
    @Test func everyStringResolves() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VettIDData/Resources/Localizable.xcstrings")
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let keys = try #require((doc["strings"] as? [String: Any])?.keys)
        #expect(keys.count == 132)
        let missing = "\u{0}missing"
        for key in keys {
            let text = Bundle.module.localizedString(forKey: key, value: missing, table: nil)
            #expect(!text.isEmpty && text != key && text != missing, "\(key)")
        }
    }

    @Test func anUnknownNameOrNoBoundIsTheGenericText() {
        #expect(VaultLimit("moons", max: 3).text() == LimitText(.failureLimit))
        #expect(VaultLimit("items").text() == LimitText(.failureLimit))
        #expect(VaultLimit("items").message == FailureKind.limit.message)
    }

    @Test func aFailureNamesItsKindCodeAndLimitButNoSecret() {
        #expect(VaultFailure(.badPin).description == "badPin")
        #expect(VaultFailure(.other, code: "signer_unconfirmed").description == "other (signer_unconfirmed)")
        #expect(VaultFailure(.limit, code: "limit", limit: VaultLimit("items", max: 2)).description == "limit (limit) [items]")
    }

    @Test func theWeakPasswordReasonIsReadFromTheVaultsError() {
        let op = VaultOpError(type: "pin.change", code: "weak_password", detail: "", body: Array(#"{"reason":"common"}"#.utf8))
        #expect(VaultFailure(.weakPassword, code: "weak_password", cause: op).weakPasswordReason == "common")
        let noBody = VaultOpError(type: "pin.change", code: "weak_password", detail: "", body: nil)
        #expect(VaultFailure(.weakPassword, cause: noBody).weakPasswordReason == nil)
        #expect(VaultFailure(.weakPassword).weakPasswordReason == nil)
    }
}
