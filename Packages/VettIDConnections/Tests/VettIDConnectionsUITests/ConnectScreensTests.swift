#if os(iOS)
import CoreImage
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDConnections
@testable import VettIDConnectionsUI
import VettIDCrypto
import VettIDData
import VettIDUI

/// The connect flow's screens: their texts (vettid-android's, word for word), every state rendered, the camera states,
/// the QR code read back as the invitation, and the codes kept out of captures. Mirrors vettid-android's
/// `feature/connections` screen tests for these screens.
@MainActor
@Suite struct ConnectScreensTests {
    /// Every key of the package's `Localizable.xcstrings` resolves, in the built bundle, to its own non-empty text.
    @Test func everyStringResolves() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VettIDConnectionsUI/Resources/Localizable.xcstrings")
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let keys = try #require((doc["strings"] as? [String: Any])?.keys)
        #expect(keys.count == 149)
        let missing = "\u{0}missing"
        for key in keys {
            let text = Bundle.module.localizedString(forKey: key, value: missing, table: nil)
            #expect(!text.isEmpty && text != key && text != missing, "\(key)")
            #expect(key.hasPrefix("connections_"), "\(key)")
        }
    }

    @Test func theTextsAreAndroids() {
        #expect(ConnectStrings.inviteTitle == "Invite a connection")
        #expect(ConnectStrings.expiresIn(7, "3:00 PM") == "Expires in 7 min, at 3:00 PM")
        #expect(ConnectStrings.requestBody("Ada")
            == "Ada used your invitation. Compare this code with Ada: it must match the code on their phone.")
        #expect(ConnectStrings.shareText("https://relay.vettid.org/connect#x") == "Connect with me on VettID: open this link on a phone "
            + "with VettID (or paste it under Invite a connection, Paste an invitation link):\n\nhttps://relay.vettid.org/connect#x")
        #expect(ConnectStrings.existsTitle == "You're already connected")
        #expect(ConnectStrings.waitingPeer("Ada") == "Waiting for Ada to approve on their phone…")
        #expect(ConnectStrings.scanPermissionBody
            == "VettID uses the camera only to read the code; nothing is recorded or stored. You can paste a link instead.")
        #expect(ChooseTtl.label(.tenMinutes) == "In person · 10 minutes" && ChooseTtl.label(.sevenDays) == "Link · 7 days")
        #expect(PeerDeclineText.title(outgoing: true, name: "Ada") == "Ada declined your connection request")
        #expect(PeerDeclineText.title(outgoing: false, name: " ") == "Someone declined the connection")
        #expect(ConnectedScreen.body(nil) == "You can now message each other through your vaults.")
        #expect(ConnectedScreen.body("Ada") == "You and \u{2068}Ada\u{2069} can now message each other through your vaults.")
        #expect(AcceptScreen.endedBody(.expired) == "The request expired before both of you approved.")
        #expect(AcceptScreen.endedBody(.gone) == ConnectStrings.endedFailed)
    }

    @Test func theExpiryCountsWholeMinutes() {
        let exp = Date(timeIntervalSince1970: 1_791_115_800)
        let time = exp.formatted(date: .omitted, time: .shortened)
        #expect(ExpiryLine.text(exp: exp, now: exp.addingTimeInterval(-599)) == "Expires in 9 min, at \(time)")
        #expect(ExpiryLine.text(exp: exp, now: exp.addingTimeInterval(-600)) == "Expires in 10 min, at \(time)")
        #expect(ExpiryLine.text(exp: exp, now: exp.addingTimeInterval(5)) == "Expires in 0 min, at \(time)")
    }

    /// A copied link stays 5 minutes at most, never past the invitation's expiry.
    @Test func aCopiedLinkDoesNotStay() {
        let now = Date(timeIntervalSince1970: 1_791_115_200)
        #expect(ShowInvite.clipboardLifetime(exp: now.addingTimeInterval(7 * 86_400), now: now) == 300)
        #expect(ShowInvite.clipboardLifetime(exp: now.addingTimeInterval(90), now: now) == 90)
        #expect(ShowInvite.clipboardLifetime(exp: now.addingTimeInterval(-5), now: now) == 0)
    }

    @Test func everyInviteStateRenders() {
        for s in inviteStates() {
            #expect(height(InviteScreen(state: s, actions: InviteActions())) > 0, "\(s.step)")
        }
    }

    @Test func everyAcceptStateRenders() {
        let steps: [AcceptStep] = [.input, .accepting, .waiting, .compare, .approved, .connected, .exists, .ended]
        for step in steps {
            for fromLink in [false, true] {
                var s = AcceptState(input: fromLink ? "link" : "", fromLink: fromLink)
                s.step = step
                s.sas = "042817"
                s.name = fromLink ? "Ada Lovelace" : nil
                s.connectionID = "conn-1"
                s.end = fromLink ? .peerDeclined : .expired
                s.error = fromLink ? .inviteUnavailable : nil
                var actions = AcceptActions()
                if fromLink {
                    actions.onMessage = { _ in }
                    actions.onOpenConnection = { _ in }
                }
                #expect(height(AcceptScreen(state: s, actions: actions)) > 0, "\(step)")
            }
        }
    }

    @Test func theScanScreenHasEveryCameraState() {
        let access: [CameraAccess] = [.granted, .notDetermined, .denied, .restricted, .unavailable]
        for a in access {
            #expect(height(scan(access: a)) > 0, "\(a)")
        }
        #expect(height(ScanScreen(
            state: ScanState(problem: .inviteExpired), onBack: {}, onScanned: { _ in }, onPaste: {}, onLink: { _ in },
            camera: AnyView(Color.gray)
        )) > 0)
        #expect(height(AddConnectionSheet(onInvite: {}, onScan: {}, onPaste: {})) > 0)
        // Without a camera (the simulator, or restricted): the note, never a preview.
        for a in [CameraAccess.unavailable, .restricted] {
            #expect(!views(in: host(scan(access: a))).contains { $0 is QrScannerView.PreviewView })
        }
    }

    @Test func aScannedInvitationOpensTheAcceptScreenOnce() {
        var opened: [String] = []
        let link = "a-link"
        _ = host(ScanScreen(
            state: ScanState(link: link), onBack: {}, onScanned: { _ in }, onPaste: {}, onLink: { opened.append($0) },
            access: .unavailable
        ))
        #expect(opened == [link])
    }

    /// The invitation's QR code, as the screen draws it, reads back as the invitation (VAULT-MESSAGING §6.4).
    @Test func theDrawnCodeReadsBackAsTheInvitation() throws {
        let exp = Date().addingTimeInterval(600)
        let link = try InviteQr(
            kind: .connection, relay: "https://relay.vettid.org", claimID: "abcdefghijklmnopqrstuvwxyz",
            hash: [UInt8](repeating: 7, count: 32), key: [UInt8](repeating: 9, count: 32), exp: UInt64(exp.timeIntervalSince1970)
        ).link()
        let payload = try InviteLinks.qrPayload(link)
        let renderer = ImageRenderer(content: QrCode(payload, accessibilityLabel: ConnectStrings.qrLabel).vettIDTheme(.dark))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
        let read = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(read == [payload])
        guard case .ok(let back, _) = InviteLinks.parse(try #require(read.first)) else {
            Issue.record("the code did not read back as an invitation")
            return
        }
        #expect(back == link)
    }

    /// IOS-PLAN §6.4: the QR code, the link and the safety code on the secure layer, unless screenshots are allowed.
    @Test func theCodesAreKeptOutOfCaptures() {
        guard SecureLayer.isAvailable else { return }
        var showing = InviteState()
        showing.step = .showing
        showing.invite = InviteInfo(inviteID: "i", link: "link", qr: "{}", exp: Date().addingTimeInterval(600), remote: false)
        var request = InviteState()
        request.step = .request
        request.request = ConnectionRequest(pendingID: "p", sas: "042817", remote: false, name: "Ada", receivedAt: Date(), exp: nil)
        for s in [showing, request] {
            let protected = host(InviteScreen(state: s, actions: InviteActions()).environment(ScreenshotAllowance(onByDefault: false)))
            #expect(views(in: protected).contains(where: onSecureLayer), "\(s.step)")
            let allowed = host(InviteScreen(state: s, actions: InviteActions()).environment(ScreenshotAllowance(onByDefault: true)))
            #expect(!views(in: allowed).contains(where: onSecureLayer), "\(s.step)")
        }
        // A pasted or opened link: its field (a text field, with a canvas of its own) on the secure layer too.
        let link = AcceptState(input: "link", fromLink: true)
        let protected = host(AcceptScreen(state: link, actions: AcceptActions()).environment(ScreenshotAllowance(onByDefault: false)))
        let allowed = host(AcceptScreen(state: link, actions: AcceptActions()).environment(ScreenshotAllowance(onByDefault: true)))
        #expect(views(in: protected).filter(onSecureLayer).count > views(in: allowed).filter(onSecureLayer).count)
    }

    /// The secure text field's layout canvas, which ``SecureContainer`` hosts its content on (VettIDUI `SecureLayer`).
    private func onSecureLayer(_ v: UIView) -> Bool { String(describing: type(of: v)).contains("Canvas") }

    private func inviteStates() -> [InviteState] {
        let invite = InviteInfo(inviteID: "i", link: "link", qr: "{}", exp: Date().addingTimeInterval(600), remote: true)
        var request = ConnectionRequest(pendingID: "p", sas: "042817", remote: true, name: "Ada Lovelace", receivedAt: Date(), exp: nil)
        request.displayName = "Ada"
        let steps: [InviteStep] = [.choose, .showing, .request, .connecting, .connected, .expired, .declined]
        return steps.flatMap { step in
            [false, true].map { variant in
                var s = InviteState()
                s.step = step
                s.ttls = InviteTtl.allCases
                s.ttl = variant ? .oneDay : .tenMinutes
                s.invite = invite
                s.request = request
                s.autoApproved = variant
                s.connectionName = variant ? "Ada Lovelace" : nil
                s.error = variant ? .network : nil
                s.confirmBlock = variant && step == .request
                return s
            }
        }
    }

    private func scan(access: CameraAccess) -> ScanScreen {
        ScanScreen(state: ScanState(), onBack: {}, onScanned: { _ in }, onPaste: {}, onLink: { _ in }, access: access)
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func views(in view: UIView) -> [UIView] { [view] + view.subviews.flatMap { views(in: $0) } }
}
#endif
