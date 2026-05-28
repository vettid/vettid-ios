import SwiftUI
import AVFoundation
import UserNotifications
import CoreLocation

/// Post-enrollment permissions screen.
/// All permissions are optional — "Continue" is always enabled.
struct PermissionsPhaseView: View {

    var onContinue: () -> Void

    @State private var notificationsGranted = false
    @State private var cameraGranted = false
    @State private var microphoneGranted = false
    @State private var locationGranted = false

    @State private var notificationsChecked = false
    @State private var cameraChecked = false
    @State private var microphoneChecked = false
    @State private var locationChecked = false

    @StateObject private var locationRequester = LocationPermissionRequester()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer().frame(height: 12)

                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentColor)

                    VStack(spacing: 8) {
                        Text("Make VettID work first time")
                            .font(.title2)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                        Text("We'll set up the permissions VettID needs now so calls, messages, and notifications work the moment your enrollment finishes. Each is optional — you can continue without any of them.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 12) {
                        PermissionCard(
                            icon: "bell.badge",
                            title: "Notifications",
                            description: "Incoming calls, messages, connection requests, and security alerts.",
                            isGranted: notificationsGranted,
                            isChecked: notificationsChecked
                        ) {
                            await requestNotifications()
                        }

                        PermissionCard(
                            icon: "mic",
                            title: "Microphone",
                            description: "Voice and video calls. Granting now means the first call connects with audio working — without it the OS prompt fires too late to attach your mic.",
                            isGranted: microphoneGranted,
                            isChecked: microphoneChecked
                        ) {
                            await requestMicrophone()
                        }

                        PermissionCard(
                            icon: "camera",
                            title: "Camera",
                            description: "Video calls, QR-code scanning to add connections, and your profile photo.",
                            isGranted: cameraGranted,
                            isChecked: cameraChecked
                        ) {
                            await requestCamera()
                        }

                        PermissionCard(
                            icon: "location",
                            title: "Location",
                            description: "Optional. Lets you share your location with a connection — only when you turn the toggle on for that connection. Granting here avoids an OS prompt mid-flow.",
                            isGranted: locationGranted,
                            isChecked: locationChecked
                        ) {
                            await requestLocation()
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            Button {
                onContinue()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .task {
            await checkExistingPermissions()
        }
    }

    // MARK: - Permission Requests

    private func requestNotifications() async {
        let center = UNUserNotificationCenter.current()
        do {
            notificationsGranted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            #if DEBUG
            print("[Permissions] Notification request failed: \(error)")
            #endif
        }
        notificationsChecked = true
    }

    private func requestCamera() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            cameraGranted = await AVCaptureDevice.requestAccess(for: .video)
        } else {
            cameraGranted = status == .authorized
        }
        cameraChecked = true
    }

    private func requestMicrophone() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            microphoneGranted = status == .authorized
        }
        microphoneChecked = true
    }

    private func requestLocation() async {
        locationGranted = await locationRequester.request()
        locationChecked = true
    }

    private func checkExistingPermissions() async {
        // Notifications
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsGranted = settings.authorizationStatus == .authorized
        notificationsChecked = settings.authorizationStatus != .notDetermined

        // Camera
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        cameraGranted = cameraStatus == .authorized
        cameraChecked = cameraStatus != .notDetermined

        // Microphone
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneGranted = micStatus == .authorized
        microphoneChecked = micStatus != .notDetermined

        // Location
        let locStatus = CLLocationManager().authorizationStatus
        locationGranted = locStatus == .authorizedWhenInUse || locStatus == .authorizedAlways
        locationChecked = locStatus != .notDetermined
    }
}

// MARK: - Location Permission Requester

/// Bridges CLLocationManager's delegate-based authorization callback to
/// async/await so the Location card can `await` the user's choice.
/// CoreLocation has no async authorization API like AVCaptureDevice.
private final class LocationPermissionRequester: NSObject, ObservableObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<Bool, Never>?

    func request() async -> Bool {
        let status = CLLocationManager().authorizationStatus
        // Already decided — return the current verdict without re-prompting.
        if status != .notDetermined {
            return status == .authorizedWhenInUse || status == .authorizedAlways
        }
        return await withCheckedContinuation { cont in
            self.continuation = cont
            let mgr = CLLocationManager()
            mgr.delegate = self
            self.manager = mgr
            mgr.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        // The delegate fires once with .notDetermined right after we set
        // it — ignore that and wait for the user's actual choice.
        guard status != .notDetermined else { return }
        continuation?.resume(returning: status == .authorizedWhenInUse || status == .authorizedAlways)
        continuation = nil
    }
}

// MARK: - Permission Card

struct PermissionCard: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let isChecked: Bool
    let onRequest: () async -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if isChecked {
                Image(systemName: "xmark.circle")
                    .foregroundColor(.secondary)
            } else {
                Button("Allow") {
                    Task { await onRequest() }
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemBackground))
        )
    }
}
