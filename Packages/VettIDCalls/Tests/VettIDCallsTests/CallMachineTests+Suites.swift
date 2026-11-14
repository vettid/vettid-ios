import Foundation
import Testing
import VettIDCrypto
import VettIDVault
@testable import VettIDCalls

/// Two devices, the real negotiation in between (`Exchange`).
@MainActor
struct Pair {
    let x: Exchange
    let caller: CallMachine
    let callee: CallMachine
    let callerEngines: FakeEngines
    let calleeEngines: FakeEngines
}

extension CallMachineTests {
    var one: [MediaSuite] { [.aes128Gcm] }
    var both: [MediaSuite] { [.aes256Gcm, .aes128Gcm] }

    func pair(_ callerSuites: [MediaSuite], _ calleeSuites: [MediaSuite]) -> Pair {
        let x = Exchange()
        x.calleeSuites = calleeSuites
        let a = FakeEngines(suites: callerSuites)
        let b = FakeEngines(suites: calleeSuites)
        return Pair(x: x, caller: machine(x.caller, a), callee: machine(x.callee, b), callerEngines: a, calleeEngines: b)
    }

    /// Call, ring, answer, and what the two media stacks then do with the keys they were given.
    func talk(_ p: Pair) async throws {
        p.caller.call("peer")
        await runCurrent()
        #expect(try live(p.caller).phase == .ringing)
        p.callee.answer()
        await runCurrent()
        var bothLive = false
        if case .live = p.caller.state, case .live = p.callee.state { bothLive = true }
        if bothLive { p.x.connect(p.callerEngines.last, p.calleeEngines.last) }
        await runCurrent()
    }

    @Test func aSuiteOneDeviceAndASuiteOneAndTwoDeviceTalkOnSuiteOne() async throws {
        for (a, b) in [(one, both), (both, one)] {
            let p = pair(a, b)
            try await talk(p)
            #expect(try live(p.caller).phase == .active)
            #expect(try live(p.callee).phase == .active)
            #expect(p.callerEngines.last.suite == .aes128Gcm)
            #expect(p.calleeEngines.last.suite == .aes128Gcm)
        }
    }

    @Test func twoDevicesThatCanDoSuiteTwoTalkOnSuiteOneInFormOneWithCryptorsMadeForIt() async throws {
        // Form 1 offers and chooses suite 1 only (VAULT-MESSAGING "Call forms", rules 1 and 3).
        let p = pair(both, both)
        try await talk(p)
        #expect(try live(p.caller).phase == .active)
        #expect(try live(p.callee).phase == .active)
        for e in [p.callerEngines.last, p.calleeEngines.last] {
            // Made for the call's suite before any SDP, and keyed for that same suite: nothing is remade.
            #expect(e.madeFor == .aes128Gcm)
            #expect(e.suite == .aes128Gcm)
        }
    }

    @Test func aSuiteListChangedOnTheWayGivesNoCall() async throws {
        let p = pair(both, both)
        p.x.onOffer = { $0.replacingOccurrences(of: "a=vettid-media-suites:1", with: "a=vettid-media-suites:2 1") }
        try await talk(p)
        // The callee answers 1 from the changed list, the caller derives with the list it sent: both set keys for suite 1, but
        // not the same keys: nothing decrypts, both end the call.
        #expect(p.callerEngines.last.suite == .aes128Gcm)
        #expect(p.calleeEngines.last.suite == .aes128Gcm)
        #expect(p.callerEngines.last.sendKey != p.calleeEngines.last.receiveKey)
        #expect(try ended(p.caller).reason == .notEncrypted)
        #expect(try ended(p.callee).reason == .notEncrypted)
        #expect(p.callerEngines.last.closed && p.calleeEngines.last.closed)
    }

    @Test func aChoiceRewrittenOnTheWayGivesNoCall() async throws {
        // A choice that was never offered is refused when it is read: the caller sets no key at all.
        for (a, b) in [(one, both), (both, both)] {
            let q = pair(a, b)
            q.x.onAnswer = { $0.replacingOccurrences(of: "a=vettid-media-suite:1", with: "a=vettid-media-suite:2") }
            try await talk(q)
            #expect(try ended(q.caller).reason == .notEncrypted)
            #expect(q.callerEngines.last.suite == nil)
            #expect(try ended(q.callee).reason == .failed, "the callee is told")
        }
    }

    @Test func aCallStartNeverOffersAnythingButSuiteOne() {
        // Guard (VAULT-MESSAGING "Call forms" rule 3, "Mixed releases"): whatever the engine can do, what a `call.start` offers
        // is [1] or nothing, until form 1 is retired.
        let s = FakeSignalling()
        for suites in [one, both, [.aes256Gcm], MediaSuite.allCases, []] as [[MediaSuite]] {
            let offered = s.offerable(suites)
            #expect(offered.isEmpty || offered == one, "\(suites) -> \(offered)")
            #expect(suites.contains(.aes128Gcm) == (offered == one))
        }
    }

    @Test func aDeviceWithoutSuiteOnePlacesNoFormOneCall() async throws {
        let p = pair([.aes256Gcm], one)
        p.caller.call("peer")
        await runCurrent()
        #expect(try ended(p.caller).reason == .notEncrypted)
        #expect(p.x.caller.sent.isEmpty, "nothing was sent")
    }

    @Test func aFormOneOfferWithoutSuiteOneDoesNotRing() async throws {
        let p = pair(one, both)
        p.x.onOffer = { $0.replacingOccurrences(of: "a=vettid-media-suites:1", with: "a=vettid-media-suites:2") }
        p.caller.call("peer")
        await runCurrent()
        #expect(p.calleeEngines.created.isEmpty, "the callee's engine was never made")
        if case .live = p.callee.state { Issue.record("the callee rang") }
    }

    @Test func keysForAnotherSuiteThanTheCryptorsWereMadeForEndTheCall() async throws {
        // The engine never remakes its cryptors: keys for another suite are refused, and the call ends as not encrypted.
        let s = FakeSignalling()
        let e = FakeEngines(suites: both)
        let m = machine(s, e)
        s.answerResult = { MediaKeys(suite: .aes256Gcm, send: filled(32, 1), receive: filled(32, 2)) }
        s.deliver(offer())
        await runCurrent()
        m.answer()
        await runCurrent()
        #expect(e.last.madeFor == .aes128Gcm)
        #expect(e.last.suite == nil, "no key was taken")
        #expect(try ended(m).reason == .notEncrypted)
        #expect(e.last.closed)
    }

    @Test func theTimingsAreThePlans() {
        let t = CallTimings()
        #expect(t.gather == .seconds(8) && t.connect == .seconds(60) && t.decrypt == .seconds(20))
        #expect(t.minRing == .seconds(10) && t.maxRing == .seconds(60))
        #expect(t.incomingGrace == .seconds(3) && t.maxIncomingRing == .seconds(93))
        #expect(t.iceBatch == .milliseconds(200) && t.iceInterval == .milliseconds(300) && t.maxIceMessages == 100)
        #expect(t.diagnosticsEvery == .seconds(1) && t.relisten == .seconds(1))
    }

    @Test func noSecretIsPrinted() {
        let keys = MediaKeys(suite: .aes128Gcm, send: filled(16, 0xAB), receive: filled(16, 0xCD))
        let offer = CallOffer(
            callId: callId, connectionId: "c", sdp: "v=0 SDPSECRET", exp: t0, ringFor: .seconds(1),
            servers: [CallWire.IceServer(urls: ["turn:x"], username: "USERSECRET", credential: "CREDSECRET")], suite: .aes128Gcm
        )
        var dumped = ""
        for x: Any in [keys, offer, SignalEvent.offer(offer), SignalEvent.answer(CallAnswer(callId: callId, sdp: "SDPSECRET", keys: keys)),
                       SignalEvent.ice(callId: callId, candidates: [candidate(1)])] {
            dump(x, to: &dumped)
            dumped += "\(x) \(String(reflecting: x))"
        }
        for secret in ["SDPSECRET", "USERSECRET", "CREDSECRET", "192.0.2"] {
            #expect(!dumped.contains(secret), "\(secret)")
        }
        #expect(keys.description == "MediaKeys(suite=1, [redacted])")
    }
}
