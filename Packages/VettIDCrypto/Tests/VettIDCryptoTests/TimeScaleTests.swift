import Foundation
import Testing
@testable import VettIDCrypto

/// The release's time scale (VAULT-MESSAGING 0.43.0 §11.10.9; STAGING-TIME-SCALE §3, §5.2): read from the descriptor
/// and the transfer bundle, 1 when absent, 1 to 86,400 otherwise; waits divided and rounded up to a whole second.
struct TimeScaleTests {
    private func descriptor(_ scale: UInt64?) throws -> [UInt8] {
        Descriptor.marshal(
            instanceID: "inst-a", etk: try KemPrivateKey.generate().publicKey, release: String(repeating: "a3", count: 48),
            notAfter: try Timestamps.parseSeconds("2026-10-19T12:00:00Z"), capabilities: ["recovery_r"], timeScale: scale
        )
    }

    @Test func theDescriptorCarriesTheScale() throws {
        #expect(try Descriptor.parse(try descriptor(nil)).timeScale == 1)
        #expect(try Descriptor.parse(try descriptor(1)).timeScale == 1)
        #expect(try Descriptor.parse(try descriptor(24)).timeScale == 24)
        #expect(try Descriptor.parse(try descriptor(86_400)).timeScale == 86_400)
        // 0, above the development bound, or not an integer: malformed, as any malformed descriptor.
        expectCrypto(.format) { _ = try Descriptor.parse(try descriptor(0)) }
        expectCrypto(.format) { _ = try Descriptor.parse(try descriptor(86_401)) }
        let text = try #require(String(bytes: try descriptor(24), encoding: .utf8))
        expectCrypto(.format) { _ = try Descriptor.parse(Array(text.replacingOccurrences(of: ":24}", with: ":\"24\"}").utf8)) }
        expectCrypto(.format) { _ = try Descriptor.parse(Array(text.replacingOccurrences(of: ":24}", with: ":24.5}").utf8)) }
    }

    @Test func theTransferBundleCarriesTheScale() throws {
        let signer = Ed25519PrivateKey.generate()
        let vault = Principal(
            ik: Ed25519PrivateKey.generate().publicKey, kem: try KemPrivateKey.generate().publicKey,
            relay: RelayAddr(url: "https://relay.vettid.org", mailbox: Mailbox.id(signer.publicKey), pk: signer.publicKey)
        )
        let exp = try Timestamps.parseSeconds("2026-10-19T12:10:00Z")
        let id = "01JB2Z6V9K3M4N5P6Q7R8S9T0V"
        func bundle(_ kind: InviteKind, _ scale: UInt64?) -> InviteBundle {
            InviteBundle(
                kind: kind, inviteID: id, remote: false, vault: vault, token: "v4.public.b3Blbg", exp: exp,
                capabilities: kind == .app ? ["recovery_r"] : nil, timeScale: scale
            )
        }
        let scaled = try InviteBundle.parse(try bundle(.app, 24).marshal())
        #expect(scaled.timeScale == 24 && scaled.timeScaleOrReal == 24)
        let plain = try InviteBundle.parse(try bundle(.app, nil).marshal())
        #expect(plain.timeScale == nil && plain.timeScaleOrReal == 1)
        // Only a transfer bundle carries it, and only 1 to 86,400.
        expectCrypto(.format) { _ = try bundle(.connection, 24).marshal() }
        expectCrypto(.format) { _ = try bundle(.app, 0).marshal() }
        let text = try #require(String(bytes: try bundle(.app, 24).marshal(), encoding: .utf8))
        let zero = text.replacingOccurrences(of: "\"time_scale\":24", with: "\"time_scale\":0")
        expectCrypto(.format) { _ = try InviteBundle.parse(Array(zero.utf8)) }
    }

    @Test func aWaitIsDividedAndRoundedUpToASecond() {
        #expect(TimeScale.scaled(86_400, by: 24) == 3_600)
        #expect(TimeScale.scaled(72 * 3_600, by: 24) == 3 * 3_600)
        #expect(TimeScale.scaled(7 * 86_400, by: 24) == 7 * 3_600)
        // 1 h becomes 2.5 minutes; 7 s at 24 rounds up to 1 s.
        #expect(TimeScale.scaled(3_600, by: 24) == 150)
        #expect(TimeScale.scaled(7, by: 24) == 1)
        #expect(TimeScale.scaled(86_400, by: 1) == 86_400)
        #expect(TimeScale.scaled(86_400, by: 0) == 86_400)
        #expect(TimeScale.scaledMs(7 * 86_400_000, by: 24) == 7 * 3_600_000)
        #expect(TimeScale.scaledMs(86_400_000, by: 86_400) == 1_000)
        #expect(TimeScale.scaledMs(1_000, by: 1) == 1_000)
    }
}
