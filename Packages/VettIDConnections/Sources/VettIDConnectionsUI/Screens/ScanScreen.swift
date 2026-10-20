#if os(iOS)
import SwiftUI
import UIKit
import VettIDConnections
import VettIDData
import VettIDUI

/// Scan an invitation's QR code; nothing is sent until it is a valid connection invitation (``ScanViewModel``). The
/// camera-permission states of iOS: asked once when the screen opens; after a refusal "Allow camera" opens the app's
/// page in Settings (iOS asks only once) and the camera is looked at again on return; where the camera is restricted or
/// missing (the simulator), the note says to paste the link instead. [camera] replaces the camera in tests and the screen
/// catalog. Mirrors vettid-android `ScanScreen`.
public struct ScanScreen: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.vettIDColors) private var colors
    let state: ScanState
    let onBack: @MainActor () -> Void
    let onScanned: @MainActor (String) -> Void
    let onPaste: @MainActor () -> Void
    let onLink: @MainActor (String) -> Void
    let camera: AnyView?
    /// nil until the screen appears and asks iOS (once, not at every redraw).
    @State private var access: CameraAccess?

    /// [access]: the camera access to start from (tests force one; by default what iOS says when the screen appears).
    public init(
        state: ScanState,
        onBack: @escaping @MainActor () -> Void,
        onScanned: @escaping @MainActor (String) -> Void,
        onPaste: @escaping @MainActor () -> Void,
        onLink: @escaping @MainActor (String) -> Void,
        camera: AnyView? = nil,
        access: CameraAccess? = nil
    ) {
        self.state = state
        self.onBack = onBack
        self.onScanned = onScanned
        self.onPaste = onPaste
        self.onLink = onLink
        self.camera = camera
        _access = State(initialValue: access)
    }

    public var body: some View {
        FormScaffold(
            title: ConnectStrings.scanTitle,
            message: ConnectStrings.scanBody,
            primaryLabel: camera == nil && access == .denied ? ConnectStrings.scanAllow : nil,
            secondaryLabel: ConnectStrings.scanPasteInstead,
            onPrimary: openSettings,
            onSecondary: onPaste,
            onBack: onBack
        ) {
            scanner
            FailureLine(kind: state.problem)
        }
        .accessibilityIdentifier("scan_screen")
        .onChange(of: state.link, initial: true) { _, link in if let link { onLink(link) } }
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

    @ViewBuilder private var scanner: some View {
        if let camera {
            ScannerFrame(label: ConnectStrings.scanTitle) { camera }
        } else {
            switch access ?? .notDetermined {
            case .granted:
                QrScanner(label: ConnectStrings.scanTitle, onText: onScanned, access: .granted)
            case .notDetermined:
                ScannerFrame(label: ConnectStrings.scanTitle) { colors.surfaceContainer.color }
            case .denied:
                NoticeCard(.info, title: ConnectStrings.scanPermissionTitle, message: ConnectStrings.scanPermissionBody)
                    .accessibilityIdentifier("scan_permission")
            case .restricted, .unavailable:
                ScannerFrame(label: nil) { ScannerNoCameraNote() }
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}
#endif
