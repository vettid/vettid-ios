import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDSettings

/// A wait the vault asked for outlives the screen and the app's foreground, and not the open vault (VAULT-MESSAGING §10.1: the
/// app does not resend before it ends).
@MainActor
@Suite struct WaitRegistryTests {
    let repo = FakeVaultRepository(.unlocked)
    let waits = WaitRegistry()

    func wait(_ seconds: Int64 = 600) -> VaultFailure { FakeVaultRepository.failure(.backoff, code: "backoff", retry: seconds) }

    /// Closing and reopening the screen keeps the wait and its failure; an ended wait is forgotten.
    @Test func closingAndReopeningKeepsTheWait() async {
        repo.fail["rotate"] = wait()
        let first = RotateViewModel(repo: repo, waits: waits)
        first.setPassword("pw")
        first.submit()
        await first.settle()
        #expect(first.state.waiting)
        let reopened = RotateViewModel(repo: repo, waits: waits)
        #expect(reopened.state.waiting && reopened.state.error == .backoff)
        reopened.setPassword("pw")
        reopened.submit()
        await reopened.settle()
        #expect(repo.calls.filter { $0 == "rotate" }.count == 1, "nothing is sent during the wait")
        // Not kept across the open vault: a lock clears it.
        waits.clearAll()
        #expect(!RotateViewModel(repo: repo, waits: waits).state.waiting)
    }

    @Test func aWaitThatEndedIsForgotten() {
        _ = waits.record(.rotate, error: FakeVaultRepository.failure(.backoff, retry: 1))
        #expect(waits.current(.rotate) != nil)
        // A failure with no wait ends what was kept.
        _ = waits.record(.rotate, error: FakeVaultRepository.failure(.badPassword))
        #expect(waits.current(.rotate) == nil)
    }

    /// The app leaving the foreground drops what was typed and keeps the wait (Change PIN and Change password rebuild their state).
    @Test func theAppLeavingTheForegroundKeepsTheWait() async {
        repo.phoneSecret = false
        let pin = ChangePinViewModel(vault: repo, waits: waits)
        _ = waits.record(.changePin, error: wait())
        pin.forgetSecrets()
        #expect(pin.state.waiting && pin.state.error == .backoff)

        let password = ChangePasswordViewModel(repo: repo, vault: repo, waits: waits)
        repo.fail["changePassword"] = wait()
        password.setCurrent("old password 1")
        password.setPassword("a much better passphrase here")
        password.setConfirm("a much better passphrase here")
        password.submit()
        await password.settle()
        #expect(password.state.waiting && password.state.error == .backoff)
        // Typing does not clear it, and the send is held back.
        password.setCurrent("old password 1")
        #expect(password.state.error == .backoff)
        #expect(!password.state.canSubmit(pinTyped: 0))
        password.forgetSecrets()
        #expect(password.state.waiting && password.state.error == .backoff)
        password.setCurrent("old password 1")
        password.setPassword("a much better passphrase here")
        password.setConfirm("a much better passphrase here")
        password.submit()
        await password.settle()
        #expect(repo.calls.filter { $0 == "changePassword" }.count == 1)
    }

    /// The unlock window's dialog: typing keeps the wait's failure, and closing and reopening the dialog keeps the wait.
    @Test func theWindowDialogKeepsItsWait() async {
        repo.fail["openUnlockWindow"] = wait()
        let m = CredentialViewModel(repo: repo, waits: waits)
        m.showWindowDialog(true)
        m.setWindowPassword("pw")
        m.openWindow()
        await m.settle()
        #expect(m.state.windowWaiting && m.state.windowError == .backoff)
        m.setWindowPassword("pw2")
        #expect(m.state.windowError == .backoff, "typing does not clear a wait that runs")
        m.showWindowDialog(false)
        m.showWindowDialog(true)
        #expect(m.state.windowWaiting && m.state.windowError == .backoff)
        m.openWindow()
        await m.settle()
        #expect(repo.calls.filter { $0 == "openUnlockWindow" }.count == 1)
    }
}
