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
    /// What the way to typing is called when the camera cannot be used ("Type the code instead"; the transfer says "Paste the
    /// code instead").
    let typeLabel: String
    /// nil until the view appears and asks iOS (once, not at every redraw).
    @State private var access: CameraAccess?

    /// [access]: the camera access to start from (tests force one; by default what iOS says when the view appears).
    init(
        onText: @escaping @MainActor (String) -> Void,
        onTypeInstead: @escaping @MainActor () -> Void,
        camera: AnyView?,
        typeLabel: String = OnboardingStrings.setupType,
        access: CameraAccess? = nil
    ) {
        self.onText = onText
        self.onTypeInstead = onTypeInstead
        self.camera = camera
        self.typeLabel = typeLabel
        _access = State(initialValue: access)
    }

    var body: some View {
        Group {
            if let camera {
                ScannerFrame(label: OnboardingStrings.moveCdQrScanner) { camera }
            } else {
                switch access ?? .notDetermined {
                case .granted:
                    QrScanner(label: OnboardingStrings.moveCdQrScanner, onText: onText, access: .granted)
                case .notDetermined:
                    ScannerFrame(label: OnboardingStrings.moveCdQrScanner) { colors.surfaceContainer.color }
                case .denied:
                    NoticeCard(
                        .info, title: OnboardingStrings.recoverScanPermissionTitle, message: OnboardingStrings.recoverScanPermissionBody
                    ) {
                        TextLink(OnboardingStrings.recoverScanAllow, identifier: "scan_allow") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        TextLink(typeLabel, action: onTypeInstead)
                    }
                    .accessibilityIdentifier("scan_permission")
                case .restricted, .unavailable:
                    NoticeCard(
                        .info, title: OnboardingStrings.recoverScanNoCameraTitle, message: OnboardingStrings.recoverScanNoCameraBody
                    ) {
                        TextLink(typeLabel, action: onTypeInstead)
                    }
                    .accessibilityIdentifier("scan_no_camera")
                }
            }
        }
        .task {
            guard camera == nil else { return }
            if access == nil { access = CameraAccess.current() }
            guard access == .notDetermined else { return }
            access = await CameraAccess.request()
        }
        // Back from Settings: the member may have allowed the camera there.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && camera == nil && access == .denied { access = CameraAccess.current() }
        }
    }
}
#endif
