import Foundation
import Testing
import VettIDCrypto
import VettIDRelay
import VettIDTesting
@testable import VettIDVault

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// (VAULT-MESSAGING 0.97.0 §10.10 "Placing a call", "Servers and credentials") `call.start` is deposited again, with the same
/// inner `id`, while no answer has come, and given up with its hang-up at the end of the wait; the first answer is the one used;
/// a cached copy marked `withheld: true` is kept as the call. The times are short here: 10 s and 20 s of 30 s in the app.
extension VaultDeviceTests {
    @Test func callStartIsDepositedAgainWithTheSameIdThenRungOff() async throws {
        let (d, v) = try await pairedDevice()
        let api = VaultApi(device: d)
        await #expect(throws: VaultStateError.self) {
            _ = try await api.callStart("conn-1", pinnedFingerprint: Self.callFp, sdp: Self.callSdp, timeout: 1.2, resendAfter: [0.3, 0.6])
        }
        let first = try v.open(try await relay.nextDeposit().payload)
        let second = try v.open(try await relay.nextDeposit().payload)
        let third = try v.open(try await relay.nextDeposit().payload)
        #expect([first, second, third].allSatisfy { $0.type == "call.start" })
        #expect(second.id == first.id && third.id == first.id, "the same request: the vault answers it again, it places nothing again")
        #expect(second.body == first.body && third.body == first.body)
        let end = try v.open(try await relay.nextDeposit().payload)
        #expect(end.type == "call.end")
        #expect(String(bytes: end.body, encoding: .utf8) == #"{"call_id":"\#(try StrictJson.parseObject(first.body).string("call_id"))","reason":"hangup"}"#)
        #expect(await relay.noDeposit(within: 0.3), "nothing more")
        #expect(CallLimits.startResends == [10, 20] && CallLimits.startTimeout == 30, "the app's times (0.97.0)")
    }

    /// Answered after the first resend: the call is placed, and nothing is deposited again.
    @Test func theFirstAnswerEndsTheResends() async throws {
        let (d, v) = try await pairedDevice()
        let api = VaultApi(device: d)
        let starting = Task { try await api.callStart("conn-1", pinnedFingerprint: Self.callFp, sdp: Self.callSdp, timeout: 3, resendAfter: [0.3, 1.5]) }
        let first = try v.open(try await relay.nextDeposit().payload)
        let again = try v.open(try await relay.nextDeposit().payload)
        #expect(again.id == first.id)
        let callId = try StrictJson.parseObject(first.body).string("call_id")
        let exp = try millis(Date().addingTimeInterval(45))
        let answer = try iceBody(JsonBuilder().string("call_id", callId).string("exp", ts(exp)), v, callId).build()
        try await d.handle(try v.seal("call.start", answer, re: first.id, status: Inner.statusOK))
        let call = try await starting.value
        #expect(call.callId == callId)
        // The same answer again (the vault's to the resend) matches nothing now.
        try await d.handle(try v.seal("call.start", answer, re: first.id, status: Inner.statusOK))
        #expect(await relay.noDeposit(within: 2), "no resend after the answer, and no hang-up")
    }

    /// A cached copy marked `withheld: true` (the vault no longer held the call's TURN entry): the call is kept, with the
    /// servers the copy has, and not placed again.
    @Test func aWithheldCopyIsKeptAsTheCall() async throws {
        let (d, v) = try await pairedDevice()
        let api = VaultApi(device: d)
        let starting = Task { try await api.callStart("conn-1", pinnedFingerprint: Self.callFp, sdp: Self.callSdp, timeout: 3, resendAfter: [0.3]) }
        let first = try v.open(try await relay.nextDeposit().payload)
        _ = try v.open(try await relay.nextDeposit().payload)
        let callId = try StrictJson.parseObject(first.body).string("call_id")
        let exp = try millis(Date().addingTimeInterval(45))
        let copy = try iceBody(JsonBuilder().string("call_id", callId).string("exp", ts(exp)), v, callId).bool("withheld", true).build()
        try await d.handle(try v.seal("call.start", copy, re: first.id, status: Inner.statusOK))
        let call = try await starting.value
        #expect(call.callId == callId && call.ice.servers.isEmpty)
        #expect(await relay.noDeposit(within: 0.5), "kept: no hang-up, no new call.start")
    }

    /// The lock gate shut after the first deposit: nothing is deposited again, and the wait goes on to its end.
    @Test func aResendIsHeldByTheLockGate() async throws {
        let (d, v) = try await pairedDevice()
        let api = VaultApi(device: d)
        let starting = Task { try await api.callStart("conn-1", pinnedFingerprint: Self.callFp, sdp: Self.callSdp, timeout: 1, resendAfter: [0.4]) }
        #expect(try v.open(try await relay.nextDeposit().payload).type == "call.start")
        d.setFlushGate { false }
        await #expect(throws: (any Error).self) { _ = try await starting.value }
        d.setFlushGate { true }
        // Only the hang-up may follow (the lock gate lets it through, VaultRequestGateTests): no second call.start.
        let next = try? v.open(try await relay.nextDeposit(timeout: 1).payload)
        #expect(next.map { $0.type != "call.start" } ?? true)
    }
}

// swiftlint:enable line_length
