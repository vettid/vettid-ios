import CoreImage
import Foundation
import Testing
import UIKit
@testable import VettIDUI

/// Mirrors vettid-android `InitialTest`.
struct InitialTests {
    @Test func firstLetterUpperCased() { #expect(initialOf("mesmerverse") == "M") }
    @Test func skipsLeadingPunctuationAndSpace() { #expect(initialOf("  @alice") == "A") }
    @Test func blankIsQuestionMark() { #expect(initialOf("   ") == "?") }
    @Test func nonLatin() { #expect(initialOf("élodie") == "É") }
}

/// The bell's label and badge (ANDROID-PLAN 0.1.23): no badge at 0, the count, "99+", the urgent wording.
/// Mirrors vettid-android `NotificationBellTest` (labels; the views are checked in the gallery).
@MainActor
struct NotificationBellTests {
    @Test func labels() {
        #expect(NotificationBell(unread: 0, urgent: false) {}.accessibilityLabel == "Notifications")
        #expect(NotificationBell(unread: 1, urgent: false) {}.accessibilityLabel == "Notifications, 1 unread")
        #expect(NotificationBell(unread: 3, urgent: false) {}.accessibilityLabel == "Notifications, 3 unread")
        #expect(NotificationBell(unread: 1, urgent: true) {}.accessibilityLabel == "Notifications, 1 unread, urgent")
        #expect(NotificationBell(unread: 2, urgent: true) {}.accessibilityLabel == "Notifications, 2 unread, one is urgent")
    }

    @Test func badgeText() {
        #expect(VettIDUI.badgeText(3) == "3")
        #expect(VettIDUI.badgeText(99) == "99")
        #expect(VettIDUI.badgeText(140) == "99+")
    }
}

/// The package's strings come from its catalog, plurals included.
struct StringsTests {
    @Test func pluralsAndFormats() {
        #expect(UIStrings.badgeCount(1) == "1 pending")
        #expect(UIStrings.tagsMoreDescription(1) == "1 more tag")
        #expect(UIStrings.tagsMoreDescription(4) == "4 more tags")
        #expect(UIStrings.tagsMore(4) == "+4")
        #expect(UIStrings.account("Mesmer") == "Account: Mesmer")
        #expect(UIStrings.favoriteAdd("Alice") == "Add Alice to favourites")
        #expect(UIStrings.safetyCode("0 4 2 8 1 7") == "Safety code 0 4 2 8 1 7")
    }
}

/// Mirrors vettid-android `SafetyCode` grouping.
@MainActor
struct SafetyCodeTests {
    @Test func twoGroupsOfThree() {
        #expect(SafetyCode.groups("042817") == ["042", "817"])
        #expect(SafetyCode.groups("12345") == ["123", "45"])
    }
}

/// A QR code reads back as what it encodes. Mirrors vettid-android `QrCodeTest`.
@MainActor
struct QrCodeTests {
    @Test func encodesAndReadsBack() throws {
        let payload = #"{"v":2,"t":"c","r":"https://relay.example","c":"abcdefghijklmnopqrstuvwxyz","e":1791100000}"#
        let image = try #require(QrCode.image(payload))
        // Scale up with a white quiet zone, as the card draws it, then detect.
        let ci = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let framed = ci.composited(over: CIImage(color: .white).cropped(to: ci.extent.insetBy(dx: -64, dy: -64)))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
        let features = detector.features(in: framed).compactMap { $0 as? CIQRCodeFeature }
        #expect(features.first?.messageString == payload)
        // No generator margin: the corners are dark modules (finder patterns).
        #expect(image.width == image.height)
    }
}

/// Profile photos are read defensively (VAULT-MESSAGING §10.8). Mirrors the decoding half of vettid-android
/// `ProfilePhotosTest`.
struct ProfilePhotosTests {
    private func png(_ side: Int) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: {
            let f = UIGraphicsImageRendererFormat()
            f.scale = 1
            return f
        }()).pngData { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    @Test func aPngDecodes() throws {
        let data = png(64)
        #expect(ProfilePhotos.isPNG(data))
        #expect(ProfilePhotos.decode(data.base64EncodedString()) != nil)
    }

    @Test func aJpegDecodes() throws {
        let jpeg = try #require(UIImage(data: png(64))?.jpegData(compressionQuality: 0.8))
        #expect(ProfilePhotos.isJPEG(jpeg))
        #expect(ProfilePhotos.decode(jpeg.base64EncodedString()) != nil)
    }

    @Test func badPhotosFallBackToTheInitial() {
        #expect(ProfilePhotos.decode(nil) == nil)
        #expect(ProfilePhotos.decode("") == nil)
        #expect(ProfilePhotos.decode("not base64 !!!") == nil)
        // Not a JPEG or PNG.
        #expect(ProfilePhotos.decode(Data(repeating: 1, count: 100).base64EncodedString()) == nil)
        // A JPEG header followed by garbage.
        let fake = Data([0xFF, 0xD8, 0xFF]) + Data(repeating: 7, count: 200)
        #expect(ProfilePhotos.decode(fake.base64EncodedString()) == nil)
        // Over the size limit: refused unread.
        let big = Data([0xFF, 0xD8, 0xFF]) + Data(count: ProfilePhotos.maxBytes)
        #expect(ProfilePhotos.decode(big.base64EncodedString()) == nil)
    }
}

/// A bubble's links (VAULT-MESSAGING §10.5 "Links"): a tapped link goes to the caller, never to the system; the link runs
/// are the ones VoiceOver offers.
@MainActor
struct BubbleLinksTests {
    @Test func aTappedLinkGoesToTheCaller() throws {
        var opened: [URL] = []
        let links = BubbleLinks(name: { $0.host() ?? "" }) { opened.append($0) }
        let url = try #require(URL(string: "https://example.org/a"))
        BubbleLinks.intercepting(links)(url)
        #expect(opened == [url])
        // Without links nothing opens, and the system is not asked either.
        BubbleLinks.intercepting(nil)(url)
        #expect(opened == [url])
    }

    @Test func theLinkRunsAreFound() throws {
        var text = AttributedString("see ")
        var link = AttributedString("https://example.org")
        link.link = try #require(URL(string: "https://example.org"))
        text += link
        #expect(MessageBubble.linkURLs(text).map(\.absoluteString) == ["https://example.org"])
        #expect(MessageBubble.linkURLs(AttributedString("plain")).isEmpty)
    }
}
