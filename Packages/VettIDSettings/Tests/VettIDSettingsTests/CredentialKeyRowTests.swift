import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDSettings

/// Settings → Vault status, the Credential key row's view model (ANDROID-PLAN 0.1.119 §4 "Owner check and status";
/// VAULT-MESSAGING 0.83.8 §10.8). Mirrors vettid-android `CredentialKeyRowTest`'s view-model tests.
@MainActor
@Suite struct CredentialKeyRowTests {
    let repo = FakeVaultRepository(.unlocked)
    let fp = "e939 754d 09aa a93a"

    @Test func theKeyIsAskedWhenTheScreenOpensAndShown() async {
        repo.credentialKeyAnswer = CredentialKeyAnswer(exists: true, fingerprint: fp)
        let m = VaultStatusViewModel(vault: repo)
        #expect(m.credentialKey == .loading)
        await m.settleKey()
        #expect(repo.calls.filter { $0 == "credentialKey" }.count == 1)
        #expect(m.credentialKey == .shown(fp))
    }

    @Test func noCredentialIsNoneYet() async {
        repo.credentialKeyAnswer = CredentialKeyAnswer(exists: false, fingerprint: nil)
        let m = VaultStatusViewModel(vault: repo)
        await m.settleKey()
        #expect(m.credentialKey == .none)
    }

    /// An error, a timeout or a locked vault: cannot be checked, and Try again asks again.
    @Test func aFailureCannotBeCheckedAndTryAgainAsksAgain() async {
        repo.credentialKeyAnswer = CredentialKeyAnswer(exists: true, fingerprint: fp)
        repo.fail["credentialKey"] = VaultFailure(.network)
        let m = VaultStatusViewModel(vault: repo)
        await m.settleKey()
        #expect(m.credentialKey == .unknown)
        repo.fail["credentialKey"] = VaultFailure(.phoneLocked)
        m.loadCredentialKey()
        #expect(m.credentialKey == .loading)
        await m.settleKey()
        #expect(m.credentialKey == .unknown)
        repo.fail["credentialKey"] = nil
        m.loadCredentialKey()
        await m.settleKey()
        #expect(m.credentialKey == .shown(fp))
        #expect(repo.calls.filter { $0 == "credentialKey" }.count == 3)
    }

    /// An answer that names no key, or an unreadable one: cannot be checked, never blank.
    @Test func anAnswerWithoutAKeyCannotBeChecked() async {
        repo.credentialKeyAnswer = CredentialKeyAnswer(exists: true, fingerprint: nil)
        let m = VaultStatusViewModel(vault: repo)
        await m.settleKey()
        #expect(m.credentialKey == .unknown)
    }

    /// A rotation answered while the screen is up: its key at once.
    @Test func aKeyFromAnAnswerIsShownAtOnce() async {
        repo.credentialKeyAnswer = CredentialKeyAnswer(exists: true, fingerprint: fp)
        let m = VaultStatusViewModel(vault: repo)
        await m.settleKey()
        repo.answerWithKey("1111 2222 3333 4444")
        #expect(await eventually { m.credentialKey == .shown("1111 2222 3333 4444") })
    }

    /// An ask still out when a rotation answered: its older answer does not replace the new key.
    @Test func anOlderAskDoesNotReplaceANewerKey() async {
        repo.credentialKeyAnswer = CredentialKeyAnswer(exists: true, fingerprint: fp)
        let gate = TestDeferred<Void>()
        repo.credentialKeyGate = gate
        let m = VaultStatusViewModel(vault: repo)
        #expect(await eventually { repo.calls.contains("credentialKey") })
        #expect(m.credentialKey == .loading)
        repo.answerWithKey("1111 2222 3333 4444")
        #expect(await eventually { m.credentialKey == .shown("1111 2222 3333 4444") })
        gate.complete(())
        for _ in 0..<20 { await Task.yield() }
        #expect(m.credentialKey == .shown("1111 2222 3333 4444"))
    }

    /// An answer that replaced the key without naming it: asked again, the old fingerprint not left unflagged.
    @Test func aChangeWithoutAKeyAsksAgain() async {
        repo.credentialKeyAnswer = CredentialKeyAnswer(exists: true, fingerprint: fp)
        let m = VaultStatusViewModel(vault: repo)
        await m.settleKey()
        repo.credentialKeyAnswer = CredentialKeyAnswer(exists: true, fingerprint: "5555 6666 7777 8888")
        repo.answerWithKey(nil)
        #expect(await eventually { repo.calls.filter { $0 == "credentialKey" }.count == 2 })
        await m.settleKey()
        #expect(m.credentialKey == .shown("5555 6666 7777 8888"))
    }

    /// A change from before the screen opened is not news: only the ask decides then.
    @Test func aChangeFromBeforeTheScreenIsNotApplied() async {
        repo.answerWithKey("1111 2222 3333 4444")
        repo.credentialKeyAnswer = CredentialKeyAnswer(exists: true, fingerprint: fp)
        let m = VaultStatusViewModel(vault: repo)
        await m.settleKey()
        for _ in 0..<20 { await Task.yield() }
        #expect(m.credentialKey == .shown(fp))
    }

    @Test func tryAgainAsksTheKeyToo() async {
        repo.credentialKeyAnswer = CredentialKeyAnswer(exists: true, fingerprint: fp)
        let m = VaultStatusViewModel(vault: repo)
        await m.settleKey()
        m.load()
        #expect(m.credentialKey == .loading)
        await m.settleKey()
        #expect(repo.calls.filter { $0 == "credentialKey" }.count == 2)
    }

    @Test func theRowPrintsItsStateOnly() {
        #expect("\(CredentialKeyRow.shown(fp))" == "shown")
    }
}
