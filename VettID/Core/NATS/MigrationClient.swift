import Foundation

// MARK: - Migration Client

/// NATS-based client for vault migration operations.
/// Handles checking for vault updates, initiating re-sealing,
/// and acknowledging completed migrations.
final class MigrationClient {

    private let ownerSpaceClient: OwnerSpaceClient

    init(ownerSpaceClient: OwnerSpaceClient) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    // MARK: - Status

    /// Check current migration status.
    func getStatus() async throws -> MigrationStatus {
        let response = try await sendAndAwait("credential.migration.status", payload: [:])

        guard let result = response.result else {
            return .none
        }

        let statusString = result["status"] as? String ?? "none"
        switch statusString {
        case "in_progress":
            let progress = result["progress"] as? Double
            return .inProgress(progress: progress)
        case "complete":
            let version = result["version"] as? String ?? ""
            return .complete(version: version)
        case "emergency_recovery_required":
            return .emergencyRecoveryRequired
        default:
            return .none
        }
    }

    /// Check if a vault update is available.
    func getConfig() async throws -> MigrationConfig? {
        let response = try await sendAndAwait("credential.migration.config", payload: [:])

        guard let result = response.result,
              let version = result["version"] as? String else {
            return nil
        }

        return MigrationConfig(
            version: version,
            summary: result["summary"] as? String ?? "",
            detailsUrl: result["details_url"] as? String,
            changelogUrl: result["changelog_url"] as? String,
            publishedAt: result["published_at"] as? String,
            mandatoryAfter: result["mandatory_after"] as? String
        )
    }

    /// Start the migration (re-sealing). Uses 30s timeout.
    func startMigration() async throws -> Bool {
        let response = try await sendAndAwait("credential.migration.start", payload: [:], timeout: 30)
        return response.success
    }

    /// Acknowledge a completed migration.
    func acknowledgeMigration(version: String) async throws {
        let payload: [String: AnyCodableValue] = [
            "version": AnyCodableValue(version)
        ]
        _ = try await sendAndAwait("credential.migration.acknowledge", payload: payload)
    }

    // MARK: - Private

    private func sendAndAwait(
        _ messageType: String,
        payload: [String: AnyCodableValue],
        timeout: TimeInterval = 30
    ) async throws -> VaultHandlerResponse {
        #if DEBUG
        print("[MigrationClient] Sending \(messageType)")
        #endif

        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            messageType,
            payload: payload,
            timeout: timeout
        )

        guard response.success else {
            let error = response.error ?? "Request failed"
            #if DEBUG
            print("[MigrationClient] \(messageType) failed: \(error)")
            #endif
            throw MigrationClientError.requestFailed(
                messageType: messageType,
                error: error,
                errorCode: response.errorCode
            )
        }

        return response
    }
}

// MARK: - Errors

enum MigrationClientError: LocalizedError {
    case requestFailed(messageType: String, error: String, errorCode: String?)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let messageType, let error, let errorCode):
            if let code = errorCode {
                return "Migration request '\(messageType)' failed [\(code)]: \(error)"
            }
            return "Migration request '\(messageType)' failed: \(error)"
        }
    }
}
