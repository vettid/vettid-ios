import Foundation
import BackgroundTasks

// MARK: - PCR Update Service

/// Manages periodic updates of expected PCR values
///
/// This service:
/// - Fetches PCR updates from the backend on app launch
/// - Schedules background refresh tasks for periodic updates
/// - Verifies signatures on PCR updates
/// - Stores verified PCR sets for attestation verification
@MainActor
final class PCRUpdateService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var lastUpdateCheck: Date?
    @Published private(set) var updateError: Error?
    @Published private(set) var isUpdating: Bool = false

    // MARK: - Dependencies

    private let apiClient: APIClient
    private let pcrStore: ExpectedPCRStore

    // MARK: - Configuration

    /// Background task identifier
    static let backgroundTaskIdentifier = "dev.vettid.pcr-refresh"

    /// Minimum interval between update checks (1 hour)
    private let minimumUpdateInterval: TimeInterval = 3600

    /// Time for background task to complete
    private let backgroundTaskTimeout: TimeInterval = 25

    // MARK: - Initialization

    init(apiClient: APIClient = APIClient(), pcrStore: ExpectedPCRStore = ExpectedPCRStore()) {
        self.apiClient = apiClient
        self.pcrStore = pcrStore
    }

    // MARK: - Public API

    /// Check for PCR updates
    /// - Parameter force: If true, skip the minimum interval check
    func checkForUpdates(force: Bool = false) async {
        // Skip if recently checked (unless forced)
        if !force, let lastCheck = lastUpdateCheck,
           Date().timeIntervalSince(lastCheck) < minimumUpdateInterval {
            #if DEBUG
            print("[PCRUpdate] Skipping update check - too recent")
            #endif
            return
        }

        isUpdating = true
        updateError = nil

        do {
            // Fetch current PCRs from API
            let response = try await apiClient.getCurrentPCRs()

            // Convert API response to store format
            let storeResponse = ExpectedPCRStore.PCRUpdateResponse(
                pcrSets: response.pcrSets.map { $0.toPCRSet() },
                signature: response.signature,
                signedAt: response.signedAt
            )

            // Store and verify the update
            try pcrStore.storeUpdatedPCRSets(storeResponse)

            lastUpdateCheck = Date()

            #if DEBUG
            print("[PCRUpdate] Successfully updated PCRs - \(response.pcrSets.count) sets")
            #endif

        } catch {
            updateError = error
            #if DEBUG
            print("[PCRUpdate] Failed to update PCRs: \(error.localizedDescription)")
            #endif
        }

        isUpdating = false
    }

    /// Get the current valid PCR sets
    func getValidPCRSets() -> [ExpectedPCRStore.PCRSet] {
        return pcrStore.getValidPCRSets()
    }

    /// Get the current (primary) PCR set for attestation
    func getCurrentPCRSet() -> ExpectedPCRStore.PCRSet? {
        return pcrStore.getCurrentPCRSet()
    }

    /// Check if attestation can be performed (has valid PCRs)
    var canPerformAttestation: Bool {
        return pcrStore.getCurrentPCRSet() != nil
    }

    // MARK: - Background Tasks

    /// Register background task handler
    /// Call this from AppDelegate.application(_:didFinishLaunchingWithOptions:)
    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            Task { @MainActor in
                await PCRUpdateService.shared.handleBackgroundRefresh(task: refreshTask)
            }
        }

        #if DEBUG
        print("[PCRUpdate] Background task registered")
        #endif
    }

    /// Schedule the next background refresh
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
        // Schedule for 24 hours from now (iOS may adjust this)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 3600)

        do {
            try BGTaskScheduler.shared.submit(request)
            #if DEBUG
            print("[PCRUpdate] Background refresh scheduled")
            #endif
        } catch {
            #if DEBUG
            print("[PCRUpdate] Failed to schedule background refresh: \(error)")
            #endif
        }
    }

    /// Handle background refresh task
    private func handleBackgroundRefresh(task: BGAppRefreshTask) async {
        // Schedule the next refresh
        scheduleBackgroundRefresh()

        // Set up expiration handler
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        // Perform update check
        await checkForUpdates(force: true)

        // Complete the task
        task.setTaskCompleted(success: updateError == nil)
    }

    // MARK: - App Lifecycle Integration

    /// Call when app becomes active
    func onAppDidBecomeActive() {
        Task {
            await checkForUpdates()
        }
    }

    /// Call when app enters background
    func onAppDidEnterBackground() {
        scheduleBackgroundRefresh()
    }

    // MARK: - Singleton

    /// Shared instance for background task handling
    static let shared = PCRUpdateService()
}

// MARK: - SwiftUI Integration

import SwiftUI

extension PCRUpdateService {
    /// Environment key for dependency injection
    struct EnvironmentKey: SwiftUI.EnvironmentKey {
        static let defaultValue = PCRUpdateService.shared
    }
}

extension EnvironmentValues {
    var pcrUpdateService: PCRUpdateService {
        get { self[PCRUpdateService.EnvironmentKey.self] }
        set { self[PCRUpdateService.EnvironmentKey.self] = newValue }
    }
}

// MARK: - Attestation Integration

extension PCRUpdateService {
    /// Verify attestation document using current PCR sets
    /// - Parameters:
    ///   - attestationDocument: Raw CBOR attestation document
    ///   - nonce: Optional nonce for replay protection
    /// - Returns: Attestation result if verification succeeds
    func verifyAttestation(
        attestationDocument: Data,
        nonce: Data? = nil
    ) throws -> NitroAttestationVerifier.AttestationResult {
        // Get current PCR set
        guard let pcrSet = getCurrentPCRSet() else {
            throw PCRStoreError.noPCRSetsAvailable
        }

        // Create verifier and verify
        let verifier = NitroAttestationVerifier()
        return try verifier.verify(
            attestationDocument: attestationDocument,
            expectedPCRs: pcrSet.toExpectedPCRs(),
            nonce: nonce
        )
    }

    /// Try to verify attestation against any valid PCR set
    /// Use this during PCR transition periods
    func verifyAttestationWithFallback(
        attestationDocument: Data,
        nonce: Data? = nil
    ) throws -> NitroAttestationVerifier.AttestationResult {
        let validSets = getValidPCRSets()
        guard !validSets.isEmpty else {
            throw PCRStoreError.noPCRSetsAvailable
        }

        let verifier = NitroAttestationVerifier()
        var lastError: Error?

        // Try each valid PCR set
        for pcrSet in validSets {
            do {
                return try verifier.verify(
                    attestationDocument: attestationDocument,
                    expectedPCRs: pcrSet.toExpectedPCRs(),
                    nonce: nonce
                )
            } catch {
                lastError = error
                // Continue to next PCR set
            }
        }

        // All sets failed
        throw lastError ?? PCRStoreError.noPCRSetsAvailable
    }
}
