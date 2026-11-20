import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

/// (VAULT-MESSAGING §6.7.1, 0.90.17) One `user_guid` check (1–128 printable ASCII) for every transfer answer and every
/// stored value. Mirrors vettid-android #404.
extension VaultManagerTransferInTests {
    /// (§6.7.1, 0.90.17) A transfer's `device.paired` without `transfer: true` and a valid `user_guid` (1–128 printable
    /// ASCII) is a malformed answer: the transfer is dropped before anything of it is stored or sent, and the move stopped on
    /// this phone ("The move stopped on this phone").
    @Test(arguments: MalformedTransfer.allCases)
    func aMalformedTransferAnswerDropsTheTransfer(_ form: MalformedTransfer) async throws {
        defer { phone.close() }
        form.apply(service)
        _ = try await m.transferIn(code: try code())
        let seen = service.requestsSeen.count
        let error = await vaultFailure { _ = try await m.awaitTransferIn() }
        #expect(error?.code == VaultManager.codeTransferSessionEnded, "\(String(describing: error))")
        #expect(m.session?.device.deviceID == nil, "the answer is not applied")
        #expect(!deviceHoldsVault && !m.record.value.finishMovePending && m.record.value.userGuid.isEmpty, "nothing stored")
        #expect(!service.requestsSeen.dropFirst(seen).contains("device.features"), "nothing sent")
        #expect(phone.attester.discarded == phone.attester.attested, "the attested key goes")
        #expect(!pendingRecord && m.record.value.transferStartedMs == nil, "the epoch-1 secret and the start go")
        #expect(m.phase != .setup(.finishing))
    }

    /// A malformed answer collected in the settlement window at the deadline: the move stopped ("The move stopped on this
    /// phone"), never "no response".
    @Test func aMalformedAnswerInTheWindowStopsTheMove() async throws {
        defer { phone.close() }
        service.transferWithoutUserGuid = true
        _ = try await scanned()
        phone.clockAhead = 600
        await suspendCollector()
        service.approveTransferIn()
        let waiting = Task { try await m.awaitTransferIn() }
        #expect(await deadlineWaiting())
        phone.clockAhead = 700
        phone.deadlinePauses.release()
        let failure = await vaultFailure { _ = try await waiting.value }
        #expect(failure?.code == VaultManager.codeTransferSessionEnded, "\(String(describing: failure))")
        #expect(!deviceHoldsVault && !pendingRecord && m.record.value.transferStartedMs == nil)
        #expect(phone.attester.discarded == phone.attester.attested)
    }

    /// The device dropped a malformed `device.paired` and the app ended before anyone waited for it: the next start says
    /// "The move stopped on this phone" (``TransferEnd/stopped``), never a silent drop.
    @Test func aDropBeforeTheAppEndedIsToldAtTheNextStart() async throws {
        defer { phone.close() }
        service.transferWithoutUserGuid = true
        _ = try await m.transferIn(code: try code())
        service.approveTransferIn()
        #expect(await eventually { m.session?.device.droppedWithoutUserGuid == true }, "dropped as it was handled")
        try await phone.restart()
        try await m.refresh()
        #expect(await eventually { m.transferEnd == .stopped }, "\(String(describing: m.transferEnd))")
        #expect(!deviceHoldsVault && m.record.value.transferStartedMs == nil)
    }

    /// A stored `user_guid` that fails the check (a damaged record) is no `user_guid`: Finish the move and the release update
    /// refuse before their lock (`no_user_guid`), and nothing is locked or sent.
    @Test func aStoredMalformedUserGuidIsRefusedBeforeAnyLock() async throws {
        defer { phone.close() }
        try await transferred()
        try m.record.update(since: m.record.generation) { $0.userGuid = "a b" }
        #expect(!m.userGuidUsable)
        let seen = service.requestsSeen.count
        let r = try await m.finishMove(pin: pin)
        #expect(r == .failed(.notSupported, code: UnlockAttempt.codeNoUserGuid))
        #expect(try await m.lockForUnlock() == false, "\"Lock and unlock now\" locks nothing")
        let rel = { (n: UInt64, status: String) in
            ReleaseView(number: n, pcr0: String(repeating: "ab", count: 48), status: status, endsAt: nil, notes: "")
        }
        let offer = ReleaseUpdateOffer(current: rel(3, "deprecated"), target: rel(4, "active"))
        #expect(m.releaseUpdate.start(pin: pin, offer: offer, generation: nil))
        await m.releaseUpdate.settle()
        let sent = service.requestsSeen.dropFirst(seen)
        #expect(!sent.contains("vault.lock") && !sent.contains("vault.unlock"), "\(Array(sent))")
        #expect(m.releaseUpdate.progress?.failureCode == UnlockAttempt.codeNoUserGuid)
    }
}

/// The malformed forms of a transfer's `device.paired` (§6.7.1).
enum MalformedTransfer: CaseIterable, CustomTestStringConvertible {
    case noUserGuid, empty, tooLong, space, nonASCII, control, unflagged

    var testDescription: String { "\(self)" }

    func apply(_ s: FakeVaultService) {
        switch self {
        case .noUserGuid: s.transferWithoutUserGuid = true
        case .empty: s.transferSendsUserGuid = ""
        case .tooLong: s.transferSendsUserGuid = String(repeating: "a", count: 129)
        case .space: s.transferSendsUserGuid = "user 0001"
        case .nonASCII: s.transferSendsUserGuid = "usér-0001"
        case .control: s.transferSendsUserGuid = "user-\u{1}"
        case .unflagged: s.transferUnflagged = true
        }
    }
}
