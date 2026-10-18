#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit
import VettIDUI

/// Whether the camera can be used to read the setup QR.
enum CameraAccess: Equatable, Sendable {
    case granted
    /// Not asked yet: iOS asks when the scan screen opens.
    case notDetermined
    /// Refused: only Settings can allow it now.
    case denied
    /// No camera (the simulator), or one this phone does not let apps use (restricted, for example by Screen Time or a
    /// device policy, which the member may not be able to change): the code is typed instead.
    case unavailable

    static func current() -> CameraAccess {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        return switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .unavailable
        }
    }
}

/// The camera in a gold frame, or why there is none. Mirrors vettid-android `ScannerBox`, with the camera-permission
/// states of iOS: iOS asks once (when the screen opens); after a refusal only Settings can allow the camera, so "Allow
/// the camera" opens the app's page in Settings, and the code can be typed instead. [camera] replaces the camera in
/// previews and the screen catalog.
struct ScannerBox: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    let onText: @MainActor (String) -> Void
    let onTypeInstead: @MainActor () -> Void
    let camera: AnyView?
    @State private var access: CameraAccess

    /// [access]: the camera access to start from (tests force one; by default what iOS says now).
    init(
        onText: @escaping @MainActor (String) -> Void,
        onTypeInstead: @escaping @MainActor () -> Void,
        camera: AnyView?,
        access: CameraAccess = CameraAccess.current()
    ) {
        self.onText = onText
        self.onTypeInstead = onTypeInstead
        self.camera = camera
        _access = State(initialValue: access)
    }

    private static let height: CGFloat = 320

    var body: some View {
        Group {
            if let camera {
                frame { camera }
            } else {
                switch access {
                case .granted:
                    frame { QrScannerView(onText: onText) }
                case .notDetermined:
                    frame { colors.surfaceContainer.color }
                case .denied:
                    NoticeCard(
                        .info, title: OnboardingStrings.recoverScanPermissionTitle, message: OnboardingStrings.recoverScanPermissionBody
                    ) {
                        TextLink(OnboardingStrings.recoverScanAllow, identifier: "scan_allow") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        TextLink(OnboardingStrings.setupType, action: onTypeInstead)
                    }
                    .accessibilityIdentifier("scan_permission")
                case .unavailable:
                    NoticeCard(
                        .info, title: OnboardingStrings.recoverScanNoCameraTitle, message: OnboardingStrings.recoverScanNoCameraBody
                    ) {
                        TextLink(OnboardingStrings.setupType, action: onTypeInstead)
                    }
                    .accessibilityIdentifier("scan_no_camera")
                }
            }
        }
        .task {
            guard camera == nil, access == .notDetermined else { return }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            access = granted ? .granted : .denied
        }
        // Back from Settings: the member may have allowed the camera there.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && camera == nil && access == .denied { access = CameraAccess.current() }
        }
    }

    private func frame(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .clipShape(VettIDShape.card)
            .padding(2)
            .overlay(VettIDShape.card.stroke(colors.primary, lineWidth: 2))
            .accessibilityElement()
            .accessibilityLabel(OnboardingStrings.moveCdQrScanner)
            .accessibilityIdentifier("scanner")
    }
}
#endif
