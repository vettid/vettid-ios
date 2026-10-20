#if os(iOS)
import SwiftUI
import UIKit
import VettIDUI

/// The camera in a gold frame (VettIDUI's ``QrScanner``), or why there is none. Mirrors vettid-android `ScannerBox`, with
/// the camera-permission states of iOS: iOS asks once (when the screen opens); after a refusal only Settings can allow the
/// camera, so "Allow the camera" opens the app's page in Settings, and the code can be typed instead; on a phone where
/// the camera is restricted or missing, the code is typed. [camera] replaces the camera in previews and the screen
/// catalog.
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

    var body: some View {
        Group {
            if let camera {
                ScannerFrame(label: OnboardingStrings.moveCdQrScanner) { camera }
            } else {
                switch access {
                case .granted:
                    QrScanner(label: OnboardingStrings.moveCdQrScanner, onText: onText)
                case .notDetermined:
                    ScannerFrame(label: OnboardingStrings.moveCdQrScanner) { colors.surfaceContainer.color }
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
                case .restricted, .unavailable:
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
            access = await CameraAccess.request()
        }
        // Back from Settings: the member may have allowed the camera there.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && camera == nil && access == .denied { access = CameraAccess.current() }
        }
    }
}
#endif
