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
            // Another fetch's answer that arrived after the clear is the inbox's as any event.
            try await d.handle(try v.seal("grant.value", #"{"fetch_id":"f2"}"#))
            _ = try await d.awaitEvent("grant.value", timeout: 1) { VaultJSON.string($0.object, "fetch_id") == "f1" }
        }
        #expect(d.inboxCount == 1, "f2 came after the clear: it stays")
        _ = try await d.awaitEvent("grant.value", timeout: 1)
        #expect(d.inboxCount == 0)
        await #expect(throws: VaultStateError.self) { _ = try await d.awaitEvent("message.new", timeout: 0.2) }
        // Events after the clear are kept again.
        try await d.handle(try v.seal("message.new", #"{"n":9}"#))
        #expect(d.inboxCount == 1)
        _ = try await d.awaitEvent("message.new", timeout: 1)
        #expect(d.inboxCount == 0)
    }

    /// Two calls keep a type at once: the events a clear spared go when the last call ends, not before, and an event that
    /// arrived after the clear is not among them.
    @Test func overlappingCallsDropExactlyTheEventsTheClearSpared() async throws {
        let (d, v) = try await pairedDevice()
        let aIn = AsyncStream<Void>.makeStream(), aOut = AsyncStream<Void>.makeStream()
        let bIn = AsyncStream<Void>.makeStream(), bOut = AsyncStream<Void>.makeStream()
        let a = Task {
            try await d.keepingEvents(["grant.value"]) {
                aIn.continuation.yield()
                for await _ in aOut.stream { return }
            }
        }
        let b = Task {
            try await d.keepingEvents(["grant.value"]) {
                bIn.continuation.yield()
                for await _ in bOut.stream { return }
            }
        }
        for await _ in aIn.stream { break }
        for await _ in bIn.stream { break }
        try await d.handle(try v.seal("grant.value", #"{"fetch_id":"before"}"#))
        d.clearInbox()
        try await d.handle(try v.seal("grant.value", #"{"fetch_id":"after"}"#))
        #expect(d.inboxCount == 2)
        aOut.continuation.yield()
        try await a.value
        #expect(d.inboxCount == 2, "one call still keeps the type")
        bOut.continuation.yield()
        try await b.value
        #expect(d.inboxCount == 1, "the spared event went with the last call, the one after the clear stayed")
        _ = try await d.awaitEvent("grant.value", timeout: 1) { VaultJSON.string($0.object, "fetch_id") == "after" }
    }
}
