import Foundation
import Testing
@testable import VettIDRelay
import VettIDTesting

extension RelayClientTests {
    /// A deposit not to be sent again once it may have reached the relay (a rekey's `hs.resp`, VAULT-MESSAGING §6.3: one per
    /// `hs.init`) stops at a 5xx, a lost connection and `replay_detected`, in one request each; a refusal that applied
    /// nothing (`rate_limited`, `timestamp_stale`) or a failure before the request could reach the relay is still retried.
    @Test func aDepositNotToBeResentStopsOnceItMayHaveArrived() async throws {
        func deposit() async throws -> String {
            try await client().deposit(mailboxID: "mbx", token: "tok", payload: [1], resendAfterSent: false)
        }
        server.enqueue(.json(503, #"{"code":"internal","message":"x"}"#))
        await #expect(throws: RelayError(status: 503, code: RelayError.internalError, message: "x")) { _ = try await deposit() }
        #expect(server.requestCount == 1)
        server.enqueue(.json(401, #"{"code":"replay_detected","message":"x"}"#))
        await #expect(throws: RelayError(status: 401, code: RelayError.replayDetected, message: "x")) { _ = try await deposit() }
        #expect(server.requestCount == 2)
        server.enqueue(.failure(.networkConnectionLost))
        await #expect(throws: URLError.self) { _ = try await deposit() }
        #expect(server.requestCount == 3)
        server.enqueue(
            .json(429, #"{"code":"rate_limited","message":""}"#), .json(401, #"{"code":"timestamp_stale","message":""}"#),
            .json(201, #"{"msg_id":"01N"}"#)
        )
        #expect(try await deposit() == "01N")
        #expect(server.requestCount == 6)
        // A failure before the request could reach the relay is retried by the client too, past the transport's own retries.
        for _ in 0...HTTPTransport.defaultRetries { server.enqueue(.failure(.cannotConnectToHost)) }
        server.enqueue(.json(201, #"{"msg_id":"01P"}"#))
        #expect(try await deposit() == "01P")
        #expect(server.requestCount == 6 + HTTPTransport.defaultRetries + 2)
    }
}
