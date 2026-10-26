import Foundation
import Testing
import VettIDAltChan
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// A phone that could not tell (IOS-PLAN 0.1.35 §4.9), the recovery view model over the real vault manager: once the new identity's
/// recovery ended too, reads that decide nothing never take the code steps away ("not terminal").
@MainActor
@Suite(.serialized) struct CouldNotTellEndToEndTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let clock = VirtualTime()
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service, requestTimeout: TestVaultPhone.shortRequestTimeout)
    }

    var m: VaultManager { phone.manager }

    func code() throws -> RecoveryCode {
        try #require(RecoveryCode.parseScanned(try service.armRecovery(pin: pin, password: password).qr))
    }

    /// Two reads 5 minutes apart on both clocks, which go back afterwards.
    func twoReads() async throws -> CouldNotTellStage {
        _ = try await m.checkCouldNotTell()
        let (wall, up) = (phone.clockAhead, phone.uptimeAhead)
        phone.clockAhead += 301
        phone.uptimeAhead += 301
        let stage = try await m.checkCouldNotTell()
        (phone.clockAhead, phone.uptimeAhead) = (wall, up)
        return stage
    }

    /// E's open and then N's got no answer, and both recoveries ended.
    func bothEnded() async throws {
        for n in 0..<2 {
            #expect(try await m.registerRecovery(try code()) == .registered(emailHint: service.emailHint))
            service.recoveryOpenAnswers(.neverProcessed)
            _ = try? await m.recoveryOpen(pin: pin, password: password)
            service.cancelRecoveryAtApi()
            #expect(try await twoReads() == (n == 0 ? .newCode : .unlockOrNewCode))
        }
    }

    @Test func readsThatDecideNothingKeepTheCodeStepsOffered() async throws {
        defer { phone.close() }
        try await bothEnded()
        let vm = RecoverViewModel(move: m, vault: m, account: m, tick: clock.tick)
        await vm.settle()
        #expect(vm.state.step == .open && vm.state.couldNotTell == .unlockOrNewCode && vm.state.newCodeAllowed)
        // A check before any pair completes (at once, and a minute later): still the unlock and a new code.
        vm.checkEnded()
        await vm.settle()
        phone.clockAhead += 60
        phone.uptimeAhead += 60
        vm.checkEnded()
        await vm.settle()
        #expect(vm.state.couldNotTell == .unlockOrNewCode && vm.state.newCodeAllowed)
        // The member uses a new recovery: N is registered again, never a third identity.
        vm.scan()
        #expect(vm.state.step == .scan)
        let third = try service.armRecovery(pin: pin, password: password)
        vm.scanned(third.qr)
        await vm.settle()
        #expect(vm.state.step == .open && service.recoveryRegisters.last?.recoveryID == third.recoveryID)
        #expect(Set(service.recoveryRegisters.map { $0.ik }).count == 2)
    }
}
