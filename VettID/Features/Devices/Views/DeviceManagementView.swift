import SwiftUI

/// Main view for managing connected devices
struct DeviceManagementView: View {
    @StateObject private var viewModel: DeviceManagementViewModel
    @State private var showPairing = false
    @State private var showRevokeConfirmation = false
    @State private var deviceToRevoke: ConnectedDevice?

    init(ownerSpaceClient: OwnerSpaceClient? = nil) {
        self._viewModel = StateObject(wrappedValue: DeviceManagementViewModel(
            ownerSpaceClient: ownerSpaceClient
        ))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                loadingView

            case .empty:
                emptyView

            case .loaded(let devices):
                deviceListView(devices)

            case .error(let message):
                errorView(message)
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showPairing = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showPairing) {
            NavigationStack {
                DevicePairingView(ownerSpaceClient: viewModel.ownerSpaceClientRef)
            }
        }
        .alert("Revoke Device", isPresented: $showRevokeConfirmation) {
            Button("Cancel", role: .cancel) {
                deviceToRevoke = nil
            }
            Button("Revoke", role: .destructive) {
                if let device = deviceToRevoke {
                    Task {
                        await viewModel.revokeDevice(connectionId: device.connectionId)
                    }
                }
                deviceToRevoke = nil
            }
        } message: {
            if let device = deviceToRevoke {
                Text("Are you sure you want to revoke access for \"\(device.deviceName)\"? This device will no longer be able to connect to your vault.")
            }
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            if let message = viewModel.errorMessage {
                Text(message)
            }
        }
        .task {
            await viewModel.loadDevices()
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading devices...")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("No Connected Devices")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Pair a new device to access your vault from multiple devices.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Button {
                showPairing = true
            } label: {
                Label("Pair New Device", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Device List

    private func deviceListView(_ devices: [ConnectedDevice]) -> some View {
        List {
            // Active devices
            let activeDevices = devices.filter { $0.status == .active }
            if !activeDevices.isEmpty {
                Section {
                    ForEach(activeDevices) { device in
                        DeviceRow(device: device)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deviceToRevoke = device
                                    showRevokeConfirmation = true
                                } label: {
                                    Label("Revoke", systemImage: "xmark.circle")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                if device.isSessionActive {
                                    Button {
                                        Task {
                                            await viewModel.extendSession(
                                                connectionId: device.connectionId
                                            )
                                        }
                                    } label: {
                                        Label("Extend", systemImage: "clock.arrow.circlepath")
                                    }
                                    .tint(.blue)
                                }
                            }
                    }
                } header: {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Active")
                    }
                }
            }

            // Inactive / other devices
            let otherDevices = devices.filter { $0.status != .active }
            if !otherDevices.isEmpty {
                Section {
                    ForEach(otherDevices) { device in
                        DeviceRow(device: device)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if device.status != .revoked {
                                    Button(role: .destructive) {
                                        deviceToRevoke = device
                                        showRevokeConfirmation = true
                                    } label: {
                                        Label("Revoke", systemImage: "xmark.circle")
                                    }
                                }
                            }
                    }
                } header: {
                    HStack {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                        Text("Other")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await viewModel.refresh()
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundStyle(.red)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Retry") {
                Task { await viewModel.loadDevices() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Device Row

struct DeviceRow: View {
    let device: ConnectedDevice

    var body: some View {
        HStack(spacing: 12) {
            // Platform icon
            Image(systemName: device.platformIcon)
                .font(.title2)
                .foregroundStyle(device.status == .active ? .blue : .secondary)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(device.status == .active ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(device.deviceName)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    DeviceStatusBadge(status: device.status)
                }

                HStack(spacing: 8) {
                    if let hostname = device.hostname {
                        Text(hostname)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let platform = device.platform {
                        Text(platform)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Session info
                if let sessionStatus = device.sessionStatus {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(sessionIndicatorColor(sessionStatus))
                            .frame(width: 6, height: 6)

                        Text(sessionLabel(device))
                            .font(.caption)
                            .foregroundStyle(device.isSessionExpiringSoon ? .orange : .secondary)
                    }
                }

                Text("Last active \(device.lastActiveAt, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func sessionIndicatorColor(_ status: SessionStatus) -> Color {
        switch status {
        case .active: return .green
        case .expired: return .orange
        case .revoked: return .red
        }
    }

    private func sessionLabel(_ device: ConnectedDevice) -> String {
        guard let sessionStatus = device.sessionStatus else { return "" }

        switch sessionStatus {
        case .active:
            if let remaining = device.sessionTimeRemaining {
                return "Session active - \(remaining) remaining"
            }
            return "Session active"
        case .expired:
            return "Session expired"
        case .revoked:
            return "Session revoked"
        }
    }
}

// MARK: - Device Status Badge

struct DeviceStatusBadge: View {
    let status: DeviceConnectionStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(backgroundColor)
            .cornerRadius(4)
    }

    private var textColor: Color {
        switch status {
        case .active: return .green
        case .inactive: return .orange
        case .pending: return .blue
        case .revoked: return .red
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .active: return .green.opacity(0.15)
        case .inactive: return .orange.opacity(0.15)
        case .pending: return .blue.opacity(0.15)
        case .revoked: return .red.opacity(0.15)
        }
    }
}

// MARK: - ViewModel Extension for Client Access

extension DeviceManagementViewModel {
    /// Expose the OwnerSpaceClient reference for child views
    var ownerSpaceClientRef: OwnerSpaceClient? {
        // This is a workaround to pass the client to sheet views
        // In a real app, this would use EnvironmentObject or a DI container
        nil // Sheets should receive the client via their own configuration
    }
}

// MARK: - Preview

#if DEBUG
struct DeviceManagementView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            DeviceManagementView()
        }
    }
}
#endif
