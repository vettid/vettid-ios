import SwiftUI

// MARK: - Location Settings View

struct LocationSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var locationService: LocationCollectionService = .shared

    var body: some View {
        List {
            // Tracking toggle
            Section {
                Toggle("Enable Location Tracking", isOn: trackingBinding)

                if appState.preferences.location.trackingEnabled {
                    HStack {
                        Image(systemName: statusIcon)
                            .foregroundStyle(statusColor)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Location Tracking")
            } footer: {
                Text("When enabled, your location is periodically recorded and stored in your vault. Only you can access this data.")
            }

            // Permission status
            if appState.preferences.location.trackingEnabled {
                Section("Permissions") {
                    HStack {
                        Text("Location Access")
                        Spacer()
                        Text(permissionStatusText)
                            .font(.subheadline)
                            .foregroundStyle(permissionColor)
                    }

                    if !locationService.hasBackgroundPermission && locationService.hasLocationPermission {
                        Button("Enable Background Location") {
                            locationService.requestAlwaysPermission()
                        }
                    }
                }
            }

            // Settings
            if appState.preferences.location.trackingEnabled {
                Section("Precision") {
                    Picker("Precision", selection: precisionBinding) {
                        ForEach(LocationPrecision.allCases, id: \.self) { precision in
                            Text(precision.displayName).tag(precision)
                        }
                    }
                }

                Section("Collection") {
                    Picker("Frequency", selection: frequencyBinding) {
                        ForEach(LocationUpdateFrequency.allCases, id: \.self) { freq in
                            Text(freq.displayName).tag(freq)
                        }
                    }

                    Picker("Minimum Distance", selection: displacementBinding) {
                        ForEach(DisplacementThreshold.allCases, id: \.self) { threshold in
                            Text(threshold.displayName).tag(threshold)
                        }
                    }
                }

                Section("Data Retention") {
                    Picker("Keep Data For", selection: retentionBinding) {
                        ForEach(LocationRetention.allCases, id: \.self) { retention in
                            Text(retention.displayName).tag(retention)
                        }
                    }
                }
            }

            // Navigation
            Section("History") {
                NavigationLink(destination: LocationHistoryView()) {
                    Label("Location History", systemImage: "clock.arrow.circlepath")
                }

                NavigationLink(destination: SharedLocationsView()) {
                    Label("Shared Locations", systemImage: "person.2.wave.2")
                }
            }

            // Error display
            if let error = locationService.lastError {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Location")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Bindings

    private var trackingBinding: Binding<Bool> {
        Binding(
            get: { appState.preferences.location.trackingEnabled },
            set: { newValue in
                appState.preferences.location.trackingEnabled = newValue
                appState.preferences.save()
                if newValue {
                    locationService.updateSettings(appState.preferences.location)
                    locationService.startCollecting()
                } else {
                    locationService.stopCollecting()
                }
            }
        )
    }

    private var precisionBinding: Binding<LocationPrecision> {
        Binding(
            get: { appState.preferences.location.precision },
            set: { newValue in
                appState.preferences.location.precision = newValue
                appState.preferences.save()
                locationService.updateSettings(appState.preferences.location)
            }
        )
    }

    private var frequencyBinding: Binding<LocationUpdateFrequency> {
        Binding(
            get: { appState.preferences.location.updateFrequency },
            set: { newValue in
                appState.preferences.location.updateFrequency = newValue
                appState.preferences.save()
                locationService.updateSettings(appState.preferences.location)
            }
        )
    }

    private var displacementBinding: Binding<DisplacementThreshold> {
        Binding(
            get: { appState.preferences.location.displacementThreshold },
            set: { newValue in
                appState.preferences.location.displacementThreshold = newValue
                appState.preferences.save()
                locationService.updateSettings(appState.preferences.location)
            }
        )
    }

    private var retentionBinding: Binding<LocationRetention> {
        Binding(
            get: { appState.preferences.location.retention },
            set: { newValue in
                appState.preferences.location.retention = newValue
                appState.preferences.save()
            }
        )
    }

    // MARK: - Status

    private var statusIcon: String {
        locationService.isCollecting ? "location.fill" : "location.slash"
    }

    private var statusColor: Color {
        locationService.isCollecting ? .green : .orange
    }

    private var statusText: String {
        if locationService.isCollecting {
            return "Actively collecting locations"
        } else if !locationService.hasLocationPermission {
            return "Location permission required"
        } else {
            return "Not collecting"
        }
    }

    private var permissionStatusText: String {
        switch locationService.authorizationStatus {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "When In Use"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Set"
        @unknown default: return "Unknown"
        }
    }

    private var permissionColor: Color {
        switch locationService.authorizationStatus {
        case .authorizedAlways: return .green
        case .authorizedWhenInUse: return .orange
        default: return .red
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        LocationSettingsView()
            .environmentObject(AppState())
    }
}
