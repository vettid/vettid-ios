import Foundation
import os
import Testing
import VettIDCrypto
@testable import VettIDCalls
import VettIDVault

/// ``VaultCallGateway`` passes a start's arguments to `VaultApi.callStart` as given: the re-place's shorter wait included
/// (VAULT-MESSAGING 0.97.0 §10.10 "Placing a call"), the app's 30 s and its resend times otherwise.
@MainActor
@Suite struct VaultCallGatewayTests {
    struct Seen: Equatable {
        var connectionId = "", callId: String?, fingerprint = "", sdp = "", suites: [MediaSuite] = [], media = ""
        var timeout: TimeInterval = -1, peerIk: [UInt8]?, resendAfter: [TimeInterval] = [], mayResend: Bool?
    }

    struct NoAnswer: Error {}

    final class FakeStarts: CallStartApi {
        let seen = OSAllocatedUnfairLock(initialState: [Seen]())

        // swiftlint:disable:next function_parameter_count
        func callStart(
            _ connectionId: String, callId: String?, pinnedFingerprint: String, sdp: String, suites: [MediaSuite], media: String,
            timeout: TimeInterval, peerIk: [UInt8]?, resendAfter: [TimeInterval], mayResend: (@Sendable () async -> Bool)?
        ) async throws -> OutgoingCall {
            let may = await mayResend?()
            seen.withLock {
                $0.append(Seen(
                    connectionId: connectionId, callId: callId, fingerprint: pinnedFingerprint, sdp: sdp, suites: suites, media: media,
                    timeout: timeout, peerIk: peerIk, resendAfter: resendAfter, mayResend: may
                ))
            }
            throw NoAnswer()
        }
    }

    struct NoVault: Error {}

    @Test func aStartsArgumentsArePassedAsGiven() async {
        let fake = FakeStarts()
        let gateway = VaultCallGateway(api: { throw NoVault() }, starts: { fake })
        let ik = [UInt8](repeating: 7, count: 32)
        for timeout in [4.5 as TimeInterval?, nil] {
            await #expect(throws: NoAnswer.self) {
                _ = try await gateway.start(
                    connectionId: "conn-1", callId: "call-1", pinnedFingerprint: "fp", sdp: "v=0", suites: [.aes128Gcm], peerIk: ik,
                    timeout: timeout, mayResend: { false }
                )
            }
        }
        let seen = fake.seen.withLock { $0 }
        let first = Seen(
            connectionId: "conn-1", callId: "call-1", fingerprint: "fp", sdp: "v=0", suites: [.aes128Gcm], media: CallWire.mediaAudio,
            timeout: 4.5, peerIk: ik, resendAfter: CallLimits.startResends, mayResend: false
        )
        var second = first
        second.timeout = CallLimits.startTimeout
        #expect(seen == [first, second], "the re-place's wait as given; without one, the app's 30 s")
    }
}
