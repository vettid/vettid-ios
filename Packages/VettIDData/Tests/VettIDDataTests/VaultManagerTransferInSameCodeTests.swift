import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// A second scan of the same code (VAULT-MESSAGING 0.88.4 §11.14.10 rule 5; owner decision a): while the
/// transfer it started is open, the same code (the same `r` and `c`, whatever its expiry) changes nothing, sends nothing
/// and gives the move back as it stands. A different code is handled as before, and the same code after the transfer
/// ended is a spent code. Mirrors vettid-android `TransferInSameCodeTest`.
extension VaultManagerTransferInTests {
    /// What a scan must not touch while the transfer is open.
    struct OpenTransfer: Equatable {
        let started: Int64?
        let epochID: String?
        let attestKey: [UInt8]?
        let attested: Int
        let discarded: Int
        let inits: Int
        let pendings: Int
    }

    func openTransfer() throws -> OpenTransfer {
        OpenTransfer(
            started: m.record.value.transferStartedMs, epochID: m.record.value.transferEpochID,
            attestKey: m.session?.device.altState.transferAttestKeyID, attested: phone.attester.attested.count,
            discarded: phone.attester.discarded.count, inits: service.transferInits.count,
            pendings: try m.phoneSecrets.records().pendings.count
        )
    }

    // MARK: - The code's identity

    @Test func aCodesIdentityIsItsRelayAndClaimAndIgnoresItsExpiry() throws {
        let qr = try code()
        let id = try #require(InviteLinks.transferCodeID(qr))
        #expect(id.relay == service.vaultRelay.baseURL && !id.claim.isEmpty)
        // The pasted link form is the same code.
        guard case .ok(let link, _) = InviteLinks.parseTransfer(qr) else { Issue.record("not a transfer code"); return }
        #expect(InviteLinks.transferCodeID(link) == id)
        // Expired by the clock: still read (``parseTransfer`` says expired).
        let old = try service.armTransferTarget(pin: pin, password: password, validFor: -60)
        #expect(InviteLinks.parseTransfer(old) == .expired && InviteLinks.transferCodeID(old) != nil)
        #expect(InviteLinks.transferCodeID("hello there") == nil)
    }

    // MARK: - While the transfer is open

    @Test func theSameCodeWhileOpenChangesNothingAndGivesTheSasBack() async throws {
        defer { phone.close() }
        let qr = try code()
        service.holdsTransferApproval = true
        let sas = try await m.transferIn(code: qr)
        let before = try openTransfer()
        #expect(m.record.value.transferCode == InviteLinks.transferCodeID(qr) && m.session?.device.transferSas == sas)
        // The claim is served once: a fetch would fail, and an hs.init would be counted.
        #expect(try await m.transferIn(code: qr) == sas)
        #expect(try openTransfer() == before && deviceHoldsVault && pendingRecord)
        // The move goes on as before.
        let waiting = Task { try await m.awaitTransferIn() }
        try await Task.sleep(for: .milliseconds(100))
        service.approveTransferIn()
        #expect(try await waiting.value)
        #expect(service.transferPaired && m.record.value.transferCode == nil && m.session?.device.transferSas == nil)
    }

    /// The code expires 10 minutes after it was made, before the transfer's 11: in that gap it is still the same code,
    /// never an expired one, and the window's refusal of new codes does not apply to it.
    @Test func theSameCodeAfterItsExpiryAndInTheClosedWindowIsStillTheSame() async throws {
        defer { phone.close() }
        let qr = try code()
        service.holdsTransferApproval = true
        let sas = try await m.transferIn(code: qr)
        let before = try openTransfer()
        phone.clockAhead = 620
        #expect(InviteLinks.parseTransfer(qr, now: Date().addingTimeInterval(620)) == .expired)
        #expect(m.abandonClosed, "the window's refusal of new codes is on")
        #expect(try await m.transferIn(code: qr) == sas)
        #expect(try openTransfer() == before && deviceHoldsVault)
    }

    /// Before the vault's `hs.resp`: the wait for it, at most until 60 s after the stored start, and then "not answered"
    /// with nothing dropped (the scan that started it decides its own end).
    @Test func theSameCodeBeforeTheHsRespEndsUnansweredAndDropsNothing() async throws {
        defer { phone.close() }
        service.transferIgnoresInit = true
        let qr = try code()
        let first = Task { try await m.transferIn(code: qr) }
        #expect(await eventually { phone.transferPauses.lengths == [60] })
        let before = try openTransfer()
        phone.clockAhead = 61
        let failure = await vaultFailure { _ = try await m.transferIn(code: qr) }
        #expect(failure?.kind == .noResponse && failure?.code == MoveCodes.hsUnanswered)
        #expect(try openTransfer() == before && deviceHoldsVault && pendingRecord)
        // The first scan's own end drops it, as before.
        phone.transferPauses.release()
        #expect(await vaultFailure { _ = try await first.value }?.code == MoveCodes.hsUnanswered)
        #expect(!deviceHoldsVault && m.record.value.transferCode == nil)
    }

    /// Without a session (a background ended it): the stored code and start say it is the open transfer's, and the scan
    /// gives the stored comparison code back with nothing changed, even after the code's expiry.
    @Test func withoutASessionTheSameCodeIsStillOpen() async throws {
        defer { phone.close() }
        let qr = try code()
        service.holdsTransferApproval = true
        let sas = try await m.transferIn(code: qr)
        let before = try openTransfer()
        await m.onBackground(budget: .seconds(1))
        #expect(m.session == nil)
        phone.clockAhead = 620
        #expect(m.isOpenTransferCode(qr))
        #expect(try await m.transferIn(code: qr) == sas)
        #expect(try openTransfer() == before && deviceHoldsVault)
    }

    /// After a restart the comparison code is the stored one: the same code goes back to it without reaching the vault.
    @Test func theSameCodeAfterARestartGivesTheStoredSas() async throws {
        defer { phone.close() }
        let qr = try code()
        service.holdsTransferApproval = true
        let sas = try await m.transferIn(code: qr)
        try await phone.restart()
        try await m.refresh()
        let before = try openTransfer()
        #expect(try await m.transferIn(code: qr) == sas)
        #expect(try openTransfer() == before && deviceHoldsVault)
        // The screen's wait has the move now: the approval completes it there, not at the deadline.
        let waiting = Task { try await m.awaitTransferIn() }
        try await Task.sleep(for: .milliseconds(100))
        service.approveTransferIn()
        #expect(try await waiting.value)
        #expect(m.finishMovePending && m.record.value.transferStartedMs == nil)
    }

    // MARK: - Any other case, as before

    /// Paired, its take-over not done: the transfer is applied, so its code is not the open transfer's any more (the
    /// stored comparison code notwithstanding).
    @Test func aPairedTransfersCodeIsNotTheOpenTransfers() async throws {
        defer { phone.close() }
        let qr = try code()
        service.holdsTransferApproval = true
        _ = try await m.transferIn(code: qr)
        service.approveTransferIn()
        let d = try #require(m.session?.device)
        _ = try await d.awaitTransfer(timeout: 5)
        #expect(d.deviceID != nil && d.transferSas != nil && m.record.value.transferCode != nil)
        #expect(!m.isOpenTransferCode(qr))
        #expect(await vaultFailure { _ = try await m.transferIn(code: qr) }?.kind == .vaultExists)
    }

    /// A restart before the vault's `hs.resp` ends the transfer (0.88.4): its handshake was in memory only, so no `hs.fin`
    /// can follow. Dropped at the start, its code and start with it: a new code is not refused for it in what would have
    /// been its closed window, and its own code is a spent code.
    @Test func aRestartBeforeTheHsRespEndsTheTransfer() async throws {
        defer { phone.close() }
        service.transferIgnoresInit = true
        let qr = try code()
        let first = Task { try await m.transferIn(code: qr) }
        #expect(await eventually { phone.transferPauses.lengths == [60] })
        #expect(m.isOpenTransferCode(qr), "open while its scan waits for the hs.resp")
        try await phone.restart()
        first.cancel()
        try await m.refresh()
        #expect(m.record.value.transferStartedMs == nil && m.record.value.transferCode == nil)
        #expect(!deviceHoldsVault && !pendingRecord && !m.isOpenTransferCode(qr))
        // In what would have been the first transfer's closed window: its code is a spent code (never `transfer_waiting`),
        // and a new code starts at once.
        phone.clockAhead = 620
        #expect(!m.abandonClosed)
        let inits = service.transferInits.count
        let failure = await vaultFailure { _ = try await m.transferIn(code: qr) }
        #expect(failure != nil && failure?.code != MoveCodes.hsUnanswered && failure?.code != VaultManager.codeTransferWaiting)
        #expect(service.transferInits.count == inits && m.record.value.transferCode == nil, "nothing sent, no code kept")
        // A new code is not refused for it (the fake's answers, 620 s behind this phone's clock, are not taken, so the scan
        // ends otherwise once its wait is over: its pauses last five seconds, whenever it reaches them).
        let next = try service.armTransferTarget(pin: pin, password: password, validFor: 1_300)
        phone.transferPauses.holding = false
        let ended = await vaultFailure { _ = try await m.transferIn(code: next) }
        #expect(ended?.code != VaultManager.codeTransferWaiting && ended?.code != VaultManager.codeTransferNotDropped)
    }

    /// A drop at the start that cannot be saved changes nothing on disk: the transfer is waited for in the background,
    /// and the next scan clears it once saves work again.
    @Test func aRestartDropThatCannotBeSavedIsLeftToTheBackgroundAndTheNextScan() async throws {
        defer { phone.close() }
        service.transferIgnoresInit = true
        let qr = try code()
        let first = Task { try await m.transferIn(code: qr) }
        #expect(await eventually { phone.transferPauses.lengths == [60] })
        let started = try #require(m.record.value.transferStartedMs)
        try await phone.restart()
        first.cancel()
        // The device file as the transfer left it, pinned vault and all.
        let deviceFile = phone.directory.appendingPathComponent(VaultFiles.device(of: .first))
        let saved = try Data(contentsOf: deviceFile)
        phone.deviceSaveFails.on = true
        try await m.refresh()
        phone.deviceSaveFails.on = false
        #expect(m.record.value.transferStartedMs == started && m.record.value.transferCode != nil && pendingRecord)
        #expect(try Data(contentsOf: deviceFile) == saved, "the device file still holds the pinned vault")
        #expect(m.moveFlags.book.transferWaiter != nil, "waited for in the background")
        try await expectFreshSecondScan()
    }

    /// A scan cancelled while its `hs.init` still waits, before this process's first resume (a fresh install's first
    /// evaluation is `.signedOut`): the resume never drops that handshake, which can still be answered.
    @Test func theResumeKeepsAHandshakeThatStillWaitsInThisProcess() async throws {
        defer { phone.close() }
        service.transferIgnoresInit = true
        let qr = try code()
        let first = Task { try await m.transferIn(code: qr) }
        #expect(await eventually { phone.transferPauses.lengths == [60] })
        first.cancel()
        _ = try? await first.value
        let before = try openTransfer()
        m.moveFlags.book.transferResumed = false
        try await m.refresh()
        #expect(try openTransfer() == before && deviceHoldsVault && pendingRecord && m.record.value.transferCode != nil)
        #expect(m.isOpenTransferCode(qr))
    }

    /// A scan cancelled while its `hs.init` waits for the answer leaves the handshake waiting in this process: still open,
    /// so the same code waits for it (and ends "not answered" with nothing dropped), never a scan of its own.
    @Test func aCancelledScanWhoseHsInitStillWaitsIsOpen() async throws {
        defer { phone.close() }
        service.transferIgnoresInit = true
        let qr = try code()
        let first = Task { try await m.transferIn(code: qr) }
        #expect(await eventually { phone.transferPauses.lengths == [60] })
        first.cancel()
        _ = try? await first.value
        #expect(m.moveFlags.book.startingIn == 0 && m.session?.device.awaitsPairingResp == true)
        let before = try openTransfer()
        #expect(m.isOpenTransferCode(qr))
        phone.clockAhead = 61
        let failure = await vaultFailure { _ = try await m.transferIn(code: qr) }
        #expect(failure?.code == MoveCodes.hsUnanswered)
        #expect(try openTransfer() == before && deviceHoldsVault && pendingRecord)
    }

    @Test func aDifferentCodeWhileOpenStartsAFreshTransfer() async throws {
        defer { phone.close() }
        _ = try await scanned()
        let firstCode = m.record.value.transferCode
        try await expectFreshSecondScan()
        #expect(m.record.value.transferCode != firstCode && m.record.value.transferCode != nil)
    }

    /// Once the transfer ended its code is spent: the scan is handled as a new one (the relay no longer serves the claim),
    /// never given the old move back.
    @Test func theSameCodeAfterTheTransferEndedIsASpentCode() async throws {
        defer { phone.close() }
        let qr = try code()
        service.holdsTransferApproval = true
        _ = try await m.transferIn(code: qr)
        try await m.abandonTransferIn()
        #expect(m.record.value.transferCode == nil && m.session?.device.transferSas == nil)
        let inits = service.transferInits.count
        #expect(await vaultFailure { _ = try await m.transferIn(code: qr) } != nil)
        #expect(service.transferInits.count == inits && !deviceHoldsVault)
    }
}
