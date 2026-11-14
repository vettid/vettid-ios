import Foundation
import Testing
import VettIDCrypto
import VettIDVault
@testable import VettIDCalls

/// A call that ends or is replaced while CallKit is still taking its report (see ``CallKitCoordinatorTests``).
extension CallKitCoordinatorTests {
    @Test func aCallThatEndsWhileItsReportIsOnItsWayIsEndedInCallKitOnceReported() async throws {
        let gate = Gate()
        kit.incomingGate = gate
        let c = coordinator(machine())
        c.apply(state(.incoming, .incoming))
        await settle()
        let uuid = try #require(kit.uuid)
        c.apply(ended(.missed, .incoming))
        await settle()
        #expect(kit.events == [.incoming(uuid, CallKitUpdate(handle: c.trackedHandle ?? "", name: CallKitName.generic))])
        gate.open()
        await settle()
        #expect(kit.events.last == .ended(uuid, CallEnd.missed.callKitReason), "no ringing call is left in CallKit")
    }

    @Test func aCallReplacedWhileItsReportIsOnItsWayIsEndedInCallKitOnceReported() async throws {
        let gate = Gate()
        kit.incomingGate = gate
        let c = coordinator(machine())
        c.apply(state(.incoming, .incoming), seq: 0)
        await settle()
        let first = try #require(kit.uuid)
        kit.incomingGate = nil
        c.apply(state(.incoming, .incoming), seq: 1)
        await settle()
        gate.open()
        await settle()
        #expect(kit.events.contains(.ended(first, .failed)))
    }

    @Test func aCallEndedThenReplacedWhileItsReportIsOnItsWayIsEndedWithItsOwnReason() async throws {
        let gate = Gate()
        kit.incomingGate = gate
        let c = coordinator(machine())
        c.apply(state(.incoming, .incoming), seq: 0)
        await settle()
        let first = try #require(kit.uuid)
        c.apply(ended(.missed, .incoming), seq: 0)
        kit.incomingGate = nil
        c.apply(state(.incoming, .incoming), seq: 1)
        await settle()
        gate.open()
        await settle()
        #expect(kit.events.contains(.ended(first, CallEnd.missed.callKitReason)))
    }

    @Test func aCallStillGoingWhenItsReportCompletesIsLeftAlone() async throws {
        let gate = Gate()
        kit.incomingGate = gate
        let c = coordinator(machine())
        c.apply(state(.incoming, .incoming))
        await settle()
        gate.open()
        await settle()
        #expect(kit.events.count == 1)
    }
}
