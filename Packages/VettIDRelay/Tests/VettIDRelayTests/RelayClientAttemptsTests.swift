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
}
