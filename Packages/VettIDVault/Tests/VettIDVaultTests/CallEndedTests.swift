import Foundation
import Testing
import VettIDCrypto
@testable import VettIDVault

/// `call.end` as received (VAULT-MESSAGING §10.10): `superseded_by` is the call that won a glare over this device's own.
@Suite struct CallEndedTests {
    let callId = "01JB2Z6V9K3M4N5P6Q7R8S9T50"
    let winner = "01JB2Z6V9K3M4N5P6Q7R8S9T4Z"

    private func ended(_ body: String) async -> CallEnded? {
        let m = VaultMessage(inner: Inner(id: Ulid.new(), type: "call.end", ts: Date(), body: Array(body.utf8)))
        let events = AsyncStream<VaultMessage> { c in
            c.yield(m)
            c.finish()
        }
        for await e in callEventsIn(events) {
            if case .ended(let end) = e { return end }
        }
        return nil
    }

    @Test func aGlareEndNamesTheWinner() async {
        let e = await ended(#"{"call_id":"\#(callId)","reason":"busy","superseded_by":"\#(winner)"}"#)
        #expect(e == CallEnded(callId: callId, reason: "busy", supersededBy: winner))
    }

    @Test func withoutSupersededByThereIsNone() async {
        let e = await ended(#"{"call_id":"\#(callId)","reason":"hangup"}"#)
        #expect(e == CallEnded(callId: callId, reason: "hangup"))
        #expect(e?.supersededBy == nil)
    }

    @Test func aSupersededByThatIsNotAnotherCallIdIsLeftOut() async {
        for bad in [#""superseded_by":"not-an-id""#, #""superseded_by":"\#(callId)""#, #""superseded_by":7"#, #""superseded_by":null"#] {
            let e = await ended(#"{"call_id":"\#(callId)","reason":"busy",\#(bad)}"#)
            #expect(e == CallEnded(callId: callId, reason: "busy"), "\(bad)")
        }
    }
}
