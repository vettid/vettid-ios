import Foundation
import Testing
import VettIDKeys
@testable import VettIDData
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The member's own account is memory only and forgotten whenever the vault is not open (IOS-PLAN §4.7): ``OwnAccount``,
/// the gate ``isOwnProfileOpen(_:_:)``, the steps of the vault manager, and the account record that no longer keeps it.
/// Mirrors vettid-android `OwnAccountTest`.
@MainActor
@Suite struct OwnAccountTests {
    static let snapJSON = #"{"as_of":"2026-10-21T00:00:00Z","email_hint":"a***@example.org","email":"ada@example.org","state":"member","first_name":"Ada","last_name":"Lovelace"}"#
    let snap: AccountSnapshot
    let request = NameRequest(seq: 3, firstName: "Ada", lastName: "King", requestedAt: nil, state: "pending")
    let open = { true }

    init() throws {
        snap = try AccountUpdateTests.snapshot(Self.snapJSON)
    }

    func view(_ s: String?, _ r: NameRequest?) throws -> AccountView { try AccountUpdateTests.view(s, 1, r) }

    static func check(_ s: OwnerCheckState) -> OwnerCheckView {
        OwnerCheckView(state: s, deadline: FakeDates.date("2026-10-22T00:00:00Z"), intervalSeconds: 86_400, failures: 0, hold: true)
    }

    @Test func anAnswerIsKeptWhileTheVaultIsOpen() throws {
        let own = OwnAccount()
        #expect(own.keep(mark: own.mark(), view: try view(Self.snapJSON, request), open: open) != nil)
        #expect(own.snapshot == snap && own.nameRequest == request)
    }

    @Test func aLockForgetsTheSnapshotAndTheNameRequest() throws {
        let own = OwnAccount()
        _ = own.keep(mark: own.mark(), view: try view(Self.snapJSON, request), open: open)
        own.forget()
        #expect(own.snapshot == nil && own.nameRequest == nil)
    }

    @Test func anAnswerOnItsWayWhenTheVaultLocksIsDropped() throws {
        let own = OwnAccount()
        let mark = own.mark()
        // `account.get` was sent; the vault locks (or the check falls due) before its answer arrives.
        own.forget()
        #expect(own.keep(mark: mark, view: try view(Self.snapJSON, request), open: open) == nil)
        #expect(own.snapshot == nil && own.nameRequest == nil)
    }

    @Test func anAnswerArrivingWhileTheVaultIsNotOpenIsDropped() throws {
        let own = OwnAccount()
        #expect(own.keep(mark: own.mark(), view: try view(Self.snapJSON, request), open: { false }) == nil)
        #expect(own.snapshot == nil)
        #expect(!own.request(mark: own.mark(), request, open: { false }))
        #expect(own.nameRequest == nil)
    }

    @Test func aNameRequestIsKeptInMemoryAndForgottenAtTheLock() {
        let own = OwnAccount()
        let mark = own.mark()
        #expect(own.request(mark: mark, request, open: open))
        #expect(own.nameRequest == request)
        own.forget()
        #expect(own.nameRequest == nil)
        // A request answered after the lock: not kept.
        #expect(!own.request(mark: mark, request, open: open))
        #expect(own.nameRequest == nil)
    }

    @Test func theAnswerAfterTheNextUnlockBringsTheNamesBack() throws {
        let own = OwnAccount()
        _ = own.keep(mark: own.mark(), view: try view(Self.snapJSON, nil), open: open)
        own.forget()
        #expect(own.keep(mark: own.mark(), view: try view(Self.snapJSON, nil), open: open) != nil)
        let info = try #require(LocalAccount(userGuid: "", vaultID: "", emailHint: "a***@example.org").info(snapshot: own.snapshot, nameRequest: own.nameRequest))
        #expect(info.fullName == "Ada Lovelace" && info.displayEmail == "ada@example.org")
    }

    @Test func whileTheVaultIsNotOpenOnlyTheMaskedEmailIsShown() throws {
        let own = OwnAccount()
        _ = own.keep(mark: own.mark(), view: try view(Self.snapJSON, request), open: open)
        own.forget()
        let info = try #require(LocalAccount(userGuid: "", vaultID: "", emailHint: "a***@example.org").info(snapshot: own.snapshot, nameRequest: own.nameRequest))
        #expect(info.fullName == nil && info.firstName == nil && info.email == nil && info.nameRequest == nil)
        #expect(info.displayEmail == "a***@example.org")
    }

    @Test func theOwnProfileIsOpenOnlyWhenUnlockedAndNeitherHeldNorDue() {
        #expect(isOwnProfileOpen(.unlocked, nil))
        #expect(isOwnProfileOpen(.unlocked, Self.check(.ok)))
        #expect(!isOwnProfileOpen(.unlocked, Self.check(.held)))
        #expect(!isOwnProfileOpen(.unlocked, Self.check(.due)))
        #expect(!isOwnProfileOpen(.locked, nil))
        #expect(!isOwnProfileOpen(.signedOut, nil))
        #expect(!isOwnProfileOpen(.starting, nil))
        #expect(!isOwnProfileOpen(.deleting, Self.check(.ok)))
    }

    @Test func anOlderAnswerNeverReplacesANewerOne() throws {
        let own = OwnAccount()
        // Two `account.get`s on their way; the newer answer lands first.
        let mark = own.mark()
        let newer = Self.snapJSON.replacingOccurrences(of: "00:00:00Z", with: "12:00:00Z").replacingOccurrences(of: "Lovelace", with: "King")
        #expect(own.keep(mark: mark, view: try view(newer, nil), open: open) != nil)
        #expect(own.keep(mark: mark, view: try view(Self.snapJSON, nil), open: open) == nil)
        #expect(own.snapshot?.lastName == "King")
        // What a kept answer replaced is reported (the shared profile is read again when the names changed).
        let newest = newer.replacingOccurrences(of: "12:00:00Z", with: "13:00:00Z").replacingOccurrences(of: "King", with: "Byron")
        let kept = try #require(own.keep(mark: mark, view: try view(newest, nil), open: open))
        #expect(kept.before?.lastName == "King" && kept.update.snapshot?.lastName == "Byron")
    }

    @Test func aPhaseOtherThanUnlockedOrStartingForgetsAndAnUnlockReads() {
        #expect(OwnProfileStep.onPhase(.unlocked) == .read)
        #expect(OwnProfileStep.onPhase(.starting) == .none)
        #expect(OwnProfileStep.onPhase(.locked) == .forget)
        #expect(OwnProfileStep.onPhase(.signedOut) == .forget)
        #expect(OwnProfileStep.onPhase(.deleting) == .forget)
        #expect(OwnProfileStep.onPhase(.setup(.newVault)) == .forget)
    }

    @Test func enteringTheHoldForgetsAndThePassedCheckReadsAgain() {
        #expect(OwnProfileStep.held(Self.check(.held)))
        #expect(OwnProfileStep.held(Self.check(.due)))
        #expect(!OwnProfileStep.held(Self.check(.ok)))
        #expect(!OwnProfileStep.held(nil))
        #expect(OwnProfileStep.onCheck(wasHeld: false, held: true, phase: .unlocked) == .forget)
        #expect(OwnProfileStep.onCheck(wasHeld: true, held: false, phase: .unlocked) == .read)
        // Passed while locked: the unlock reads it.
        #expect(OwnProfileStep.onCheck(wasHeld: true, held: false, phase: .locked) == .none)
        #expect(OwnProfileStep.onCheck(wasHeld: true, held: true, phase: .unlocked) == .none)
        #expect(OwnProfileStep.onCheck(wasHeld: false, held: false, phase: .unlocked) == .none)
    }

    @Test func theStartFindsTheOwnAccountOfAnOlderBuildInTheRecord() throws {
        #expect(holdsLegacyOwnAccount(Array(#"{"user_guid":"u","snapshot":{"v":1}}"#.utf8)))
        #expect(holdsLegacyOwnAccount(Array(#"{"user_guid":"u","name_request":{"seq":1}}"#.utf8)))
        #expect(!holdsLegacyOwnAccount(Array(#"{"user_guid":"u","email_hint":"a***@example.org"}"#.utf8)))
        #expect(!holdsLegacyOwnAccount(Array("not json".utf8)))
        #expect(!holdsLegacyOwnAccount(Array("[1]".utf8)))
        // What is written back holds neither.
        let read = try JSONDecoder().decode(LocalAccount.self, from: Data(#"{"user_guid":"u","snapshot":{"v":1}}"#.utf8))
        #expect(!holdsLegacyOwnAccount(Array(try JSONEncoder().encode(read))))
    }

    @Test func theShellShowsTheAccountOnlyFromTheOpenVaultsSnapshot() throws {
        let own = OwnAccount()
        let record = LocalAccount(userGuid: "", vaultID: "", emailHint: "a***@example.org")
        // Locked (nothing in memory): the masked hint is there for the unlock screen, not for the shell.
        let locked = record.info(snapshot: own.snapshot, nameRequest: own.nameRequest)
        #expect(locked?.emailHint == "a***@example.org")
        #expect(locked.shownInShell == nil)
        #expect(AccountInfo?.none.shownInShell == nil)
        _ = own.keep(mark: own.mark(), view: try view(Self.snapJSON, nil), open: open)
        let opened = record.info(snapshot: own.snapshot, nameRequest: own.nameRequest)
        #expect(opened.shownInShell?.fullName == "Ada Lovelace")
    }
}

// swiftlint:enable line_length
