import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// The release update end to end (RELEASE-UPDATES §2; VAULT-MESSAGING §11.10.3, §11.10.4, §11.10.6): the offer from the
/// manifest, the update's lock, the unlock that carries the approval beside its device assertion, `update: moved`, and
/// the unlock that reaches the new release; a refusal; a lost answer; and the unlock screen's approval. The member API,
/// the enclave and the vault are ``FakeVaultService``, which answers `release_update` as vettid-vault's `releaseRules`.
@MainActor
@Suite(.serialized) struct VaultManagerReleaseUpdateTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    /// Setup code to the open app, on release 3; then release 4 is published.
    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
        service.listsRelease4 = true
    }

    @Test func theOfferIsTheNewestActiveReleaseOfTheTrustedManifest() async throws {
        defer { phone.close() }
        try await setUp()
        await m.releaseUpdate.refreshOffer()
        let offer = try #require(m.releaseUpdate.offer)
        #expect(offer.current.number == 3 && offer.target.number == 4)
        #expect(offer.target.pcr0 == FakeVaultService.pcr0(4))
        #expect(offer.kind == .available)
        service.listsRelease4 = false
        await m.releaseUpdate.refreshOffer()
        #expect(m.releaseUpdate.offer == nil && m.releaseUpdate.offerKnown)
    }

    /// "Approve and update": the lock, one unlock carrying the approval for release 4 beside its device assertion, `moved`,
    /// then the unlock that reaches release 4 with the same PIN and no approval. The phone records release 4 and the
    /// release it moved from.
    @Test func approveLocksMovesAndOpensOnTheNewRelease() async throws {
        defer { phone.close() }
        try await setUp()
        await m.releaseUpdate.refreshOffer()
        let offer = try #require(m.releaseUpdate.offer)
        let unlocksBefore = service.unlocks.count
        #expect(m.releaseUpdate.start(pin: pin, offer: offer))
        await m.releaseUpdate.settle()
        let p = try #require(m.releaseUpdate.progress)
        #expect(p.step == .done && p.vaultOpen)
        #expect(service.unlocks.count == unlocksBefore + 2)
        let update = try #require(service.releaseUpdates.first)
        #expect(service.releaseUpdates.count == 1)
        #expect(update.to == FakeVaultService.pcr0(4) && update.toRelease == 4)
        #expect(try update.approval.string("platform") == "ios" && update.approval.has("assertion"))
        #expect(try update.deviceAssertion.base64("assertion") != update.approval.base64("assertion"))
        #expect(service.routedRelease == 4 && service.isOpen)
        #expect(m.phase == .unlocked)
        let st = try #require(m.session?.device.altState)
        #expect(st.releaseNumber == 4 && st.release == FakeVaultService.pcr0(4))
        #expect(st.previousRelease == FakeVaultService.pcr0)
        #expect(m.releaseUpdate.offer == nil)
        m.releaseUpdate.finish()
        #expect(m.releaseUpdate.progress == nil)
    }

    /// A refusal still opens the vault on its release; nothing moved.
    @Test func aRefusedApprovalLeavesTheVaultOpenOnItsRelease() async throws {
        defer { phone.close() }
        try await setUp()
        service.releaseUpdateAnswer = .refuse("approval")
        await m.releaseUpdate.refreshOffer()
        let offer = try #require(m.releaseUpdate.offer)
        _ = m.releaseUpdate.start(pin: pin, offer: offer)
        await m.releaseUpdate.settle()
        let p = try #require(m.releaseUpdate.progress)
        #expect(p.step == .refused && p.refusal == "approval" && p.vaultOpen)
        #expect(service.routedRelease == 3 && service.isOpen)
        #expect(m.phase == .unlocked)
        #expect(m.session?.device.altState.releaseNumber == 3)
    }

    /// A wrong PIN moves nothing and leaves the vault locked; the right one then approves again.
    @Test func aWrongPinThenTheRightOne() async throws {
        defer { phone.close() }
        try await setUp()
        await m.releaseUpdate.refreshOffer()
        let offer = try #require(m.releaseUpdate.offer)
        _ = m.releaseUpdate.start(pin: "111111", offer: offer)
        await m.releaseUpdate.settle()
        #expect(m.releaseUpdate.progress?.step == .badPin)
        #expect(service.routedRelease == 3 && !service.isOpen)
        m.releaseUpdate.retry(pin: pin)
        await m.releaseUpdate.settle()
        #expect(m.releaseUpdate.progress?.step == .done)
        #expect(service.releaseUpdates.count == 2)
    }

    /// The answer of the unlock that carried the approval is lost after the vault moved: the update says it did not go
    /// through (nothing is known), and "Try again" reaches release 4, which opens: done, with release 4 recorded.
    @Test func aLostAnswerOfTheApprovalIsDoneOnTheRetry() async throws {
        defer { phone.close() }
        try await setUp()
        await m.releaseUpdate.refreshOffer()
        let offer = try #require(m.releaseUpdate.offer)
        service.unlockAnswers(.answerLost)
        _ = m.releaseUpdate.start(pin: pin, offer: offer)
        await m.releaseUpdate.settle()
        #expect(m.releaseUpdate.progress?.step == .failed)
        #expect(service.routedRelease == 4)
        m.releaseUpdate.retry(pin: pin)
        await m.releaseUpdate.settle()
        #expect(m.releaseUpdate.progress?.step == .done)
        #expect(m.session?.device.altState.releaseNumber == 4)
        #expect(m.phase == .unlocked)
    }

    /// The unlock screen's approval ("Approve the update with this unlock"): the unlock that carries it is followed at
    /// once by the unlock that reaches the new release (§11.10.6).
    @Test func theUnlockScreensApprovalFollowsTheMove() async throws {
        defer { phone.close() }
        try await setUp()
        try await m.lock()
        let p = try await m.preflight()
        let offer = try #require(p.offer)
        #expect(offer.number == 4)
        #expect(try await m.unlock(pin: pin, approve: offer) == .success)
        #expect(m.phase == .unlocked && service.isOpen && service.routedRelease == 4)
        #expect(m.session?.device.altState.releaseNumber == 4)
        // The next check before the PIN finds the vault on release 4, as this phone last unlocked into: nothing to say.
        try await m.lock()
        let after = try await m.preflight()
        #expect(after.routed.number == 4 && !after.softwareUpdated && !after.rollback && after.offer == nil)
    }
}
