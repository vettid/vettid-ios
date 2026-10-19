import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// The gate inside the credential lock (VAULT-MESSAGING 0.47.0 §11.14.9 step 2; IOS-PLAN 0.1.6 §6.3): a credential
/// operation that passed its own check (``VaultManager/decideFirst(carriesPin:)``) and then waited for the credential lock
/// while a change of PIN or password was on its way, or went out, is refused with nothing sent. Sent afterwards it would
/// carry the PIN or password the change replaced, and the vault would count a `bad_pin` or `bad_password` as a failed
/// owner check. The test holds the credential lock to put the operations in a known order.
@MainActor
@Suite(.serialized) struct VaultManagerCredentialGateTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let newPin = "518293"
    let password = "correct horse battery"
    let newPassword = "a brand new passphrase"

    init() throws {
        service = try FakeVaultService()
        service.stampsOnVaultClock = true
        phone = try TestVaultPhone(service: service, requestTimeout: 0.4)
    }

    var m: VaultManager { phone.manager }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    func count(_ type: String) -> Int { service.requestsSeen.filter { $0 == type }.count }

    /// The device's credential lock, taken by the test as an operation in progress would hold it.
    func takeLock() async throws -> AsyncLock {
        let lock = try #require(m.session?.device.credentialLock)
        await lock.acquire()
        return lock
    }

    /// A PIN change started while the test holds the lock: on its way (``VaultManager/sendingChange``) and queued.
    func pinChangeQueued(_ lock: AsyncLock, behind waiting: Int) async -> Task<Void, any Error> {
        let change = Task { try await m.changePin(pin: pin, newPin: newPin, password: password) }
        #expect(await eventually { m.sendingChange && lock.waiting == waiting + 1 })
        return change
    }

    /// The PIN change went through and nothing counted a wrong PIN.
    func expectPinChanged(_ change: Task<Void, any Error>) async throws {
        try await change.value
        #expect(service.currentPin == newPin && service.pinFailureCount == 0)
        #expect(try m.phoneSecrets.unresolvedChange() == nil)
    }

    // MARK: - Queued on the lock while a PIN change is on its way (the manager's own paths)

    /// A renew that passed its check waits on the lock while a PIN change starts: refused there, nothing sent.
    @Test func aQueuedRenewIsRefusedWhileAPinChangeIsOnItsWay() async throws {
        defer { phone.close() }
        try await setUp()
        let lock = try await takeLock()
        let renew = Task { await vaultFailure { try await m.renewPhoneSecret(pin: pin, password: password) } }
        #expect(await eventually { lock.waiting == 1 })
        let change = await pinChangeQueued(lock, behind: 1)
        lock.release()
        let f = await renew.value
        #expect(f?.kind == .busy && f?.code == "change_in_flight", "\(String(describing: f))")
        try await expectPinChanged(change)
        #expect(service.renews.isEmpty && count(VaultApi.typeSecretRenew) == 0)
        #expect(try m.phoneSecrets.records().candidates.isEmpty)
    }

    /// The same for an owner check.
    @Test func aQueuedOwnerCheckIsRefusedWhileAPinChangeIsOnItsWay() async throws {
        defer { phone.close() }
        try await setUp()
        let lock = try await takeLock()
        let check = Task { try await m.ownerChecks.check(pin: pin, password: password, holdOff: nil) }
        #expect(await eventually { lock.waiting == 1 })
        let change = await pinChangeQueued(lock, behind: 1)
        lock.release()
        let r = try await check.value
        #expect(r == .failed(.busy, code: "change_in_flight"), "\(r)")
        try await expectPinChanged(change)
        #expect(service.ownerChecks.isEmpty && count(VaultApi.typeOwnerCheck) == 0)
    }

    /// The same for a name change.
    @Test func aQueuedNameChangeIsRefusedWhileAPinChangeIsOnItsWay() async throws {
        defer { phone.close() }
        try await setUp()
        let lock = try await takeLock()
        let name = Task { await m.profiles.changeName(pin: pin, password: password, firstName: "Ada", lastName: "King") }
        #expect(await eventually { lock.waiting == 1 })
        let change = await pinChangeQueued(lock, behind: 1)
        lock.release()
        let r = await name.value
        #expect(r == .failed(.busy, code: "change_in_flight"), "\(r)")
        try await expectPinChanged(change)
        #expect(service.nameSets.isEmpty && count(VaultApi.typeAccountNameSet) == 0)
    }

    /// The same for the unlock window.
    @Test func aQueuedUnlockWindowIsRefusedWhileAPinChangeIsOnItsWay() async throws {
        defer { phone.close() }
        try await setUp()
        let lock = try await takeLock()
        let window = Task { await vaultFailure { try await m.openUnlockWindow(password: password) } }
        #expect(await eventually { lock.waiting == 1 })
        let change = await pinChangeQueued(lock, behind: 1)
        lock.release()
        let f = await window.value
        #expect(f?.kind == .busy && f?.code == "change_in_flight", "\(String(describing: f))")
        try await expectPinChanged(change)
        #expect(count("credential.unlock") == 0 && m.unlockWindow == nil)
    }

    /// A password change while a PIN change is on its way: refused at once, nothing sent; the PIN change goes through.
    @Test func aPasswordChangeIsRefusedWhileAPinChangeIsOnItsWay() async throws {
        defer { phone.close() }
        try await setUp()
        let lock = try await takeLock()
        let change = await pinChangeQueued(lock, behind: 0)
        let f = await vaultFailure { try await m.changePassword(password, newPassword: newPassword, pin: pin) }
        #expect(f?.kind == .busy && f?.code == "change_in_flight", "\(String(describing: f))")
        #expect(lock.waiting == 1, "nothing else queued")
        lock.release()
        try await expectPinChanged(change)
        #expect(service.passwordChanges.isEmpty && count(VaultApi.typePasswordChange) == 0)
        #expect(service.passwordFailureCount == 0)
    }

    // MARK: - Queued behind a change that goes out and is answered first

    /// An operation that passed its check just before a change began (``VaultManager/decideFirst(carriesPin:)`` here),
    /// then queued on the lock behind the change: the change goes out, is answered and decided, and only then does the
    /// operation get the lock, with no marker left to gate on and no change on its way. It is refused by the count of
    /// secrets sent, with nothing sent ([send] the operation's own request, as its manager path makes it once past its
    /// check). The test queues itself between the change and the operation, so the operation runs only once the change
    /// has ended.
    func queuedBehindAnsweredChange(
        password change: Bool = false, carriesPin: Bool = true, _ send: @escaping @Sendable (VaultApi) async throws -> Void
    ) async throws {
        try await setUp()
        try await m.decideFirst(carriesPin: carriesPin)
        let api = try m.openApi(try await m.openSession())
        let lock = try await takeLock()
        let changeTask: Task<Void, any Error> = change
            ? Task { try await m.changePassword(password, newPassword: newPassword, pin: pin) }
            : Task { try await m.changePin(pin: pin, newPin: newPin, password: password) }
        #expect(await eventually { m.sendingChange && lock.waiting == 1 })
        let testTurn = Task { await lock.acquire() }
        #expect(await eventually { lock.waiting == 2 })
        let op = Task { () -> (any Error)? in
            do {
                try await send(api)
                return nil
            } catch {
                return error
            }
        }
        #expect(await eventually { lock.waiting == 3 })
        lock.release()
        try await changeTask.value
        await testTurn.value
        let marker = try m.phoneSecrets.unresolvedChange()
        #expect(!m.sendingChange && marker == nil, "the change has ended")
        lock.release()
        let error = await op.value
        #expect(error is CredentialUnsettled, "\(String(describing: error))")
        #expect(service.pinFailureCount == 0 && service.passwordFailureCount == 0)
        if change {
            #expect(service.passwordChanges.count == 1)
        } else {
            #expect(service.currentPin == newPin)
        }
    }

    /// (VAULT-MESSAGING 0.47.0 §11.14.9 step 2) A PIN change whose caller read the count of secrets sent before its own
    /// checks (as ``VaultManager/changePin(pin:newPin:password:)`` does before the renews' decision, which may wait on the
    /// network) is refused when a password change went out and was decided meanwhile: nothing sent, no `bad_password`.
    @Test func aPinChangeIsRefusedWhenAPasswordChangeWentOutAfterItsCallerRead() async throws {
        defer { phone.close() }
        try await setUp()
        let s = try #require(m.session)
        let since = s.device.secretsSent
        try await m.changePassword(password, newPassword: newPassword, pin: pin)
        let mark = count(VaultApi.typePinChange)
        let api = try m.openApi(s)
        await #expect(throws: CredentialUnsettled.self) {
            _ = try await api.pinChange(pin: pin, newPin: newPin, password: password, since: since) { _ in
                [UInt8](repeating: 7, count: 32)
            }
        }
        #expect(count(VaultApi.typePinChange) == mark && service.pinChanges.isEmpty)
        #expect(service.passwordFailureCount == 0 && service.pinFailureCount == 0)
    }

    @Test func aRenewQueuedBehindAnAnsweredPinChangeIsRefused() async throws {
        defer { phone.close() }
        let (pin, password) = (pin, password)
        try await queuedBehindAnsweredChange { api in
            try await api.secretRenew(
                pin: pin, password: password, onMarker: { _ in [UInt8](repeating: 7, count: 32) }, onAnswered: {}
            )
        }
        #expect(service.renews.isEmpty && count(VaultApi.typeSecretRenew) == 0)
    }

    @Test func anOwnerCheckQueuedBehindAnAnsweredPinChangeIsRefused() async throws {
        defer { phone.close() }
        let (pin, password) = (pin, password)
        try await queuedBehindAnsweredChange { api in _ = try await api.ownerCheck(pin: pin, password: password) }
        #expect(service.ownerChecks.isEmpty && count(VaultApi.typeOwnerCheck) == 0)
    }

    @Test func aNameChangeQueuedBehindAnAnsweredPinChangeIsRefused() async throws {
        defer { phone.close() }
        let (pin, password) = (pin, password)
        try await queuedBehindAnsweredChange { api in
            _ = try await api.accountNameSet(pin: pin, password: password, firstName: "Ada", lastName: "King")
        }
        #expect(service.nameSets.isEmpty && count(VaultApi.typeAccountNameSet) == 0)
    }

    /// The unlock window carries the password: queued behind a password change that went out and was answered.
    @Test func anUnlockWindowQueuedBehindAnAnsweredPasswordChangeIsRefused() async throws {
        defer { phone.close() }
        let password = password
        try await queuedBehindAnsweredChange(password: true, carriesPin: false) { api in
            _ = try await api.credentialUnlock(password: password)
        }
        #expect(count("credential.unlock") == 0)
    }
}
