import Foundation
import Testing
import VettIDCrypto
import VettIDData
@testable import VettIDCalls
@testable import VettIDVault

/// The microphone gate, the end before a lock and the 12-hour cap (see ``CallsControllerTests``).
extension CallsControllerTests {
    // MARK: the microphone

    @Test func withTheMicrophoneAllowedTheCallGoesOut() async throws {
        vault.gatewayFake.startResult = { _, _ in try self.outgoing() }
        let mic = FakeMicrophone(.granted)
        let c = controller(mic)
        await unlock()
        c.call("conn-1")
        await settle()
        #expect(vault.gatewayFake.asked == ["start(conn-1)"])
        #expect(c.microphonePrompt == nil && mic.requests == 0)
    }

    @Test func aMicrophoneNotAskedForYetShowsOurOwnScreenBeforeTheSystemsPrompt() async throws {
        vault.gatewayFake.startResult = { _, _ in try self.outgoing() }
        let mic = FakeMicrophone(.undetermined)
        let c = controller(mic)
        await unlock()
        c.call("conn-1")
        await settle()
        #expect(c.microphonePrompt == .explain(.call(connectionId: "conn-1")))
        #expect(mic.requests == 0 && vault.gatewayFake.asked.isEmpty, "the system is not asked, no call is placed")
        let screen = try #require(c.microphoneScreen)
        #expect(screen.title == "Allow the microphone")
        #expect(screen.body == "VettID needs the microphone so \(AccountNames.isolate("Sam")) can hear you. It is used only during calls.")
        #expect(screen.primaryButton == "Allow" && screen.secondaryButton == "Not now")

        c.allowMicrophone()
        await settle()
        #expect(mic.requests == 1)
        #expect(c.microphonePrompt == nil)
        #expect(vault.gatewayFake.asked == ["start(conn-1)"], "what was held back goes on")
    }

    @Test func notNowPlacesNoCallAndAsksNothing() async {
        let mic = FakeMicrophone(.undetermined)
        let c = controller(mic)
        await unlock()
        c.call("conn-1")
        await settle()
        c.closeMicrophonePrompt()
        await settle()
        #expect(c.microphonePrompt == nil && c.microphoneScreen == nil)
        #expect(mic.requests == 0 && vault.gatewayFake.asked.isEmpty)
    }

    @Test func refusingAtTheSystemsPromptPlacesNoCallAndTheNextTryIsBlocked() async throws {
        let mic = FakeMicrophone(.undetermined)
        mic.allows = false
        let c = controller(mic)
        await unlock()
        c.call("conn-1")
        await settle()
        c.allowMicrophone()
        await settle()
        #expect(mic.requests == 1 && c.microphonePrompt == nil && vault.gatewayFake.asked.isEmpty)
        c.call("conn-1")
        await settle()
        #expect(c.microphonePrompt == .blocked(.call(connectionId: "conn-1")))
        #expect(mic.requests == 1, "the system does not ask again")
    }

    @Test func aDeniedMicrophoneShowsTheBlockedScreen() async throws {
        let mic = FakeMicrophone(.denied)
        let c = controller(mic)
        await unlock()
        c.call("conn-1")
        await settle()
        #expect(c.microphonePrompt == .blocked(.call(connectionId: "conn-1")))
        let screen = try #require(c.microphoneScreen)
        #expect(screen.title == "The microphone is turned off for VettID")
        #expect(screen.body == "iOS doesn't ask again. To make and answer calls, allow the microphone for VettID in Settings.")
        #expect(screen.primaryButton == "Open Settings" && screen.secondaryButton == "Close")
        #expect(mic.requests == 0 && vault.gatewayFake.asked.isEmpty)
        // "Allow" does nothing on this screen: only Settings can change it.
        c.allowMicrophone()
        await settle()
        #expect(c.microphonePrompt == .blocked(.call(connectionId: "conn-1")) && mic.requests == 0)
        c.closeMicrophonePrompt()
        #expect(c.microphonePrompt == nil)
    }

    @Test func aScreenWithoutAFirstNameSaysYourConnection() async throws {
        vault.firstNames = [:]
        let c = controller(FakeMicrophone(.undetermined))
        await unlock()
        c.call("conn-1")
        await settle()
        let screen = try #require(c.microphoneScreen)
        #expect(screen.body == "VettID needs the microphone so Your connection can hear you. It is used only during calls.")
    }

    @Test func aNameWithBidiControlsIsCleanedAndIsolated() async throws {
        vault.firstNames = ["conn-1": "Sam\u{202E}"]
        let c = controller(FakeMicrophone(.undetermined))
        await unlock()
        c.call("conn-1")
        await settle()
        let body = try #require(c.microphoneScreen).body
        #expect(!body.contains("\u{202E}") && body.contains(AccountNames.isolate("Sam")))
    }

    @Test func theAnswerIsHeldBackForTheMicrophoneToo() async throws {
        vault.gatewayFake.incomingResult = { _ in try self.incoming() }
        var answered = 0
        let mic = FakeMicrophone(.undetermined)
        let c = controller(mic, answering: { answered += 1 })
        await unlock()
        c.answer()
        #expect(c.microphonePrompt == nil, "no call rings: nothing to answer")
        vault.gatewayFake.send(offerEvent())
        await settle()
        guard case .live(let l) = c.state, l.phase == .incoming else { throw WrongState(state: c.state) }
        let seq = try #require(c.machine.session?.seq)
        c.answer()
        #expect(c.microphonePrompt == .explain(.answer(seq: seq)))
        #expect(try #require(c.microphoneScreen).body.contains("Sam"), "the caller's first name")
        #expect(answered == 0)
        c.allowMicrophone()
        await settle()
        #expect(answered == 1)

        // Denied: blocked, and the call keeps ringing.
        mic.status = .denied
        c.answer()
        #expect(c.microphonePrompt == .blocked(.answer(seq: seq)))
        #expect(answered == 1)
        c.closeMicrophonePrompt()
        guard case .live(let still) = c.state, still.phase == .incoming else { throw WrongState(state: c.state) }
        // Allowed: straight through.
        mic.status = .granted
        c.answer()
        #expect(answered == 2 && c.microphonePrompt == nil)
    }

    @Test func theAnswerScreenGoesWhenTheCallerGivesUp() async throws {
        vault.gatewayFake.incomingResult = { _ in try self.incoming() }
        let c = controller(FakeMicrophone(.undetermined))
        await unlock()
        vault.gatewayFake.send(offerEvent())
        await settle()
        c.answer()
        #expect(c.microphonePrompt != nil)
        vault.gatewayFake.send(.ended(CallEnded(callId: callId, reason: "hangup")))
        await settle()
        #expect(c.microphonePrompt == nil && c.microphoneScreen == nil, "nothing is left to answer")
    }

    @Test func allowAfterTheCallerGaveUpAnswersNoOtherCall() async throws {
        vault.gatewayFake.incomingResult = { _ in try self.incoming() }
        var answered = 0
        let mic = FakeMicrophone(.undetermined)
        mic.requestGate = Gate()
        let c = controller(mic, answering: { answered += 1 })
        await unlock()
        vault.gatewayFake.send(offerEvent())
        await settle()
        c.answer()
        c.allowMicrophone()
        await settle()
        #expect(mic.requests == 1, "the member is at the system's prompt")
        // The caller gives up and the connection calls again while the prompt is up.
        vault.gatewayFake.send(.ended(CallEnded(callId: callId, reason: "hangup")))
        await settle()
        c.dismiss()
        await settle()
        vault.gatewayFake.send(offerEvent())
        await settle()
        guard case .live(let l) = c.state, l.phase == .incoming else { throw WrongState(state: c.state) }
        mic.requestGate?.open()
        await settle()
        #expect(answered == 0, "Allow answers the call it was asked for, not this one")
        guard case .live = c.state else { throw WrongState(state: c.state) }
    }

    @Test func aLockTakesTheScreenAway() async {
        let c = controller(FakeMicrophone(.denied))
        await unlock()
        c.call("conn-1")
        #expect(c.microphonePrompt != nil)
        vault.setUnlocked(false)
        await settle()
        #expect(c.microphonePrompt == nil)
    }

    // MARK: the end before a lock

    @Test func aLiveCallIsHungUpAndItsEndIsWaitedFor() async throws {
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        try await activeCall(c)
        let gate = Gate()
        vault.gatewayFake.endGate = gate
        var done = false
        let waiter = Task {
            await c.endCallBeforeLock()
            done = true
        }
        await clock.advance(by: 1500)
        #expect(c.state != .idle)
        guard case .ended(let e) = c.state else { throw WrongState(state: c.state) }
        #expect(e.reason == .locked)
        #expect(vault.gatewayFake.asked.contains("end(\(callId), hangup)"), "the hang-up was handed to the vault")
        #expect(!done, "the end is not with the relay yet: the lock waits")
        gate.open()
        await settle()
        #expect(done)
        #expect(vault.gatewayFake.ended == ["\(callId) hangup"])
        await waiter.value
    }

    @Test func theLockIsNotHeldLongerThanTwoSecondsWhenTheVaultDoesNotAnswer() async throws {
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        try await activeCall(c)
        vault.gatewayFake.endGate = Gate()
        var done = false
        let waiter = Task {
            await c.endCallBeforeLock()
            done = true
        }
        await clock.advance(by: 1950)
        #expect(!done)
        await clock.advance(by: 100)
        #expect(done, "returns at two seconds, the end still on its way")
        await waiter.value
    }

    @Test func nothingToEndMeansNoWait() async {
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        await c.endCallBeforeLock()
        #expect(clock.ms == 0 && vault.gatewayFake.asked.isEmpty)
    }

    @Test func aHangUpStillBeingSentIsWaitedForAlthoughTheCallIsOver() async throws {
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        try await activeCall(c)
        let gate = Gate()
        vault.gatewayFake.endGate = gate
        c.hangUp()
        await settle()
        guard case .ended = c.state else { throw WrongState(state: c.state) }
        var done = false
        let waiter = Task {
            await c.endCallBeforeLock()
            done = true
        }
        await clock.advance(by: 500)
        #expect(!done)
        gate.open()
        await settle()
        #expect(done)
        await waiter.value
    }

    @Test func theLockItselfEndsALiveCallToo() async throws {
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        try await activeCall(c)
        vault.setUnlocked(false)
        await settle()
        #expect(c.state == .idle, "nothing of the call is kept for the next unlock")
        #expect(vault.gatewayFake.asked.contains("end(\(callId), hangup)"))
    }

    // MARK: the 12-hour cap

    @Test func aCallEndsAfterTwelveHours() async throws {
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        try await activeCall(c)
        await clock.advance(by: 12 * 3600 * 1000 - 1)
        guard case .live = c.state else { throw WrongState(state: c.state) }
        await clock.advance(by: 1)
        await settle()
        guard case .ended(let e) = c.state else { throw WrongState(state: c.state) }
        #expect(e.reason == .hungUp)
        #expect(vault.gatewayFake.ended == ["\(callId) hangup"])
    }

    @Test func aCallThatEndedEarlierIsNotCutAtTheCapOfItsPredecessor() async throws {
        let c = controller(FakeMicrophone(.granted))
        await unlock()
        try await activeCall(c)
        await clock.advance(by: 60_000)
        c.hangUp()
        await settle()
        c.dismiss()
        await settle()
        await clock.advance(by: 12 * 3600 * 1000)
        await settle()
        #expect(c.state == .idle)
        #expect(vault.gatewayFake.ended == ["\(callId) hangup"], "one hang-up only: the member's")
    }

    // MARK: answering in CallKit's own screen

    struct RingingCall {
        let controller: CallsController
        let coordinator: CallKitCoordinator
        let kit: FakeKit
    }

    final class Holder {
        var coordinator: CallKitCoordinator?
    }

    /// A controller wired to a coordinator as the app will: CallKit's answer asks the controller's gate, and the controller answers
    /// through the coordinator. A ringing call is up.
    func ringing(_ mic: FakeMicrophone) async throws -> RingingCall {
        vault.gatewayFake.incomingResult = { _ in try self.incoming() }
        vault.gatewayFake.answerKeys = CallKeys(suite: .aes128Gcm, send: filled(32, 5), receive: filled(32, 6))
        let holder = Holder()
        let c = controller(mic, answering: { holder.coordinator?.answer() })
        let kit = FakeKit()
        let coordinator = CallKitCoordinator(
            machine: c.machine, provider: kit, control: kit, audio: FakeAudio(), tones: FakeTones(), clock: clock,
            isForeground: { true }, mayAnswer: { c.answerFromCallKit(seq: $0) }
        )
        kit.delegate = coordinator
        coordinator.start()
        holder.coordinator = coordinator
        await unlock()
        vault.gatewayFake.send(offerEvent())
        await settle()
        guard case .live(let l) = c.state, l.phase == .incoming else { throw WrongState(state: c.state) }
        return RingingCall(controller: c, coordinator: coordinator, kit: kit)
    }

    func answered() -> Bool { vault.gatewayFake.asked.contains { $0.hasPrefix("answer(") } }

    @Test func acceptingInCallKitWithTheMicrophoneAllowedAnswers() async throws {
        let r = try await ringing(FakeMicrophone(.granted))
        let (coordinator, kit) = (r.coordinator, r.kit)
        #expect(coordinator.performAnswer(uuid: try #require(kit.uuid)))
        await settle()
        #expect(answered())
    }

    @Test func acceptingInCallKitBeforeTheMicrophoneIsAskedShowsOurScreenAndDoesNotAnswer() async throws {
        let r = try await ringing(FakeMicrophone(.undetermined))
        let (c, coordinator, kit) = (r.controller, r.coordinator, r.kit)
        #expect(!coordinator.performAnswer(uuid: try #require(kit.uuid)), "the action is failed: the call keeps ringing")
        await settle()
        let seq = try #require(c.machine.session?.seq)
        #expect(c.microphonePrompt == .explain(.answer(seq: seq)))
        #expect(!answered())
        guard case .live(let l) = c.state, l.phase == .incoming else { throw WrongState(state: c.state) }
    }

    @Test func acceptingInCallKitWithTheMicrophoneDeniedShowsTheBlockedScreen() async throws {
        let r = try await ringing(FakeMicrophone(.denied))
        let (c, coordinator, kit) = (r.controller, r.coordinator, r.kit)
        #expect(!coordinator.performAnswer(uuid: try #require(kit.uuid)))
        let seq = try #require(c.machine.session?.seq)
        #expect(c.microphonePrompt == .blocked(.answer(seq: seq)))
        #expect(!answered())
    }

    @Test func allowAfterCallKitsAcceptAnswersThatCall() async throws {
        let r = try await ringing(FakeMicrophone(.undetermined))
        let (c, coordinator, kit) = (r.controller, r.coordinator, r.kit)
        _ = coordinator.performAnswer(uuid: try #require(kit.uuid))
        c.allowMicrophone()
        await settle()
        #expect(answered(), "answered through CallKit once the microphone is allowed")
        #expect(c.microphonePrompt == nil)
    }
}
