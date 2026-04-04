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

    var body: some View {
        VStack(spacing: 24) {
            Text("Permissions")
                .font(.title2.weight(.bold))

            Text("VettID works best with these permissions. You can change them later in Settings.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 12) {
                PermissionCard(
                    icon: "bell.badge",
                    title: "Notifications",
                    description: "Get alerts for connection requests, messages, and vault activity.",
                    isGranted: notificationsGranted,
                    isChecked: notificationsChecked
                ) {
                    await requestNotifications()
                }

                PermissionCard(
                    icon: "camera",
                    title: "Camera",
                    description: "Scan QR codes for connections and credentials.",
                    isGranted: cameraGranted,
                    isChecked: cameraChecked
                ) {
                    await requestCamera()
                }

                PermissionCard(
                    icon: "mic",
                    title: "Microphone",
                    description: "Make voice and video calls to your connections.",
                    isGranted: microphoneGranted,
                    isChecked: microphoneChecked
                ) {
                    await requestMicrophone()
                }
            }
            .padding(.horizontal)

            Spacer()

            Button("Continue") {
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 40)
        }
        .padding(.top, 40)
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
