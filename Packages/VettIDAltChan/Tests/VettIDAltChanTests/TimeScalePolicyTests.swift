import Foundation
import Testing
@testable import VettIDAltChan
import VettIDCrypto

/// The time scale a build accepts (STAGING-TIME-SCALE §4 item 4, §5.2; VAULT-MESSAGING 0.43.0 §11.10.9): a production
/// build refuses any value other than 1 and sends nothing; a staging build accepts 1 and 24; what the instance said comes
/// back with the outcome and the preflight.
@Suite struct TimeScalePolicyTests {
    private let vaultID = "0123456789abcdef0123456789abcdef"

    @Test func eachBuildAcceptsItsScales() {
        #expect(TimeScalePolicy.production.accepts(1))
        #expect(!TimeScalePolicy.production.accepts(24) && !TimeScalePolicy.production.accepts(2))
        #expect(TimeScalePolicy.staging.accepts(1) && TimeScalePolicy.staging.accepts(24))
        #expect(!TimeScalePolicy.staging.accepts(2) && !TimeScalePolicy.staging.accepts(3_600))
        #expect(TimeScalePolicy.development.accepts(1) && TimeScalePolicy.development.accepts(3_600))
        #expect(TimeScalePolicy.development.accepts(86_400) && !TimeScalePolicy.development.accepts(86_401))
        #expect(AltTrust.production.timeScales == .production)
        #expect(throws: TimeScaleRefused(scale: 24)) { try TimeScalePolicy.production.check(24) }
    }

    @Test func aProductionBuildSendsNothingToAScaledInstance() async throws {
        let (api, p, f) = try AltChannelFlowTests().setUp([try FakeEnclave("inst-a", timeScale: 24)])
        await #expect(throws: TimeScaleRefused(scale: 24)) {
            _ = try await f.enroll(party: p, vaultID: vaultID, userGuid: "guid-1", pin: "246802", attester: SoftAttester())
        }
        await #expect(throws: TimeScaleRefused(scale: 24)) { _ = try await f.preflight(p.state) }
        p.vaultID = vaultID
        await #expect(throws: TimeScaleRefused(scale: 24)) {
            _ = try await f.unlock(party: p, userGuid: "guid-1", pin: "246802", attester: SoftAttester())
        }
        #expect(!api.requests.contains { $0.path == "/api/vault/enroll" || $0.path.hasSuffix("/unlock") })
    }

    @Test func aProductionBuildTakesAnInstanceWithoutTheScaleOrWithOne() async throws {
        for scale in [nil, UInt64(1)] {
            let (_, p, f) = try AltChannelFlowTests().setUp([try FakeEnclave("inst-a", timeScale: scale)])
            let out = try await f.enroll(party: p, vaultID: vaultID, userGuid: "guid-1", pin: "246802", attester: SoftAttester())
            #expect(out.ok && out.timeScale == 1)
            #expect(try await f.preflight(p.state).timeScale == 1)
        }
    }

    @Test func aStagingBuildTakesTwentyFourAndReportsIt() async throws {
        let (_, p, f) = try AltChannelFlowTests().setUp([try FakeEnclave("inst-a", timeScale: 24)], timeScales: .staging)
        let out = try await f.enroll(party: p, vaultID: vaultID, userGuid: "guid-1", pin: "246802", attester: SoftAttester())
        #expect(out.ok && out.timeScale == 24)
        #expect(try await f.preflight(p.state).timeScale == 24)
        p.vaultID = out.vaultID
        p.state = p.state.applyingEnrolled(stateSeq: 1)
        let u = try await f.unlock(party: p, userGuid: "guid-1", pin: "246802", attester: SoftAttester())
        #expect(u.ok && u.timeScale == 24)
    }

    @Test func aStagingBuildRefusesAnyOtherScale() async throws {
        let (api, p, f) = try AltChannelFlowTests().setUp([try FakeEnclave("inst-a", timeScale: 3_600)], timeScales: .staging)
        await #expect(throws: TimeScaleRefused(scale: 3_600)) {
            _ = try await f.enroll(party: p, vaultID: vaultID, userGuid: "guid-1", pin: "246802", attester: SoftAttester())
        }
        #expect(!api.requests.contains { $0.path == "/api/vault/enroll" })
    }
}
