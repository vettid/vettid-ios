import Foundation
import SwiftUI

// MARK: - Device Models

struct ConnectedDevice: Codable, Identifiable, Equatable {
    let connectionId: String
    let deviceName: String
    let hostname: String?
    let platform: String?
    let status: String
    let sessionId: String?
    let sessionStatus: String?
    let sessionExpires: Int64?
    let connectedAt: String
    let lastActiveAt: String?

    var id: String { connectionId }

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case deviceName = "device_name"
        case hostname, platform, status
        case sessionId = "session_id"
        case sessionStatus = "session_status"
        case sessionExpires = "session_expires"
        case connectedAt = "connected_at"
        case lastActiveAt = "last_active_at"
    }

    var displayName: String {
        hostname?.isEmpty == false ? hostname! : deviceName
    }

    var platformLabel: String {
        guard let platform = platform else { return "Unknown" }
        if platform.contains("darwin") { return "macOS" }
        if platform.contains("linux") { return "Linux" }
        if platform.contains("windows") { return "Windows" }
        return platform
    }

    var platformIcon: String {
        guard let platform = platform else { return "desktopcomputer" }
        if platform.contains("darwin") { return "laptopcomputer" }
        if platform.contains("linux") { return "desktopcomputer" }
        if platform.contains("windows") { return "pc" }
        return "desktopcomputer"
    }

    var isSessionActive: Bool {
        sessionStatus == "active" && (sessionExpires.map { $0 > Int64(Date().timeIntervalSince1970) } ?? false)
    }

    var sessionTimeRemaining: TimeInterval? {
        guard let expires = sessionExpires else { return nil }
        let remaining = TimeInterval(expires) - Date().timeIntervalSince1970
        return remaining > 0 ? remaining : 0
    }
}

struct DeviceListResponse: Codable {
    let devices: [ConnectedDevice]
    let count: Int
}

// MARK: - Device Management ViewModel

@MainActor
final class DeviceManagementViewModel: ObservableObject {
    @Published private(set) var devices: [ConnectedDevice] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isRevoking = false
    @Published private(set) var isExtending = false
    @Published var errorMessage: String?

    private let ownerSpaceClient: OwnerSpaceClient
    private var heartbeatTask: Task<Void, Never>?

    init(ownerSpaceClient: OwnerSpaceClient) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    deinit {
        heartbeatTask?.cancel()
    }

    func loadDevices() async {
        isLoading = true
        do {
            let response: DeviceListResponse = try await ownerSpaceClient.request(
                EmptyPayload(),
                topic: "connection.device.list",
                responseType: DeviceListResponse.self,
                timeout: 15
            )
            devices = response.devices

            if response.devices.contains(where: { $0.isSessionActive }) {
                startHeartbeat()
            } else {
                stopHeartbeat()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func revokeDevice(_ device: ConnectedDevice) async {
        isRevoking = true
        errorMessage = nil
        do {
            try await ownerSpaceClient.sendToVault(
                RevokeRequest(connectionId: device.connectionId),
                topic: "connection.device.revoke"
            )
            await loadDevices()
        } catch {
            errorMessage = "Failed to revoke: \(error.localizedDescription)"
        }
        isRevoking = false
    }

    func extendSession(_ device: ConnectedDevice) async {
        isExtending = true
        errorMessage = nil
        do {
            try await ownerSpaceClient.sendToVault(
                ExtendRequest(connectionId: device.connectionId),
                topic: "connection.device.extend-session"
            )
            await loadDevices()
        } catch {
            errorMessage = "Failed to extend: \(error.localizedDescription)"
        }
        isExtending = false
    }

    func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000_000) // 2 min
                if Task.isCancelled { break }
                try? await self?.ownerSpaceClient.sendToVault(
                    EmptyPayload(), topic: "connection.device.heartbeat"
                )
            }
        }
    }

    func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }
}

struct EmptyPayload: Encodable {}
struct RevokeRequest: Encodable {
    let connectionId: String
    enum CodingKeys: String, CodingKey { case connectionId = "connection_id" }
}
struct ExtendRequest: Encodable {
    let connectionId: String
    enum CodingKeys: String, CodingKey { case connectionId = "connection_id" }
}

// MARK: - Device Management View

struct DeviceManagementView: View {
    let ownerSpaceClient: OwnerSpaceClient
    @StateObject private var viewModel: DeviceManagementViewModel
    @State private var deviceToRevoke: ConnectedDevice?
    @State private var showRevokeConfirmation = false

    init(ownerSpaceClient: OwnerSpaceClient) {
        self.ownerSpaceClient = ownerSpaceClient
        self._viewModel = StateObject(wrappedValue: DeviceManagementViewModel(
            ownerSpaceClient: ownerSpaceClient
        ))
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.devices.isEmpty {
                ProgressView("Loading devices...")
            } else if viewModel.devices.isEmpty {
                emptyView
            } else {
                deviceList
            }
        }
        .navigationTitle("Desktop Devices")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(destination: DevicePairingView(ownerSpaceClient: ownerSpaceClient)) {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            if let msg = viewModel.errorMessage { Text(msg) }
        }
        .confirmationDialog("Revoke Device", isPresented: $showRevokeConfirmation, presenting: deviceToRevoke) { device in
            Button("Revoke \(device.displayName)", role: .destructive) {
                Task { await viewModel.revokeDevice(device) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text("Disconnect \(device.displayName) and revoke its session?")
        }
        .task { await viewModel.loadDevices() }
        .onDisappear { viewModel.stopHeartbeat() }
    }

    private var emptyView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "desktopcomputer")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("No Desktop Devices")
                .font(.title2).fontWeight(.semibold)
            Text("Pair a desktop to access your vault from your computer.")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            NavigationLink(destination: DevicePairingView(ownerSpaceClient: ownerSpaceClient)) {
                Label("Pair Desktop", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).padding(.horizontal, 40)
            Spacer()
        }
    }

    private var deviceList: some View {
        List {
            let active = viewModel.devices.filter { $0.isSessionActive }
            let inactive = viewModel.devices.filter { !$0.isSessionActive }

            if !active.isEmpty {
                Section {
                    ForEach(active) { device in
                        DeviceRow(device: device, isExtending: viewModel.isExtending,
                            onExtend: { Task { await viewModel.extendSession(device) } },
                            onRevoke: { deviceToRevoke = device; showRevokeConfirmation = true })
                    }
                } header: {
                    HStack {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("Active Sessions")
                    }
                }
            }

            if !inactive.isEmpty {
                Section("Inactive") {
                    ForEach(inactive) { device in
                        DeviceRow(device: device, isExtending: false, onExtend: nil,
                            onRevoke: { deviceToRevoke = device; showRevokeConfirmation = true })
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await viewModel.loadDevices() }
    }
}

// MARK: - Device Row

struct DeviceRow: View {
    let device: ConnectedDevice
    let isExtending: Bool
    let onExtend: (() -> Void)?
    let onRevoke: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: device.platformIcon)
                    .font(.title2).foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName).font(.headline).lineLimit(1)
                    Text(device.platformLabel).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                StatusBadge(status: device.sessionStatus ?? device.status)
            }

            if device.isSessionActive, let remaining = device.sessionTimeRemaining {
                HStack {
                    Image(systemName: "clock").font(.caption)
                        .foregroundColor(remaining < 3600 ? .orange : .secondary)
                    Text("Session: \(formatTime(remaining))")
                        .font(.caption)
                        .foregroundColor(remaining < 3600 ? .orange : .secondary)
                }
            }

            HStack(spacing: 12) {
                if device.isSessionActive, let onExtend = onExtend {
                    Button(action: onExtend) {
                        HStack(spacing: 4) {
                            if isExtending { ProgressView().controlSize(.mini) }
                            Text("Extend").font(.caption)
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(isExtending)
                }
                if device.status != "revoked" {
                    Button(role: .destructive, action: onRevoke) {
                        Text("Revoke").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }.padding(.top, 4)
        }.padding(.vertical, 4)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

struct StatusBadge: View {
    let status: String
    var body: some View {
        Text(status.capitalized)
            .font(.caption).fontWeight(.medium)
            .foregroundColor(color).padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.2)).cornerRadius(4)
    }
    private var color: Color {
        switch status {
        case "active": return .green
        case "expired": return .orange
        case "revoked": return .red
        case "suspended": return .yellow
        default: return .secondary
        }
    }
}
