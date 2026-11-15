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

    /// An end reason is kept only while the call's report is on its way: none is left behind by calls whose report was
    /// answered before or after they ended, or that were replaced.
    @Test func noEndReasonOutlivesItsReport() async throws {
        let c = coordinator(machine())
        c.apply(state(.incoming, .incoming), seq: 0)
        await settle()
        c.apply(ended(.missed, .incoming), seq: 0)
        await settle()
        #expect(c.endReasons.isEmpty, "reported before it ended")
        let gate = Gate()
        kit.incomingGate = gate
        c.apply(state(.incoming, .incoming), seq: 1)
        await settle()
        c.apply(ended(.missed, .incoming), seq: 1)
        await settle()
        #expect(c.endReasons.count == 1, "kept while the report is on its way")
        kit.incomingGate = nil
        c.apply(state(.incoming, .incoming), seq: 2)
        await settle()
        gate.open()
        await settle()
        #expect(c.endReasons.isEmpty, "dropped when the report is answered")
    }
}
