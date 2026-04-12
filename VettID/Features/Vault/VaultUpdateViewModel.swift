import Foundation

@MainActor
final class VaultUpdateViewModel: ObservableObject {

    enum State {
        case checking
        case noUpdate
        case updateAvailable(config: MigrationConfig, isMandatory: Bool)
        case updating
        case updated
        case error(String)
    }

    @Published var state: State = .checking

    var migrationClient: MigrationClient?

    // MARK: - Persistence Keys

    private static let remindedAtKey = "com.vettid.migration.remindedAt"
    private static let completedVersionKey = "com.vettid.migration.completedVersion"
    private static let dismissedKey = "com.vettid.migration.dismissed"

    // MARK: - Check for Update

    /// Check for a pending vault update. Call this after vault warming.
    func checkForUpdate() async {
        state = .checking

        guard let client = migrationClient else {
            state = .noUpdate
            return
        }

        do {
            guard let config = try await client.getConfig() else {
                state = .noUpdate
                return
            }

            // Skip if already completed this version
            let completedVersion = UserDefaults.standard.string(forKey: Self.completedVersionKey)
            if completedVersion == config.version {
                state = .noUpdate
                return
            }

            // Check if mandatory: either past mandatoryAfter or deferred > 72 hours
            var isMandatory = config.isMandatory
            if !isMandatory {
                let remindedAt = UserDefaults.standard.double(forKey: Self.remindedAtKey)
                if remindedAt > 0 {
                    let hoursSinceDeferred = (Date().timeIntervalSince1970 - remindedAt) / 3600
                    if hoursSinceDeferred > 72 {
                        isMandatory = true // Becomes mandatory after 72 hours of deferral
                    }
                }
            }

            // Skip if recently dismissed and not mandatory
            if !isMandatory && UserDefaults.standard.bool(forKey: Self.dismissedKey) {
                state = .noUpdate
                return
            }

            state = .updateAvailable(config: config, isMandatory: isMandatory)
        } catch {
            // Don't block the user if migration check fails
            #if DEBUG
            print("[VaultUpdateVM] Check failed: \(error)")
            #endif
            state = .noUpdate
        }
    }

    // MARK: - Start Update

    /// Start the vault migration with auto-retry (5 attempts, exponential backoff).
    func startUpdate() async {
        guard let client = migrationClient else { return }

        // Capture config BEFORE transitioning state
        let capturedState = state
        state = .updating

        let maxAttempts = 5

        for attempt in 1...maxAttempts {
            do {
                let success = try await client.startMigration()
                if success {
                    // Mark as completed using the captured config
                    if case .updateAvailable(let config, _) = capturedState {
                        UserDefaults.standard.set(config.version, forKey: Self.completedVersionKey)
                        try? await client.acknowledgeMigration(version: config.version)
                    }
                    UserDefaults.standard.removeObject(forKey: Self.dismissedKey)
                    state = .updated
                    return
                }
            } catch {
                #if DEBUG
                print("[VaultUpdateVM] Attempt \(attempt)/\(maxAttempts) failed: \(error)")
                #endif
            }

            if attempt < maxAttempts {
                let delay = UInt64(1_500_000_000 * pow(1.5, Double(attempt - 1)))
                try? await Task.sleep(nanoseconds: delay)
            }
        }

        state = .error("Update failed after \(maxAttempts) attempts. Please try again later.")
    }

    // MARK: - Remind Later

    /// Defer the update until next app open.
    func remindLater() {
        UserDefaults.standard.set(true, forKey: Self.dismissedKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.remindedAtKey)
        state = .noUpdate
    }

    // MARK: - Reset (for next session)

    /// Clear the dismissed flag so the update shows again next session.
    static func resetDismissedFlag() {
        UserDefaults.standard.removeObject(forKey: dismissedKey)
    }

}
