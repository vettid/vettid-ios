import Foundation
import VettIDCrypto
import VettIDVault
@testable import VettIDCalls

/// Two devices' signalling joined as two vaults would join them, with the real negotiation and key derivation of `VettIDCrypto`
/// in between, and hooks for someone on the path who changes the SDP.
@MainActor
final class Exchange {
    var onOffer: (String) -> String = { $0 }
    var onAnswer: (String) -> String = { $0 }
    private let kCall = (0..<32).map { UInt8($0 + 3) }
    fileprivate var offered: [Int] = []
    fileprivate var offerSdp = ""

    /// What the callee's engine can do (its signalling checks an offer against it before it rings).
    var calleeSuites: [MediaSuite] = [.aes128Gcm]
    private(set) var caller: End!
    private(set) var callee: End!

    init() {
        caller = End(self, isCaller: true)
        callee = End(self, isCaller: false)
    }

    final class End: FakeSignalling {
        private unowned let x: Exchange
        private let isCaller: Bool

        init(_ x: Exchange, isCaller: Bool) {
            self.x = x
            self.isCaller = isCaller
            super.init()
        }

        private var peer: End { isCaller ? x.callee : x.caller }

        override func start(connectionId: String, sdp: String, suites: [MediaSuite]) async throws -> PlacedCall {
            sent.append("start")
            x.offered = try CallMedia.offerOf(MediaSuite.formOne(suites))
            x.offerSdp = x.onOffer(try CallMedia.sdpWithOffer(sdp, offered: x.offered))
            // As `VaultApi.callIncoming`: the callee's suite is fixed when the offer is checked (form 1: suite 1), and an offer
            // without one it can do does not ring.
            let chosen = try? CallMedia.choose(
                offered: try CallMedia.offeredIn(x.offerSdp), supported: MediaSuite.formOne(x.calleeSuites)
            )
            if let chosen {
                peer.deliver(.offer(CallOffer(
                    callId: callId, connectionId: "peer", sdp: CallMedia.sdpWithout(x.offerSdp), exp: at(45_000), ringFor: .seconds(45),
                    servers: [], suite: chosen.chosen
                )))
            }
            return PlacedCall(callId: callId, exp: at(45_000))
        }

        override func answer(callId: String, sdp: String, suites: [MediaSuite]) async throws -> MediaKeys {
            sent.append("answer")
            let chosen: CallMedia.Negotiated
            do {
                chosen = try CallMedia.choose(offered: try CallMedia.offeredIn(x.offerSdp), supported: MediaSuite.formOne(suites))
            } catch is CryptoError {
                throw CallSecurityError("media suites")
            }
            let answerSdp = x.onAnswer(CallMedia.sdpWithChoice(sdp, chosen: chosen.chosen))
            // The caller's device checks the answer against the list it sent.
            if let atCaller = try? CallMedia.chosenIn(answerSdp, offered: x.offered) {
                peer.deliver(.answer(CallAnswer(
                    callId: callId, sdp: CallMedia.sdpWithout(answerSdp), keys: try x.keys(atCaller, caller: true)
                )))
            } else {
                peer.deliver(.answerRejected(callId: callId))
            }
            return try x.keys(chosen, caller: false)
        }

        override func end(callId: String, reason: String) async throws {
            try await super.end(callId: callId, reason: reason)
            peer.deliver(.end(callId: callId, reason: reason))
        }

        override func ringing(callId: String) async throws {
            try await super.ringing(callId: callId)
            peer.deliver(.ringing(callId: callId))
        }
    }

    fileprivate func keys(_ n: CallMedia.Negotiated, caller: Bool) throws -> MediaKeys {
        let a = try CallMedia.directionKey(kCall: kCall, negotiated: n, direction: CallMedia.directionCaller, callId: callId)
        let b = try CallMedia.directionKey(kCall: kCall, negotiated: n, direction: CallMedia.directionCallee, callId: callId)
        return caller ? MediaKeys(suite: n.chosen, send: a, receive: b) : MediaKeys(suite: n.chosen, send: b, receive: a)
    }

    /// What the two media stacks would do once both have their keys: with the same suite and matching keys, media flows;
    /// otherwise each receiver fails to decrypt.
    func connect(_ a: FakeEngine, _ b: FakeEngine) {
        let ok = a.suite == b.suite && a.sendKey == b.receiveKey && a.receiveKey == b.sendKey
        for e in [a, b] {
            e.emit(.connection(.connected))
            e.emit(.cryptor(.receive, ok ? .ok : .decryptionFailed))
        }
    }
}
