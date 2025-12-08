import XCTest
@testable import VettID

/// Tests for VaultHealthViewModel and related types
@MainActor
final class VaultHealthViewModelTests: XCTestCase {

    // MARK: - VaultHealthState Tests

    func testVaultHealthState_equality() {
        XCTAssertEqual(VaultHealthState.loading, .loading)
        XCTAssertEqual(VaultHealthState.notProvisioned, .notProvisioned)
        XCTAssertEqual(VaultHealthState.stopped, .stopped)

        XCTAssertNotEqual(VaultHealthState.loading, .notProvisioned)
        XCTAssertNotEqual(VaultHealthState.stopped, .loading)
    }

    func testVaultHealthState_provisioningEquality() {
        let state1 = VaultHealthState.provisioning(progress: 0.5, status: "Starting...")
        let state2 = VaultHealthState.provisioning(progress: 0.5, status: "Starting...")
        let state3 = VaultHealthState.provisioning(progress: 0.7, status: "Starting...")
        let state4 = VaultHealthState.provisioning(progress: 0.5, status: "Different")

        XCTAssertEqual(state1, state2)
        XCTAssertNotEqual(state1, state3)
        XCTAssertNotEqual(state1, state4)
    }

    func testVaultHealthState_errorEquality() {
        let error1 = VaultHealthState.error("Error message")
        let error2 = VaultHealthState.error("Error message")
        let error3 = VaultHealthState.error("Different error")

        XCTAssertEqual(error1, error2)
        XCTAssertNotEqual(error1, error3)
    }

    func testVaultHealthState_displayTitles() {
        XCTAssertEqual(VaultHealthState.loading.displayTitle, "Loading...")
        XCTAssertEqual(VaultHealthState.notProvisioned.displayTitle, "No Vault")
        XCTAssertEqual(VaultHealthState.provisioning(progress: 0, status: "").displayTitle, "Provisioning...")
        XCTAssertEqual(VaultHealthState.stopped.displayTitle, "Stopped")
        XCTAssertEqual(VaultHealthState.error("test").displayTitle, "Error")
    }

    func testVaultHealthState_isLoaded() {
        let healthInfo = makeHealthInfo()

        XCTAssertFalse(VaultHealthState.loading.isLoaded)
        XCTAssertFalse(VaultHealthState.notProvisioned.isLoaded)
        XCTAssertFalse(VaultHealthState.provisioning(progress: 0, status: "").isLoaded)
        XCTAssertFalse(VaultHealthState.stopped.isLoaded)
        XCTAssertFalse(VaultHealthState.error("test").isLoaded)
        XCTAssertTrue(VaultHealthState.loaded(healthInfo).isLoaded)
    }

    func testVaultHealthState_isProvisioning() {
        XCTAssertFalse(VaultHealthState.loading.isProvisioning)
        XCTAssertFalse(VaultHealthState.notProvisioned.isProvisioning)
        XCTAssertTrue(VaultHealthState.provisioning(progress: 0.5, status: "test").isProvisioning)
        XCTAssertFalse(VaultHealthState.stopped.isProvisioning)
    }

    // MARK: - VaultHealthInfo Tests

    func testVaultHealthInfo_formattedUptime_hoursAndMinutes() {
        let info = makeHealthInfo(uptimeSeconds: 7500) // 2h 5m
        XCTAssertEqual(info.formattedUptime, "2h 5m")
    }

    func testVaultHealthInfo_formattedUptime_minutesOnly() {
        let info = makeHealthInfo(uptimeSeconds: 300) // 5m
        XCTAssertEqual(info.formattedUptime, "5m")
    }

    func testVaultHealthInfo_latencyDescription_excellent() {
        let info = makeHealthInfo(latencyMs: 30)
        XCTAssertEqual(info.latencyDescription, "Excellent")
    }

    func testVaultHealthInfo_latencyDescription_good() {
        let info = makeHealthInfo(latencyMs: 75)
        XCTAssertEqual(info.latencyDescription, "Good")
    }

    func testVaultHealthInfo_latencyDescription_fair() {
        let info = makeHealthInfo(latencyMs: 150)
        XCTAssertEqual(info.latencyDescription, "Fair")
    }

    func testVaultHealthInfo_latencyDescription_poor() {
        let info = makeHealthInfo(latencyMs: 250)
        XCTAssertEqual(info.latencyDescription, "Poor")
    }

    // MARK: - HealthStatus Tests

    func testHealthStatus_displayName() {
        XCTAssertEqual(HealthStatus.healthy.displayName, "Healthy")
        XCTAssertEqual(HealthStatus.degraded.displayName, "Degraded")
        XCTAssertEqual(HealthStatus.unhealthy.displayName, "Unhealthy")
    }

    func testHealthStatus_isOperational() {
        XCTAssertTrue(HealthStatus.healthy.isOperational)
        XCTAssertTrue(HealthStatus.degraded.isOperational)
        XCTAssertFalse(HealthStatus.unhealthy.isOperational)
    }

    func testHealthStatus_rawValueParsing() {
        XCTAssertEqual(HealthStatus(rawValue: "healthy"), .healthy)
        XCTAssertEqual(HealthStatus(rawValue: "degraded"), .degraded)
        XCTAssertEqual(HealthStatus(rawValue: "unhealthy"), .unhealthy)
        XCTAssertNil(HealthStatus(rawValue: "unknown"))
    }

    // MARK: - VaultHealthViewModel Initialization Tests

    func testVaultHealthViewModel_initialState() {
        let viewModel = VaultHealthViewModel(authTokenProvider: { nil })

        XCTAssertEqual(viewModel.healthState, .loading)
        XCTAssertFalse(viewModel.isPolling)
    }

    func testVaultHealthViewModel_startAndStopPolling() {
        let viewModel = VaultHealthViewModel(authTokenProvider: { nil })

        XCTAssertFalse(viewModel.isPolling)

        viewModel.startHealthMonitoring()
        XCTAssertTrue(viewModel.isPolling)

        viewModel.stopHealthMonitoring()
        XCTAssertFalse(viewModel.isPolling)
    }

    func testVaultHealthViewModel_checkHealth_noAuthToken() async {
        let viewModel = VaultHealthViewModel(authTokenProvider: { nil })

        await viewModel.checkHealth()

        if case .error(let message) = viewModel.healthState {
            XCTAssertTrue(message.contains("authenticated"))
        } else {
            XCTFail("Expected error state for missing auth token")
        }
    }

    // MARK: - Helpers

    private func makeHealthInfo(
        status: HealthStatus = .healthy,
        uptimeSeconds: Int = 3600,
        latencyMs: Int = 50
    ) -> VaultHealthInfo {
        let response = VaultHealthResponse(
            status: status.rawValue,
            uptimeSeconds: uptimeSeconds,
            localNats: LocalNatsHealth(status: "running", connections: 5),
            centralNats: CentralNatsHealth(status: "connected", latencyMs: latencyMs),
            vaultManager: VaultManagerHealth(status: "running", memoryMb: 256, cpuPercent: 15.5, handlersLoaded: 10),
            lastEventAt: nil
        )
        return VaultHealthInfo(from: response)
    }
}
