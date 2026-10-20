@preconcurrency import AVFoundation
import CoreImage
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import VettIDUI

/// The QR scanner's logic without a camera: which decoded texts reach the caller, the camera-permission states, and the
/// note that stands in for a camera this phone does not have (the simulator). Mirrors vettid-android `QrScannerTest`.
@MainActor
@Suite struct QrScannerTests {
    let t0 = Date(timeIntervalSince1970: 1_791_115_200)

    @Test func eachNewTextPassesAndTheSameOneOnlyAfterTwoSeconds() {
        var gate = QrTextGate()
        // (text, seconds after the first read): the reads that pass.
        let reads: [(String, TimeInterval)] = [("a", 0), ("a", 0.5), ("a", 1.9), ("b", 1.9), ("a", 2.0), ("a", 3.0), ("a", 4.0)]
        let passes = [true, false, false, true, true, false, true]
        for ((text, at), pass) in zip(reads, passes) {
            let ok = gate.admit(text, at: t0.addingTimeInterval(at))
            #expect(ok == pass, "\(text) at \(at)")
        }
    }

    @Test func emptyAndOverlongTextsAreDroppedUnread() {
        var gate = QrTextGate()
        var ok: Bool
        ok = gate.admit("", at: t0)
        #expect(!ok)
        ok = gate.admit(String(repeating: "x", count: QrTextGate.maxLength + 1), at: t0)
        #expect(!ok)
        ok = gate.admit(String(repeating: "x", count: QrTextGate.maxLength), at: t0)
        #expect(ok)
    }

    @Test func thePermissionStates() {
        #expect(CameraAccess.of(.authorized) == .granted)
        #expect(CameraAccess.of(.notDetermined) == .notDetermined)
        #expect(CameraAccess.of(.denied) == .denied)
        #expect(CameraAccess.of(.restricted) == .restricted)
        #expect(CameraAccess.restricted.cannotScan && CameraAccess.unavailable.cannotScan)
        #expect(!CameraAccess.granted.cannotScan && !CameraAccess.denied.cannotScan && !CameraAccess.notDetermined.cannotScan)
    }

    @Test func withoutACameraTheNoteStandsInForThePreview() {
        #expect(UIStrings.scannerNoCamera == "This device has no camera that VettID can use. Type or paste the code instead.")
        #if targetEnvironment(simulator)
        #expect(CameraAccess.current() == .unavailable)
        #endif
        let none = host(QrScanner(label: "Scanner", onText: { _ in }, access: .unavailable).vettIDTheme())
        #expect(!views(in: none).contains { $0 is QrScannerView.PreviewView })
        let camera = host(QrScanner(label: "Scanner", onText: { _ in }, access: .granted).vettIDTheme())
        #expect(views(in: camera).contains { $0 is QrScannerView.PreviewView })
    }

    /// An invitation-sized payload is drawn with error correction M, one pixel per module, and reads back at the
    /// on-screen size.
    @Test func anInvitationSizedCodeReadsBackAtItsDrawnSize() throws {
        let hash = String(repeating: "A", count: 43), key = String(repeating: "B", count: 43)
        let payload = #"{"v":2,"t":"c","r":"https://relay.vettid.org","c":"01JABCDEFGHJKMNPQRSTVWXYZ0","#
            + #""h":"\#(hash)","k":"\#(key)","e":1791115800}"#
        let image = try #require(QrCode.image(payload))
        // Square, between the smallest symbol (21 modules) and the largest (177).
        #expect(image.width == image.height && image.width >= 21 && image.width <= 177)
        let rendered = ImageRenderer(content: QrCode(payload, accessibilityLabel: "QR").vettIDTheme(.dark))
        rendered.scale = 3
        let shown = try #require(rendered.cgImage)
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
        let features = detector.features(in: CIImage(cgImage: shown)).compactMap { $0 as? CIQRCodeFeature }
        #expect(features.first?.messageString == payload)
    }

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func views(in view: UIView) -> [UIView] { [view] + view.subviews.flatMap { views(in: $0) } }
}
