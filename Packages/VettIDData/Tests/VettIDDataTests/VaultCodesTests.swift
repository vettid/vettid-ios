import Foundation
import Testing
import VettIDAltChan
@testable import VettIDData
import VettIDDataTesting
import VettIDRelay
@testable import VettIDVault

/// The vault error codes the app did not map (IOS-PLAN §4.4, §4.5 (3); ANDROID-PLAN 0.1.57 §4 "Vault error codes the
/// app does not map", 0.1.58 "One-time keys and a vault without a holder"): one case per code of the table, the code's
/// check, the texts, and no erase.
@Suite struct VaultCodesTests {
    func failure(_ code: String, type: String = "vault.owner-check", message: String = "", body: String? = nil) -> VaultFailure? {
        let e = VaultOpError(type: type, code: code, detail: message, body: body.map { Array($0.utf8) })
        return VaultFailures.map(e) as? VaultFailure
    }

    @Test func everyMappedCodeKeepsItsKind() {
        let mapped: [String: FailureKind] = [
            "bad_pin": .badPin, "bad_password": .badPassword, "backoff": .backoff, "credential_frozen": .credentialFrozen,
            "rotation_required": .rotationRequired, "not_found": .notFound, "unsupported_type": .notSupported, "limit": .limit,
            "stale_credential": .noResponse, "utk_invalid": .noResponse, "owner_check_required": .ownerCheckRequired,
            "busy": .busy, "retry": .retry, "counter_unavailable": .counterUnavailable, "weak_password": .weakPassword,
        ]
        for (code, kind) in mapped { #expect(failure(code)?.kind == kind, "\(code)") }
    }

    /// `credential_required`, with or without `{"reason": "no_holder"}`, from the daily check, a PIN change, a name
    /// change and a credential unlock.
    @Test func credentialRequiredIsItsOwnKind() {
        for type in ["vault.owner-check", "pin.change", "account.name.set", "credential.unlock", "settings.set"] {
            #expect(failure("credential_required", type: type)?.kind == .credentialRequired, "\(type)")
            #expect(failure("credential_required", type: type, body: #"{"reason":"no_holder"}"#)?.kind == .credentialRequired)
        }
        #expect(failure("credential_required")?.code == "credential_required")
    }

    /// `forbidden` to a holder-only type means that another app holds the credential; to any other type it is a code.
    @Test func forbiddenOnAHolderOnlyTypeIsNotTheHolder() {
        let holderOnly = [
            "vault.owner-check", "pin.change", "vault.secret.renew", "account.name.set", "credential.get", "credential.ack",
            "credential.reset", "credential.unlock", "device.transfer.create", "device.transfer.reject", "vault.delete",
        ]
        for type in holderOnly { #expect(failure("forbidden", type: type)?.kind == .notHolder, "\(type)") }
        #expect(failure("forbidden", type: "device.unlink")?.kind == .vaultCode("forbidden"))
        #expect(failure("forbidden", type: "settings.set")?.kind == .vaultCode("forbidden"))
    }

    @Test func everyOtherCodeNamesItself() {
        for code in ["bad_request", "internal", "relay_error", "unavailable", "session_required", "some_new_code", "too_soon", "exists"] {
            let f = failure(code)
            #expect(f?.kind == .vaultCode(code) && f?.code == code, "\(code)")
            #expect(f?.kind.message.contains("(code: \(code))") == true)
        }
    }

    /// The code alone, when it is `[a-z0-9_]{1,40}`; never the error's `message` or body.
    @Test func onlyTheCheckedCodeIsShown() {
        for code in ["Internal", "a code", String(repeating: "a", count: 41), "", "é", "a-b"] {
            #expect(failure(code)?.kind == .vaultCode("unknown"), "\(code)")
            #expect(FailureKind.vaultCode(code).message.contains("(code: unknown)"))
        }
        #expect(VaultFailures.shownCode(String(repeating: "a", count: 40)) == String(repeating: "a", count: 40))
        #expect(VaultFailures.shownCode("x_9") == "x_9")
        let f = failure("strange_code", message: "secret-message", body: #"{"detail":"secret-body"}"#)
        let text = f?.kind.message ?? ""
        #expect(text == "Something went wrong (code: strange_code). Try again. If it keeps happening, contact VettID and give this code.")
        #expect(!text.contains("secret-message") && !text.contains("secret-body"))
        for kind in [FailureKind.credentialRequired, .notHolder] {
            #expect(!kind.message.contains("secret"))
        }
    }

    @Test func theTextsAreTheApprovedOnes() {
        #expect(FailureKind.credentialRequiredTitle == "This phone can't use your vault")
        #expect(FailureKind.credentialRequired.message == """
            Your vault does not count this phone as the one that holds its credential, so it refused the request. Nothing was \
            disclosed, and your PIN and password were not checked. This usually means a recovery of your vault was started \
            and has not finished. If you recovered your vault on another phone, open VettID on that phone and unlock it to \
            finish. Otherwise, start a recovery on the account site: it takes one to three days, and you need your PIN and \
            your password. If another phone of yours now opens your vault, use 'Move to a new phone' there instead.
            """)
        #expect(FailureKind.notHolderTitle == "Your vault moved to a new phone")
        #expect(FailureKind.notHolder.message == """
            Another phone now holds your vault's credential, so this phone can't do this. Nothing was disclosed. Use VettID on \
            the phone that holds it now. If you no longer have that phone, start a recovery on the account site.
            """)
        #expect(FailureKind.credentialRequired.messageKey == "vault_credential_required_body")
        #expect(FailureKind.notHolder.messageKey == "vault_not_holder")
        #expect(FailureKind.vaultCode("x").messageKey == "error_vault_code")
        #expect(FailureKind.notHolder.title(or: "Own") == FailureKind.notHolderTitle)
        #expect(FailureKind.credentialRequired.title(or: "Own") == FailureKind.credentialRequiredTitle)
        #expect(FailureKind.vaultCode("x").title(or: "Own") == "Own" && FailureKind.badPin.title(or: "Own") == "Own")
    }

    /// Neither is a proof for ``HolderPolicy``: nothing is erased.
    @Test func neitherIsAProofOfReplacement() throws {
        for code in ["credential_required", "forbidden"] {
            let f = try #require(failure(code, body: #"{"reason":"no_holder"}"#))
            #expect(!HolderPolicy.proves(HolderPolicy.of(f)))
        }
    }

    /// A transport error, a timeout, an HTTP 403 and a `forbidden` from the relay or the member API keep their texts.
    @Test func failuresThatAreNotAVaultAnswerKeepTheirTexts() {
        let kinds = [
            VaultFailures.map(URLError(.timedOut)), VaultFailures.map(RelayError(status: 403, code: "forbidden", message: "")),
            VaultFailures.map(MemberApiError(status: 403, code: "forbidden", message: "m")),
            VaultFailures.map(RequestUnanswered(type: "credential.get")),
        ].compactMap { ($0 as? VaultFailure)?.kind }
        #expect(kinds.count == 4)
        for k in kinds {
            if case .vaultCode = k { Issue.record("\(k)") }
            #expect(k != .notHolder && k != .credentialRequired)
        }
    }
}

/// The root screen and `forbidden` over ``FakeVaultService``: no erase, "Lock vault" and "Try again".
@MainActor
@Suite(.serialized) struct VaultManagerVaultCodesTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    /// `credential_required{no_holder}` to the daily check: the root screen, nothing erased; "Try again" leaves it, and a
    /// vault that has a holder again answers the next check; "Lock vault" locks, and the unlock opens the vault.
    @Test func credentialRequiredShowsTheRootScreenAndErasesNothing() async throws {
        defer { phone.close() }
        try await setUp()
        let keys = phone.phoneKeys.count
        let vaultID = m.record.value.vaultID
        service.refuseNext("vault.owner-check", code: "credential_required", message: "no holder", body: #"{"reason":"no_holder"}"#)
        let r = try await m.ownerChecks.check(pin: pin, password: password)
        #expect(r == .failed(.credentialRequired, code: "credential_required"))
        #expect(m.credentialRequired && m.phase == .unlocked)
        #expect(phone.phoneKeys.count == keys && m.record.value.vaultID == vaultID && m.usesPhoneSecret)
        m.dismissCredentialRequired()
        #expect(!m.credentialRequired)
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)

        service.refuseNext("vault.owner-check", code: "credential_required")
        _ = try await m.ownerChecks.check(pin: pin, password: password)
        #expect(m.credentialRequired)
        try await m.lock()
        #expect(!m.credentialRequired && m.phase == .locked)
        #expect(try await m.unlock(pin: pin) == .success)
    }

    /// `forbidden` to `pin.change`: "Your vault moved to a new phone" on the change's screen; no root screen, no erase.
    @Test func forbiddenOnAPinChangeIsNotTheHolder() async throws {
        defer { phone.close() }
        try await setUp()
        let keys = phone.phoneKeys.count
        service.refuseNext("pin.change", code: "forbidden", message: "not the holder")
        let f = await vaultFailure { try await m.changePin(pin: pin, newPin: "975310", password: password) }
        #expect(f?.kind == .notHolder && f?.code == "forbidden")
        #expect(!m.credentialRequired && m.phase == .unlocked && phone.phoneKeys.count == keys)
    }
}
