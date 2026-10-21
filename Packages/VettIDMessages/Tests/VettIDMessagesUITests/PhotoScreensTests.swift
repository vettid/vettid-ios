#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDMedia
import VettIDMessages
@testable import VettIDMessagesUI
import VettIDUI

/// The photo screens (ANDROID-PLAN "Photo attachments"): their texts (vettid-android's, word for word), the bubble's
/// spoken label and line, the placeholder's shape, every state rendered (the composer's button, the bubbles, the camera,
/// the prepared photos, the viewer), the saved name, and the share item that gives nothing once withdrawn. Mirrors
/// vettid-android `PhotoLabelTest` and the screen part of `PhotoPrivacyTest`.
@MainActor
@Suite struct PhotoScreensTests {
    static func photo(
        _ id: String, outgoing: Bool = false, state: AttachmentState, reason: String? = nil, text: String = ""
    ) -> MessageInfo {
        MessageInfo(
            connectionID: "c1", messageID: id, outgoing: outgoing, text: text, sentAt: Date(),
            attachment: AttachmentInfo(attID: "a\(id)", state: state, reason: reason, width: 2_560, height: 1_920)
        )
    }

    @Test func theTextsAreAndroids() {
        #expect(MessagesStrings.photoAdd == "Add a photo" && MessagesStrings.photoTake == "Take a photo")
        #expect(MessagesStrings.photoChoose == "Choose photos" && MessagesStrings.photoShutter == "Take photo")
        #expect(MessagesStrings.photoStripped == "Location and camera details are removed before sending")
        #expect(MessagesStrings.photoTo("Sam") == "Photo for Sam")
        #expect(MessagesStrings.photoPreview(1, 3) == "Photo 1 of 3, as it will be sent")
        #expect(MessagesStrings.photoProgress(2, 5) == "2 of 5 sent")
        #expect(MessagesStrings.photoFailedPicks(1) == "1 picked picture could not be used.")
        #expect(MessagesStrings.photoFailedPicks(3) == "3 picked pictures could not be used.")
        #expect(MessagesStrings.photoMailboxFull == "Your vault can't take more photos right now. Try again later.")
        #expect(MessagesStrings.photoPeerNoPhotos("Sam") == "Not delivered: Sam's VettID can't receive photos yet")
        #expect(MessagesStrings.photoInWithdrawn("Sam") == "Not received: Sam's vault can no longer send it")
        let leaves = "This puts the photo outside VettID. Other apps on this phone, and anyone you share it with, can keep it."
        #expect(MessagesStrings.photoLeaves == leaves)
        #expect(MessagesStrings.photoCdIn("Sam") == "Photo from Sam" && MessagesStrings.photoCdOut == "Photo you sent")
        // iOS saves to the Photos library (chosen; not in the spec).
        #expect(MessagesStrings.photoSaved == "Saved to Photos")
    }

    /// A photo message's spoken label leaves out an empty caption and an absent state (no stray ". ").
    @Test func theLabelLeavesOutWhatIsNotThere() {
        #expect(photoLabel("Photo you sent", "", "Delivered") == "Photo you sent. Delivered")
        #expect(photoLabel("Photo from Ann", "", "") == "Photo from Ann")
        #expect(photoLabel("Photo from Ann", nil, nil) == "Photo from Ann")
        #expect(photoLabel("Photo from Ann", "   ", nil) == "Photo from Ann")
        #expect(photoLabel("Photo you sent", "At the lake", "Delivered") == "Photo you sent. At the lake. Delivered")
        #expect(photoLabel("Photo from Ann", "At the lake", nil) == "Photo from Ann. At the lake")
    }

    @Test func everyLineAndProblemHasItsText() {
        for t in PhotoStatus.Text.allCases {
            let text = photoStatusText(PhotoStatus(t), "Sam")
            #expect(!text.isEmpty, "\(t)")
            if [.peerNoPhotos, .inRate, .inWithdrawn].contains(t) { #expect(text.contains("Sam"), "\(t)") }
        }
        #expect(Set(PhotoProblem.allCases.map(photoProblemText)).count == PhotoProblem.allCases.count)
    }

    /// The placeholder takes the claimed shape within 1:2 and 2:1; a claim out of bounds is square.
    @Test func thePlaceholderIsClamped() {
        func r(_ w: Int, _ h: Int) -> CGFloat { PhotoBubble.ratio(AttachmentInfo(attID: "a", state: .stored, width: w, height: h)) }
        #expect(r(2_560, 1_920) == CGFloat(2_560) / 1_920 && r(8_000, 100) == 2 && r(100, 8_000) == 0.5)
        #expect(r(0, 100) == 1 && r(9_000, 100) == 1)
    }

    @Test func aSavedPhotoIsNamedByTheTimeAndItsSniffedType() {
        let at = Date(timeIntervalSince1970: 1_791_115_200)
        let name = PhotoExport.fileName(.png, at: at)
        #expect(name.hasPrefix("VettID_") && name.hasSuffix(".png") && name.count == "VettID_20261005_000000.png".count)
    }

    /// The share sheet's item gives the bytes while offered and nothing once a clear withdrew the offer.
    @Test func theShareItemGivesNothingOnceWithdrawn() throws {
        let token = SharedPhotos.shared.offer([0xFF, 0xD8, 0xFF, 1], type: .jpeg)
        let item = SharedPhotoItem(token: token, type: .jpeg)
        let vc = UIActivityViewController(activityItems: [], applicationActivities: nil)
        #expect(item.activityViewController(vc, itemForActivityType: nil) as? Data == Data([0xFF, 0xD8, 0xFF, 1]))
        #expect(item.activityViewController(vc, dataTypeIdentifierForActivityType: nil) == "public.jpeg")
        SharedPhotos.shared.clear()
        #expect(item.activityViewController(vc, itemForActivityType: nil) == nil)
    }

    @Test func everyPhotoStateRenders() throws {
        let prepared = try Photos.prepare(Self.picture())
        var base = ConversationState(connectionID: "c1")
        base.loading = false
        base.connection = MessagesScreensTests.connection("c1")
        base.photosAvailable = true
        base.messages = [
            Self.photo("p1", outgoing: true, state: .preparing, text: "At the lake"), Self.photo("p2", outgoing: true, state: .delivered),
            Self.photo("p3", outgoing: true, state: .failed, reason: "unsupported"), Self.photo("p4", state: .fetching),
            Self.photo("p5", state: .stored), Self.photo("p6", state: .failed, reason: "withdrawn:deleted"),
        ]
        var drafts: [PhotoDraft] = [PhotoDraft(preparing: true), PhotoDraft(photos: [prepared]), PhotoDraft(problem: .tooLarge)]
        var sending = PhotoDraft(photos: [prepared, prepared], failedPicks: 1)
        sending.sending = true
        sending.inFlight = true
        sending.sent = 1
        var retry = PhotoDraft(photos: [prepared])
        retry.retry = true
        retry.problem = .noAnswer
        drafts += [sending, retry]
        var actions = ConversationActions()
        actions.photos.thumbnail = { _ in prepared.thumb.copy() }
        #expect(height(ConversationScreen(state: base, actions: actions)) > 0)
        _ = host(ConversationScreen(state: base, actions: actions))
        for d in drafts {
            #expect(height(PhotoDraftOverlay(draft: d, name: "Ada", actions: PhotoActions())) > 0, "\(d)")
        }
        var capturing = base
        capturing.capturing = true
        _ = host(ConversationScreen(state: capturing, actions: actions))
        #expect(height(PhotoCaptureOverlay(actions: PhotoActions())) > 0)
    }

    @Test func everyViewerStateRenders() {
        var shown = PhotoViewerState(loading: false)
        shown.photo = FetchedPhoto(bytes: [0xFF, 0xD8, 0xFF, 0xE0], type: .jpeg)
        shown.name = "x.png"
        var failed = PhotoViewerState(loading: false)
        failed.error = .other
        failed.problem = .bad
        var network = PhotoViewerState(loading: false)
        network.error = .network
        for s in [PhotoViewerState(), shown, failed, network] {
            #expect(height(PhotoViewerScreen(state: s, onBack: {}, onRetry: {})) > 0, "\(s)")
            _ = host(PhotoViewerScreen(state: s, onBack: {}, onRetry: {}))
        }
    }

    static func picture() -> CGImage {
        let ctx = CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        return ctx.makeImage()!
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
}
#endif
