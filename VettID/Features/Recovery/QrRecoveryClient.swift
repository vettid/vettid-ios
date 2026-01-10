import Foundation

// MARK: - QR Recovery Client

/// Client for handling QR code-based credential recovery via NATS.
///
/// Flow:
/// 1. User scans QR code from Account Portal (after 24h delay)
/// 2. App connects to vault using temporary credentials from QR
/// 3. App sends recovery token to claim the credential
/// 4. Vault verifies token and returns new full credentials
actor QrRecoveryClient {

    // MARK: - Configuration

    private let recoveryTimeout: TimeInterval = 30

    // MARK: - State

    private var tempNatsClient: NatsClientWrapper?

    // MARK: - Public API

    /// Exchange recovery token for new credentials.
    ///
    /// - Parameters:
    ///   - recoveryQr: Parsed QR code content
    ///   - deviceId: Device identifier for the new credential
    ///   - appVersion: App version string
    /// - Returns: Result containing new credentials or error
    func exchangeRecoveryToken(
        recoveryQr: RecoveryQrCode,
        deviceId: String,
        appVersion: String = "1.0.0"
    ) async -> Result<RecoveryExchangeResult, QrRecoveryError> {
        #if DEBUG
        print("[QrRecovery] Starting QR recovery exchange to \(recoveryQr.natsEndpoint)")
        #endif

        // 1. Parse NATS credentials from QR
        guard let credentials = recoveryQr.parseNatsCredentials() else {
            return .failure(.invalidCredentials)
        }

        // 2. Connect with temporary credentials
        let client = NatsClientWrapper(
            endpoint: recoveryQr.natsEndpoint,
            jwt: credentials.jwt,
            seed: credentials.seed
        )
        tempNatsClient = client

        do {
            try await client.connect()
            #if DEBUG
            print("[QrRecovery] Connected with recovery credentials")
            #endif
        } catch {
            cleanup()
            return .failure(.connectionFailed(error.localizedDescription))
        }

        // 3. Build recovery claim request
        let requestId = UUID().uuidString
        let request: [String: Any] = [
            "token": recoveryQr.token,
            "nonce": recoveryQr.nonce,
            "device_id": deviceId,
            "device_type": "ios",
            "app_version": appVersion
        ]

        let message: [String: Any] = [
            "id": requestId,
            "type": "recovery.claim",
            "payload": request,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        guard let messageData = try? JSONSerialization.data(withJSONObject: message) else {
            cleanup()
            return .failure(.parseError("Failed to serialize request"))
        }

        #if DEBUG
        print("[QrRecovery] Sending recovery claim request: \(requestId)")
        #endif

        // 4. Subscribe to response topic and wait for response
        do {
            let result = try await withTimeout(seconds: recoveryTimeout) { [weak self] in
                guard let self = self else {
                    throw QrRecoveryError.exchangeFailed("Client deallocated")
                }
                return try await self.sendAndWaitForResponse(
                    client: client,
                    requestId: requestId,
                    messageData: messageData,
                    recoveryQr: recoveryQr
                )
            }

            cleanup()
            return result

        } catch is TimeoutError {
            #if DEBUG
            print("[QrRecovery] Recovery exchange timed out")
            #endif
            cleanup()
            return .failure(.exchangeTimeout)

        } catch let error as QrRecoveryError {
            cleanup()
            return .failure(error)

        } catch {
            #if DEBUG
            print("[QrRecovery] Recovery exchange failed: \(error)")
            #endif
            cleanup()
            return .failure(.exchangeFailed(error.localizedDescription))
        }
    }

    // MARK: - Private Methods

    private func sendAndWaitForResponse(
        client: NatsClientWrapper,
        requestId: String,
        messageData: Data,
        recoveryQr: RecoveryQrCode
    ) async throws -> Result<RecoveryExchangeResult, QrRecoveryError> {

        // Subscribe to response topic (returns AsyncStream)
        let responseStream = try await client.subscribe(to: recoveryQr.responseTopic)

        #if DEBUG
        print("[QrRecovery] Subscribed to \(recoveryQr.responseTopic)")
        #endif

        // Publish recovery claim request
        try await client.publish(messageData, to: recoveryQr.recoveryTopic)

        #if DEBUG
        print("[QrRecovery] Published recovery claim to \(recoveryQr.recoveryTopic)")
        #endif

        // Wait for response in the stream
        for await message in responseStream {
            #if DEBUG
            print("[QrRecovery] Received response on \(recoveryQr.responseTopic)")
            #endif

            let responseData = message.data

            do {
                guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                    continue
                }

                // Check if this is our response
                let eventId = json["event_id"] as? String ?? json["id"] as? String

                if eventId == requestId || eventId == nil {
                    // Parse result
                    let resultJson = json["result"] as? [String: Any] ?? json
                    let exchangeResult = parseExchangeResult(resultJson)
                    return .success(exchangeResult)
                }
            } catch {
                #if DEBUG
                print("[QrRecovery] Failed to parse recovery response: \(error)")
                #endif
                return .failure(.parseError(error.localizedDescription))
            }
        }

        // Stream ended without response
        return .failure(.exchangeFailed("No response received"))
    }

    private func parseExchangeResult(_ json: [String: Any]) -> RecoveryExchangeResult {
        return RecoveryExchangeResult(
            success: json["success"] as? Bool ?? false,
            message: json["message"] as? String ?? "",
            credentials: json["credentials"] as? String,
            natsEndpoint: json["nats_endpoint"] as? String,
            ownerSpace: json["owner_space"] as? String,
            messageSpace: json["message_space"] as? String,
            credentialId: json["credential_id"] as? String,
            userGuid: json["user_guid"] as? String,
            credentialVersion: json["credential_version"] as? Int,
            sealedCredential: json["sealed_credential"] as? String
        )
    }

    private func cleanup() {
        Task {
            do {
                try await tempNatsClient?.disconnect()
            } catch {
                #if DEBUG
                print("[QrRecovery] Error during cleanup: \(error)")
                #endif
            }
            tempNatsClient = nil
        }
    }
}

// MARK: - Timeout Helper

private struct TimeoutError: Error {}

private func withTimeout<T>(
    seconds: TimeInterval,
    operation: @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
