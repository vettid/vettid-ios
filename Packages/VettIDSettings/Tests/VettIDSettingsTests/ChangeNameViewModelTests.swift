import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDSettings

/// The name change (VAULT-MESSAGING §10.8): the names checked before the PIN, both secrets sent once and forgotten, the
/// request followed to its result, and every answer of the vault; nothing typed kept while the vault is not open, a sent
/// request keeping its state (IOS-PLAN §4.7). Mirrors vettid-android `ProfileViewModelsTest`'s name-change part.
@MainActor
@Suite struct ChangeNameViewModelTests {
    let repo: FakeVaultRepository

    init() {
        repo = FakeVaultRepository(.unlocked)
        repo.account = AccountInfo(emailHint: "a***@example.com", state: "member", firstName: "Ada", lastName: "Lovelace")
    }

    /// A tick that returns at once: a backoff counts down as fast as the test lets it.
    func model(tick: @escaping @Sendable () async throws -> Void = {}) -> ChangeNameViewModel {
        ChangeNameViewModel(accounts: repo, profiles: repo, tick: tick)
    }

    func atConfirm(_ m: ChangeNameViewModel) {
        m.setLast("King")
        m.next()
        m.setPin("246810")
        m.setPassword("correct horse")
    }

    // MARK: - The names

    @Test func theNamesStartAsTheCurrentOnesAndTheRuleIsCheckedBeforeThePin() async {
        let m = model()
        await m.settle()
        #expect(m.state.first == "Ada" && m.state.last == "Lovelace")
        #expect(repo.calls.contains("refreshAccount"))
        // Unchanged names are refused by the vault (bad_request): not sent.
        m.next()
        #expect(m.state.step == .names && m.state.same)
        for bad in ["King1", "", String(repeating: "a", count: 41)] {
            m.setLast(bad)
            m.next()
            #expect(m.state.step == .names)
        }
        m.setLast(" King ")
        m.next()
        #expect(m.state.step == .confirm && m.state.requestedName == "Ada King")
        #expect(!repo.calls.contains("changeName"))
    }

    // MARK: - Drafts dropped whenever the vault is not open (IOS-PLAN §4.7)

    @Test func aLockDropsTheTypedNamesPinAndPassword() async {
        let m = model()
        await m.settle()
        m.setFirst("Ada")
        m.setLast("King")
        m.next()
        m.setPin("246810")
        m.setPassword("pw")
        #expect(m.state.step == .confirm)
        // Locked, held or due: the account is no longer the open vault's.
        repo.account = AccountInfo(emailHint: "a***@example.com")
        #expect(await eventually { m.state.step == .names })
        let s = m.state
        #expect(s.first == "" && s.last == "" && s.pin == "" && s.password == "" && !s.checked)
        // After the unlock the member types the names again.
        repo.account = AccountInfo(emailHint: "a***@example.com", state: "member", firstName: "Ada", lastName: "Lovelace")
        #expect(await eventually { m.state.account?.firstName == "Ada" })
        #expect(m.state.first == "" && m.state.last == "")
    }

    @Test func theTypedNamesAreFilledOnlyFromTheOpenVault() async {
        let m = model()
        await m.settle()
        #expect(m.state.first == "Ada")
        repo.account = nil
        #expect(await eventually { m.state.first == "" })
    }

    @Test func aSentRequestKeepsShowingItsStateAfterTheLock() async throws {
        let m = model()
        atConfirm(m)
        m.submit()
        await m.settle()
        let seq = try #require(m.state.request?.seq)
        #expect(m.state.step == .sent)
        // The hold: the account is no longer the open vault's; the request sent stays, with its state.
        repo.account = AccountInfo(emailHint: "a***@example.com")
        #expect(await eventually { m.state.first == "" })
        #expect(m.state.step == .sent && m.state.request?.seq == seq && m.state.request?.state == .pending)
        // After the unlock the account reports its result.
        var open = AccountInfo(emailHint: "a***@example.com", state: "member", firstName: "Ada", lastName: "King")
        open.nameRequest = NameRequestView(seq: seq, firstName: "Ada", lastName: "King", requestedAt: nil, state: .applied)
        repo.account = open
        #expect(m.state.step == .sent && m.state.request?.state == .applied)
    }

    @Test func theSnapshotsAllowedAfterStopsTheFlowBeforeThePin() {
        repo.account?.nameAllowedAfter = Date().addingTimeInterval(86_400)
        let m = model()
        m.setLast("King")
        m.next()
        #expect(m.state.step == .names && m.tooSoonBySnapshot())
    }

    // MARK: - The PIN and password

    @Test func aRequestIsSentWithBothSecretsAndThenForgetsThem() async {
        let m = model()
        atConfirm(m)
        #expect(m.state.submitAllowed)
        m.submit()
        await m.settle()
        #expect(repo.lastPin == "246810" && repo.lastPassword == "correct horse")
        #expect(repo.lastNames?.first == "Ada" && repo.lastNames?.last == "King")
        #expect(m.state.step == .sent && m.state.request?.state == .pending)
        #expect(m.state.pin.isEmpty && m.state.password.isEmpty)
        #expect(!"\(m.state)".contains("246810") && !"\(m.state)".contains("correct horse"))
    }

    @Test func theRequestFollowsTheAccountToAppliedOrRefused() async throws {
        let m = model()
        atConfirm(m)
        m.submit()
        await m.settle()
        let seq = try #require(m.state.request?.seq)
        // Another request's outcome is not this one's.
        repo.account?.nameRequest = NameRequestView(seq: seq + 5, firstName: "X", lastName: "Y", requestedAt: nil, state: .applied)
        #expect(m.state.request?.state == .pending)
        // account.changed with the same snapshot version: the request alone changed (0.19.0).
        repo.account?.nameRequest = NameRequestView(seq: seq, firstName: "Ada", lastName: "King", requestedAt: nil, state: .applied)
        #expect(m.state.request?.state == .applied)
        repo.account?.nameRequest = NameRequestView(
            seq: seq, firstName: "Ada", lastName: "King", requestedAt: nil, state: .refused, reason: NameRequestView.reasonInvalid
        )
        #expect(m.state.request?.reason == NameRequestView.reasonInvalid)
    }

    @Test func wrongEntriesStayOnTheConfirmStep() async {
        repo.nameResults = [.badPin(checksLeft: 7), .badPassword(checksLeft: 6)]
        let m = model()
        atConfirm(m)
        m.submit()
        await m.settle()
        #expect(m.state.step == .confirm && m.state.message == .badPin(checksLeft: 7))
        #expect(m.state.pin.isEmpty && !m.state.submitAllowed)
        m.setPin("246810")
        m.setPassword("wrong")
        m.submit()
        await m.settle()
        #expect(m.state.message == .badPassword(checksLeft: 6))
    }

    @Test func aBackoffCountsDown() async {
        repo.nameResults = [.backoff(retryAfterSeconds: 3)]
        let gate = AsyncStream<Void>.makeStream()
        let ticks = TickGate(gate.stream)
        let m = model { await ticks.next() }
        atConfirm(m)
        m.submit()
        await m.settle()
        #expect(m.state.waitSeconds == 3)
        m.setPin("246810")
        m.setPassword("pw")
        #expect(!m.state.submitAllowed)
        for _ in 0..<3 { gate.continuation.yield() }
        for _ in 0..<50 where m.state.waitSeconds > 0 { await Task.yield() }
        #expect(m.state.waitSeconds == 0 && m.state.submitAllowed)
        gate.continuation.finish()
    }

    @Test func tooSoonFromTheVaultReturnsToTheNamesWithTheDate() async {
        let after = Date(timeIntervalSince1970: 1_793_923_200)
        repo.nameResults = [.tooSoon(allowedAfter: after)]
        let m = model()
        atConfirm(m)
        m.submit()
        await m.settle()
        #expect(m.state.step == .names && m.state.tooSoon && m.state.allowedAfter == after)
    }

    @Test func invalidAndFailedAnswers() async {
        repo.nameResults = [.invalid, .failed(.ownerCheckRequired, code: "owner_check_required")]
        let m = model()
        atConfirm(m)
        m.submit()
        await m.settle()
        #expect(m.state.step == .names && m.state.message == .invalid)
        m.next()
        m.setPin("246810")
        m.setPassword("pw")
        m.submit()
        await m.settle()
        #expect(m.state.message == .failed(.ownerCheckRequired))
    }

    @Test func backAndCancelForgetTheSecrets() {
        let m = model()
        atConfirm(m)
        m.back()
        #expect(m.state.step == .names && m.state.pin.isEmpty && m.state.password.isEmpty)
        #expect(m.state.last == "King", "the names stay")
        m.next()
        m.setPin("246810")
        m.cancel()
        #expect(m.state.pin.isEmpty && m.state.message == nil)
    }
}

/// Releases one tick per value of [stream].
final class TickGate: @unchecked Sendable {
    private var iterator: AsyncStream<Void>.Iterator

    init(_ stream: AsyncStream<Void>) { iterator = stream.makeAsyncIterator() }

    func next() async { _ = await iterator.next() }
}
