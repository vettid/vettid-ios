import Foundation
import Testing
@testable import VettIDRelay
import VettIDTesting

/// A call's own attempts (``RelayClient/collect(wait:max:attempts:)``).
extension RelayClientTests {
    /// One attempt for a caller that retries itself: one 503 is one request, and thrown; by default the client tries again
    /// up to its attempts.
    @Test func aCollectOfOneAttemptIsNotRetried() async throws {
        server.enqueue(.json(503, #"{"code":"internal","message":"x"}"#))
        await #expect(throws: RelayError.self) { _ = try await client().collect(wait: 0, attempts: 1) }
        #expect(server.requestCount == 1 && sleeps.all.isEmpty)
        for _ in 0..<RelayClient.defaultAttempts { server.enqueue(.json(503, #"{"code":"internal","message":"x"}"#)) }
        await #expect(throws: RelayError.self) { _ = try await client().collect(wait: 0) }
        #expect(server.requestCount == 1 + RelayClient.defaultAttempts)
    }

    /// The collector's collect (``RelayMailbox``) is one attempt: an answer lost after the relay handed it messages fails
    /// as such, and is not retried into an empty answer while they stay leased.
    @Test func theCollectorsCollectIsOneAttempt() async throws {
        server.enqueue(.json(503, #"{"code":"internal","message":"x"}"#))
        let mailbox = RelayMailbox(client: client(), transport: HTTPTransport(session: server.session, sleep: { _ in }))
        await #expect(throws: RelayError.self) { _ = try await mailbox.collect(wait: 0, max: 10) }
        #expect(server.requestCount == 1 && sleeps.all.isEmpty)
    }

    /// A collect's send time is taken right before each attempt goes out: after the wait for a network, and again for an
    /// attempt the transport sends again.
    @Test func aCollectsSendTimeIsEachAttempts() async throws {
        let checks = Recorder<Bool>()
        // No network for the first three looks, then one.
        let gate = NetworkGate { checks.add(true); return checks.all.count > 3 }
        server.enqueue(.failure(.cannotConnectToHost))
        server.enqueue(.json(200, #"{"messages":[]}"#))
        let transport = HTTPTransport(session: server.session, gate: gate, sleep: { _ in })
        let sentAfter = Recorder<Int>()
        _ = try await client(transport: transport).collect(wait: 0, attempts: 1, sent: { sentAfter.add(checks.all.count) })
        #expect(sentAfter.all.count == 2, "one per attempt: \(sentAfter.all)")
        #expect((sentAfter.all.first ?? 0) >= 4, "after the network came: \(sentAfter.all)")
    }

    /// Each attempt of a long poll goes on a session of its own (no connection an earlier request used); other calls on
    /// the transport's.
    @Test func aLongPollGoesOnASessionOfItsOwn() async throws {
        let made = Recorder<Bool>()
        let base = server.session
        let transport = HTTPTransport(session: base, sleep: { _ in }, makeSession: { c in
            made.add(true)
            return URLSession(configuration: c)
        })
        server.enqueue(.json(200, #"{"messages":[]}"#))
        _ = try await client(transport: transport).collect(wait: 0, attempts: 1)
        #expect(made.all.count == 1, "the long poll")
        server.enqueue(.empty(204))
        try await client(transport: transport).ack("01A")
        #expect(made.all.count == 1, "not the ack")
    }
}
