import Foundation
import Testing
import VettIDCrypto
@testable import VettIDVault

// The events kept for the ones that wait for them are vault content (IOS-PLAN §6.9).
extension VaultDeviceTests {
    /// The inbox is bounded, and emptied by ``VaultDevice/clearInbox()``: an event that arrived before is no longer found.
    @Test func theInboxIsBoundedAndClearedAtTheLock() async throws {
        let (d, v) = try await pairedDevice()
        for i in 0..<3 { try await d.handle(try v.seal("message.new", #"{"n":\#(i)}"#)) }
        #expect(d.inboxCount == 3)
        d.clearInbox()
        #expect(d.inboxCount == 0)
        // The bound: only the last ``VaultDevice/inboxMax`` events are kept.
        for i in 0..<(VaultDevice.inboxMax + 5) { try await d.handle(try v.seal("message.new", #"{"n":\#(i)}"#)) }
        #expect(d.inboxCount == VaultDevice.inboxMax)
        d.clearInbox()
        #expect(d.inboxCount == 0)
        // Events a running call waits for are kept through the clear (a hold between its request's answer and its wait).
        try await d.keepingEvents(["grant.value"]) {
            try await d.handle(try v.seal("grant.value", #"{"fetch_id":"f1"}"#))
            try await d.handle(try v.seal("message.new", "{}"))
            d.clearInbox()
            #expect(d.inboxCount == 1)
            _ = try await d.awaitEvent("grant.value", timeout: 1)
        }
        await #expect(throws: VaultStateError.self) { _ = try await d.awaitEvent("message.new", timeout: 0.2) }
        // Events after the clear are kept again.
        try await d.handle(try v.seal("message.new", #"{"n":9}"#))
        #expect(d.inboxCount == 1)
        _ = try await d.awaitEvent("message.new", timeout: 1)
        #expect(d.inboxCount == 0)
    }
}
