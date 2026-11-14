import Foundation
import Testing
import VettIDCrypto
import VettIDVault
@testable import VettIDCalls

extension CallMachineTests {
    // (C2, VAULT-MESSAGING "Key confirmation") Against a C2 vault the answering device holds its microphone back until its
    // receiver first decrypts a frame; the member's own mute still applies after. No frame 20 s after the connection is up:
    // the call ends as not encrypted. Against an S10 vault nothing is held.
    // swiftlint:disable:next function_body_length
    @Test func theAnsweringDeviceSendsNothingBeforeAFrameDecrypts() async throws {
        // Keyed on the offer's form: here the vault probe has not found the vault C2 (yet), and the hold still applies.
        signalling.c2 = false
        let m = machine()
        signalling.deliver(offer(formTwo: true))
        await runCurrent()
        m.answer()
        await runCurrent()
        let engine = engines.last
        #expect(engine.holding, "held from the answer on")
        engine.emit(.connection(.connected))
        await runCurrent()
        #expect(engine.holding, "connected is not enough")
        engine.emit(.cryptor(.send, .ok))
        await runCurrent()
        #expect(engine.holding, "its own sender working is not enough")
        engine.emit(.cryptor(.receive, .ok))
        await runCurrent()
        #expect(!engine.holding)
        await advance(60_000)
        #expect(try live(m).phase == .active)
        m.hangUp()
        await runCurrent()
        m.dismiss()

        // No frame decrypts: 20 s after the connection, not encrypted.
        signalling.deliver(offer("01JB2Z6V9K3M4N5P6Q7R8S9T70", formTwo: true))
        await runCurrent()
        m.answer()
        await runCurrent()
        engines.last.emit(.connection(.connected))
        await runCurrent()
        await advance(19_999)
        #expect(try live(m).phase == .active)
        await advance(2)
        #expect(try ended(m).reason == .notEncrypted)
        #expect(engines.last.holding)

        // The caller's call.end{failed} while this device is held (its wrong confirm): the same text.
        m.dismiss()
        signalling.deliver(offer("01JB2Z6V9K3M4N5P6Q7R8S9T72", formTwo: true))
        await runCurrent()
        m.answer()
        await runCurrent()
        #expect(try live(m).formTwo, "a form 2 call says so")
        signalling.deliver(.end(callId: "01JB2Z6V9K3M4N5P6Q7R8S9T72", reason: CallReason.failed))
        await runCurrent()
        #expect(try ended(m).reason == .notEncrypted)

        // A form 1 offer (an S10 peer), even on a C2 vault: nothing held.
        m.dismiss()
        signalling.c2 = true
        signalling.deliver(offer("01JB2Z6V9K3M4N5P6Q7R8S9T71"))
        await runCurrent()
        m.answer()
        await runCurrent()
        #expect(!engines.last.holding)
        #expect(try !live(m).formTwo)
        // Not held, the caller's call.end{failed} keeps its usual meaning.
        signalling.deliver(.end(callId: "01JB2Z6V9K3M4N5P6Q7R8S9T71", reason: CallReason.failed))
        await runCurrent()
        #expect(try ended(m).reason != .notEncrypted)
    }

    @Test func noPathBetweenTheTwoDevices() async throws {
        let m = machine()
        try await placed(m)
        engines.last.emit(.localCandidate(candidate(1)))
        signalling.deliver(answerEvent().0)
        await runCurrent()
        await advance(59_999)
        #expect(try live(m).phase == .connecting)
        await advance(2)
        #expect(try ended(m).reason == .couldNotConnect)
        #expect(signalling.sent.last == "end(\(callId), failed)")
        m.dismiss()

        // The media stack gives up first.
        try await placed(m)
        signalling.deliver(answerEvent().0)
        await runCurrent()
        engines.last.emit(.connection(.failed))
        await runCurrent()
        #expect(try ended(m).reason == .couldNotConnect)
    }

    @Test func aPathLostDuringTheCall() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(answerEvent().0)
        await runCurrent()
        let engine = engines.last
        engine.emit(.connection(.connected))
        await runCurrent()
        engine.emit(.connection(.disconnected))
        await runCurrent()
        #expect(try live(m).reconnecting)
        #expect(try live(m).phase == .active)
        engine.emit(.connection(.connected))
        await runCurrent()
        #expect(try !live(m).reconnecting)
        await advance(5_000)
        engine.emit(.connection(.disconnected))
        engine.emit(.connection(.failed))
        await runCurrent()
        #expect(try ended(m).reason == .connectionLost)
        #expect(try ended(m).duration == .milliseconds(5_000))
        #expect(signalling.sent.last == "end(\(callId), failed)")
    }

    @Test func framesThatDoNotDecryptEndTheCall() async throws {
        for state in [CryptorState.decryptionFailed, .internalError, .unknown, .missingKey] {
            let signalling = FakeSignalling()
            let m = machine(signalling)
            m.call("conn-1")
            await runCurrent()
            let engine = engines.last
            // Before the answer the caller has no key: its sender says so and sends nothing. Not a failure.
            engine.emit(.cryptor(.send, .missingKey))
            await runCurrent()
            #expect(try live(m).phase == .calling)
            signalling.deliver(answerEvent().0)
            await runCurrent()
            engine.emit(.connection(.connected))
            engine.emit(.cryptor(.send, .ok))
            await runCurrent()
            #expect(try live(m).phase == .active)
            signalling.sent.removeAll()
            engine.emit(.cryptor(.receive, state))
            await runCurrent()
            #expect(try ended(m).reason == .notEncrypted, "\(state)")
            // Ended, not repaired: the key is not set a second time.
            #expect(signalling.sent == ["end(\(callId), failed)"])
            #expect(engine.calls.filter { $0 == "setKeys" }.count == 1)
            #expect(engine.closed)
        }
    }

    /// An SDP with a media section the frame cryptors do not cover. The signalling refuses such SDP before it gets here; an
    /// engine that still finds one says so, and the call ends: on the caller with the answer, on the callee with the offer,
    /// before any answer is sent.
    @Test func mediaOutsideTheFrameEncryptionEndsTheCall() async throws {
        let strict = FakeEngines(make: {
            let e = FakeEngine()
            e.onRemoteSdp = { throw MediaNotEncryptedError("2 media sections") }
            return e
        })
        let m = machine(nil, strict)
        try await placed(m)
        signalling.deliver(answerEvent().0)
        await runCurrent()
        #expect(try ended(m).reason == .notEncrypted)
        #expect(signalling.sent.last == "end(\(callId), failed)")
        #expect(strict.last.closed)

        let other = FakeSignalling()
        let callee = machine(other, strict)
        other.deliver(offer())
        await runCurrent()
        callee.answer()
        await runCurrent()
        #expect(try ended(callee).reason == .notEncrypted)
        #expect(other.sent == ["ringing(\(callId))", "end(\(callId), failed)"])
        #expect(!strict.last.calls.contains("setKeys"), "no key was ever set")
    }

    /// Audio on an SSRC nobody announced shows as a second received stream. Its frames go through the same decryption and are
    /// not played; the call ends all the same.
    @Test func aSecondReceivedAudioStreamEndsTheCall() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(answerEvent().0)
        await runCurrent()
        let engine = engines.last
        engine.emit(.connection(.connected))
        await advance(3_000)
        #expect(try live(m).phase == .active)
        engine.streams = 2
        await advance(1_001)
        #expect(try ended(m).reason == .notEncrypted)
        #expect(signalling.sent.last == "end(\(callId), failed)")
        #expect(engine.closed)
    }

    /// Whatever ends the listening to the vault's events, it starts again. (The signalling refuses and counts what goes wrong,
    /// so this is the second lock.)
    @Test func theListeningToTheVaultStartsAgainAfterAFailure() async throws {
        final class Flaky: FakeSignalling {
            var collections = 0

            override func events() -> AsyncThrowingStream<SignalEvent, Error> {
                collections += 1
                if collections == 1 { return AsyncThrowingStream { $0.finish(throwing: StartFailure()) } }
                return super.events()
            }
        }
        let flaky = Flaky()
        let m = machine(flaky)
        await runCurrent()
        #expect(m.listenRestarts == 1)
        await advance(1_001)
        flaky.deliver(offer())
        await runCurrent()
        #expect(try live(m).phase == .incoming)
    }

    /// The vault's answer to `call.start` and the events it passes on reach the machine through two queues, so an event of the
    /// call can be handled before the call has its id. It is held, not dropped.
    @Test func whatArrivesBeforeTheVaultsAnswerToCallStartIsNotLost() async throws {
        // Busy: before the fix the call stayed "calling" and ended "no answer" 45 s later.
        let m = machine()
        signalling.holdStart()
        m.call("conn-1")
        await runCurrent()
        signalling.deliver(.end(callId: callId, reason: "busy"))
        await runCurrent()
        #expect(try live(m).phase == .starting)
        signalling.releaseStart()
        await runCurrent()
        #expect(try ended(m).reason == .busy)
        #expect(try ended(m).callId == callId)
        #expect(noEnd(signalling))

        // Ringing, candidates and the answer, all early, in order: before the fix the keys were wiped and the call could never
        // connect.
        let s2 = FakeSignalling()
        s2.holdStart()
        let m2 = machine(s2)
        m2.call("conn-1")
        await runCurrent()
        s2.deliver(.ringing(callId: callId))
        s2.deliver(.ice(callId: callId, candidates: [candidate(7)]))
        s2.deliver(answerEvent().0)
        await runCurrent()
        s2.releaseStart()
        await runCurrent()
        let engine = engines.last
        #expect(try live(m2).phase == .connecting)
        #expect(engine.calls == ["createOffer", "startGathering(0)", "setKeys", "acceptAnswer", "addRemoteCandidates(1)"])
        #expect(engine.sendKey == filled(32, 5))
        #expect(m2.diagnostics.tapToRingingMs != nil)

        // An early event of another call is not this call's; an early answer's keys do not outlive a hang-up or a refused start.
        let s3 = FakeSignalling()
        s3.holdStart()
        let m3 = machine(s3)
        m3.call("conn-1")
        await runCurrent()
        let (stray, strayKeys) = answerEvent()
        s3.deliver(.end(callId: "01JB2Z6V9K3M4N5P6Q7R8S9T51", reason: "busy"))
        s3.deliver(stray)
        await runCurrent()
        m3.hangUp()
        await runCurrent()
        #expect(try ended(m3).reason == .hungUp)
        #expect(wiped(strayKeys))
    }

    @Test func anAnswerThatDoesNotVerifyEndsTheCall() async throws {
        let m = machine()
        try await placed(m)
        signalling.deliver(.answerRejected(callId: callId))
        await runCurrent()
        #expect(try ended(m).reason == .notEncrypted)
        #expect(signalling.sent.last == "end(\(callId), failed)")
        #expect(engines.last.calls.allSatisfy { $0 != "setKeys" && $0 != "acceptAnswer" })
    }

    @Test func anAnswerForNoCallLeavesNoKeyBehind() async throws {
        let m = machine()
        let (event, keys) = answerEvent()
        signalling.deliver(event)
        await runCurrent()
        #expect(m.state == .idle)
        #expect(wiped(keys))
    }

    @Test func aMediaStackWhoseLoggingIsOnIsNotUsed() async throws {
        let m = machine(nil, FakeEngines(make: { throw MediaLoggingError("debug output is enabled") }))
        m.call("conn-1")
        await runCurrent()
        #expect(try ended(m).reason == .notEncrypted)
        #expect(signalling.sent.isEmpty, "nothing left the phone")

        // The engine refuses the keys (the guard runs again before every key).
        let refusing = FakeEngines(make: {
            let e = FakeEngine()
            e.onKeys = { throw MediaLoggingError("a logger is injected") }
            return e
        })
        let other = FakeSignalling()
        let m2 = machine(other, refusing)
        m2.call("conn-1")
        await runCurrent()
        other.deliver(answerEvent().0)
        await runCurrent()
        #expect(try ended(m2).reason == .notEncrypted)
        #expect(other.sent.last == "end(\(callId), failed)")
    }

    @Test func lockingTheVaultEndsTheCall() async throws {
        let m = machine()
        try await placed(m)
        m.vaultLocking()
        await runCurrent()
        #expect(try ended(m).reason == .locked)
        #expect(signalling.sent.last == "end(\(callId), hangup)")
        // And a ringing one is declined.
        m.dismiss()
        signalling.deliver(offer())
        await runCurrent()
        m.vaultLocking()
        await runCurrent()
        #expect(try ended(m).reason == .locked)
        #expect(signalling.sent.last == "end(\(callId), decline)")
    }

    @Test func thePostQuantumDtlsTrialIsOffUnlessADebugBuildAsksForIt() async throws {
        #expect(!MediaConfig().dtlsPqcTrial)
        let m = machine()
        try await placed(m)
        #expect(engines.config == MediaConfig(dtlsPqcTrial: false))
        let asked = FakeEngines()
        let m2 = machine(FakeSignalling(), asked, config: MediaConfig(dtlsPqcTrial: true))
        m2.call("conn-1")
        await runCurrent()
        #expect(asked.config?.dtlsPqcTrial == true)
    }

    @Test func aConnectedCallIsCountedByItsPathWhenItEnds() async throws {
        let m = machine()
        for relayed in [true, false, nil] as [Bool?] {
            m.call("conn-1")
            await runCurrent()
            let engine = engines.last
            engine.relayed = relayed
            signalling.deliver(answerEvent().0)
            await runCurrent()
            engine.emit(.connection(.connected))
            await advance(2_500)
            m.hangUp()
            await runCurrent()
            m.dismiss()
            await runCurrent()
        }
        #expect(m.paths == CallPaths(direct: 1, relayed: 1, unknown: 1))
    }
}
