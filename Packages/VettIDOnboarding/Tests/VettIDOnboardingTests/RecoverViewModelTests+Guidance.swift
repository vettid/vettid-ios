import Foundation
import Testing
import VettIDAltChan
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// The guidance of a failed registration on the code steps.
@MainActor
extension RecoverViewModelTests {
    /// A failure's guidance goes when the member tries again, and does not follow a registration or a refusal after it.
    @Test func guidanceGoesWithTheNextTry() async throws {
        let vm = await model()
        let unknown = { self.vault.fail["registerRecovery"] = VaultFailure(.other, code: VaultManager.codeRecoveryOpenUnknown) }
        unknown()
        vm.scan()
        vm.scanned(qr)
        await vm.settle()
        #expect(vm.state.guidance == .retry)
        vm.scan()
        #expect(vm.state.guidance == nil && vm.state.error == nil)
        unknown()
        vm.scanned(qr)
        await vm.settle()
        #expect(vm.state.guidance == .retry)
        vm.type()
        #expect(vm.state.guidance == nil)
        unknown()
        vm.scan()
        vm.scanned(qr)
        await vm.settle()
        #expect(vm.state.guidance == .retry)
        _ = vm.back()
        #expect(vm.state.guidance == nil && vm.state.step == .intro)
        unknown()
        vm.scan()
        vm.scanned(qr)
        await vm.settle()
        vault.registrations = [.refused(code: "bad_code")]
        vm.scan()
        vm.scanned(qr)
        await vm.settle()
        #expect(vm.state.refusal == .badCode && vm.state.guidance == nil)
        unknown()
        vm.scan()
        vm.scanned(qr)
        await vm.settle()
        #expect(vm.state.guidance == .retry)
        vm.scan()
        vm.scanned(qr)
        await vm.settle()
        #expect(vm.state.step == .open && vm.state.guidance == nil)
    }
}
