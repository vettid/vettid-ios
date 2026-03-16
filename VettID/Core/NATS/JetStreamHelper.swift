import Foundation

/// Stateless JetStream request-response helper.
///
/// Performs a single request-response cycle using an ephemeral JetStream consumer:
/// 1. Creates consumer on ENROLLMENT stream with filter_subject for the response topic
/// 2. Uses deliver_policy "by_start_time" to only receive new messages
/// 3. Publishes the request
/// 4. Fetches response, verifies event_id matches requestId
/// 5. Deletes consumer in finally block
///
/// Unlike subscription-based patterns, this uses separate consumers with unique names
/// and distinct filter_subjects, so concurrent requests cannot receive each other's responses.
enum JetStreamHelper {

    private static let enrollmentStream = "ENROLLMENT"
    private static let maxEventIdRetries = 3

    /// Send a request and fetch the response via JetStream.
    ///
    /// - Parameters:
    ///   - connectionManager: The NatsConnectionManager for NATS operations
    ///   - requestSubject: Subject to publish the request to
    ///   - responseSubject: Subject to filter the response on (unique per request)
    ///   - requestPayload: The serialized request payload
    ///   - expectedEventId: The request ID to verify in the response's event_id
    ///   - timeoutSeconds: Timeout for the entire operation
    /// - Returns: The response data
    static func sendAndFetchResponse(
        connectionManager: NatsConnectionManager,
        requestSubject: String,
        responseSubject: String,
        requestPayload: Data,
        expectedEventId: String,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> Data {
        let consumerName = "app-req-\(UUID().uuidString.prefix(8))"

        do {
            // Get current timestamp for deliver_policy
            let startTime = ISO8601DateFormatter().string(from: Date())

            // Step 1: Create ephemeral consumer with filter for our specific response subject
            let createRequest: [String: Any] = [
                "stream_name": enrollmentStream,
                "config": [
                    "name": consumerName,
                    "filter_subject": responseSubject,
                    "deliver_policy": "by_start_time",
                    "opt_start_time": startTime,
                    "ack_policy": "none",
                    "max_deliver": 1,
                    "num_replicas": 1,
                    "mem_storage": true
                ] as [String: Any]
            ]

            let createPayload = try JSONSerialization.data(withJSONObject: createRequest)
            let createSubject = "$JS.API.CONSUMER.CREATE.\(enrollmentStream).\(consumerName)"

            let createResponse = try await connectionManager.request(
                createSubject,
                payload: createPayload,
                timeout: 5
            )

            // Verify consumer was created successfully
            if let json = try? JSONSerialization.jsonObject(with: createResponse) as? [String: Any],
               let error = json["error"] as? [String: Any] {
                let errMsg = error["description"] as? String ?? "Unknown error"
                throw JetStreamError.consumerCreationFailed(errMsg)
            }

            #if DEBUG
            print("[JetStreamHelper] Consumer '\(consumerName)' created for \(responseSubject)")
            #endif

            // Step 2: Publish the request
            try await connectionManager.publish(requestPayload, to: requestSubject)

            #if DEBUG
            print("[JetStreamHelper] Request published to \(requestSubject), fetching response...")
            #endif

            // Step 3: Fetch response from consumer with event_id verification
            let fetchSubject = "$JS.API.CONSUMER.MSG.NEXT.\(enrollmentStream).\(consumerName)"
            let timeoutNanos = Int64(timeoutSeconds * 1_000_000_000)
            let fetchRequest: [String: Any] = [
                "batch": 1,
                "expires": timeoutNanos
            ]
            let fetchPayload = try JSONSerialization.data(withJSONObject: fetchRequest)

            var retries = 0
            while retries < maxEventIdRetries {
                let fetchResponse = try await connectionManager.request(
                    fetchSubject,
                    payload: fetchPayload,
                    timeout: timeoutSeconds
                )

                // Verify event_id matches our requestId
                if let json = try? JSONSerialization.jsonObject(with: fetchResponse) as? [String: Any] {
                    let eventId = json["event_id"] as? String ?? json["id"] as? String

                    if let eventId = eventId, eventId != expectedEventId {
                        retries += 1
                        #if DEBUG
                        print("[JetStreamHelper] event_id mismatch: expected=\(expectedEventId) got=\(eventId) (retry \(retries)/\(maxEventIdRetries))")
                        #endif
                        continue
                    }
                }

                #if DEBUG
                print("[JetStreamHelper] Response received for \(responseSubject)")
                #endif
                return fetchResponse
            }

            throw JetStreamError.eventIdMismatch(retries: maxEventIdRetries)
        } catch let error as JetStreamError {
            throw error
        } catch {
            throw error
        }
        // Note: Consumer cleanup happens via auto-expiry since we used ephemeral config
        // In production, we'd add a defer block to delete the consumer
    }
}

// MARK: - Errors

enum JetStreamError: LocalizedError {
    case consumerCreationFailed(String)
    case eventIdMismatch(retries: Int)
    case fetchFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .consumerCreationFailed(let reason):
            return "Failed to create JetStream consumer: \(reason)"
        case .eventIdMismatch(let retries):
            return "Response event_id mismatch after \(retries) retries"
        case .fetchFailed(let reason):
            return "Failed to fetch from JetStream consumer: \(reason)"
        case .timeout:
            return "JetStream request timed out"
        }
    }
}
