#if os(iOS)
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDMedia
import VettIDSettings
@testable import VettIDSettingsUI
import VettIDUI

/// The shared profile and the camera-only profile photo (VAULT-MESSAGING §10.8): vettid-android's texts word for word,
/// the buttons each state offers, and every state rendered. Mirrors vettid-android `PhotoCaptureTest`'s screen part.
@MainActor
@Suite struct SharedProfileScreensTests {
    let account = AccountInfo(emailHint: "a***@example.org", state: "member", firstName: "Ada", lastName: "Lovelace")
    let profile = OwnProfile(
        version: 2, displayName: "", firstName: "Ada", lastName: "Lovelace", fingerprint: "9a1f bb7d 873e eafb 494b ef94 f072 7b25"
    )

    func shot(_ w: Int = 2048, _ h: Int = 1536) throws -> ShotImage {
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return try ShotImage.of(ctx.makeImage()!)
    }

    @Test func theTextsAreAndroids() {
        #expect(ProfileStrings.title == "Shared profile")
        #expect(ProfileStrings.photoTake == "Take a photo" && ProfileStrings.photoRetake == "Retake photo")
        #expect(ProfileStrings.photoNote == """
            Taken with this app's camera, cropped to the circle you chose and made smaller on this phone. It is not saved to \
            your gallery, and no location or camera details are sent.
            """)
        #expect(ProfileStrings.captureShutter == "Take photo" && ProfileStrings.captureToBack == "Use the rear camera")
        #expect(ProfileStrings.captureUse == "Use photo" && ProfileStrings.captureRetake == "Retake")
        #expect(ProfileStrings.cropZoomState("1.5") == "Zoomed 1.5 times")
        #expect(CropReview.zoomState(1.25) == "Zoomed 1.2 times" || CropReview.zoomState(1.25) == "Zoomed 1.3 times")
        #expect(ProfileStrings.privacyProfileBody == "Your account name, display name and the items you tag @profile")
        // The iPhone's own: its Settings page has the Camera switch itself.
        #expect(ProfileStrings.capturePermissionBlocked
            == "The camera is turned off for VettID. To take your profile photo, open the app's settings and turn on Camera.")
    }

    // MARK: - The capture screen

    @Test func theLiveCameraOffersTheShutterAndTheRearCamera() {
        let s = PhotoCaptureState(access: .granted)
        #expect(CapturePrimary.of(s) == .shutter && CaptureSecondary.of(s) == .toBack)
        var back = s
        back.lens = .back
        #expect(CaptureSecondary.of(back) == .toFront)
        var one = s
        one.back = false
        #expect(CaptureSecondary.of(one) == nil, "no switch on a phone with one camera")
        #expect(height(PhotoCaptureContent(state: s) { FakeCameraPreview() }) > 0)
    }

    @Test func theReviewOffersRetakeAndUse() throws {
        let s = PhotoCaptureState(access: .granted, step: .review, shot: try shot())
        #expect(CapturePrimary.of(s) == .use && CaptureSecondary.of(s) == .retake)
        #expect(height(PhotoCaptureContent(state: s) { FakeCameraPreview() }) > 0)
    }

    @Test func aRefusalIsExplainedAndABlockedCameraOpensTheSettings() {
        #expect(CapturePrimary.of(PhotoCaptureState(access: .ask)) == .allow)
        #expect(CapturePrimary.of(PhotoCaptureState(access: .blocked)) == .openSettings)
        #expect(PhotoCaptureScreen.access(.notDetermined) == .ask)
        #expect(PhotoCaptureScreen.access(.denied) == .blocked && PhotoCaptureScreen.access(.restricted) == .blocked)
        #expect(PhotoCaptureScreen.access(.granted) == .granted && PhotoCaptureScreen.access(.unavailable) == nil)
        for a in [PhotoCaptureAccess.ask, .blocked] {
            #expect(height(PhotoCaptureContent(state: PhotoCaptureState(access: a)) { FakeCameraPreview() }) > 0)
        }
    }

    @Test func aPhoneWithoutACameraIsTold() {
        let s = PhotoCaptureState(access: .granted, noCamera: true)
        #expect(CapturePrimary.of(s) == nil && CaptureSecondary.of(s) == nil)
        #expect(height(PhotoCaptureContent(state: s) { FakeCameraPreview() }) > 0)
    }

    /// VoiceOver moves the shot without a drag: one action per direction it can still move in.
    @Test func theReviewsMovesAreOfferedOnlyWhereTheShotCanMove() {
        #expect(CropReview.moves(Framing(), 2048, 1536).map(\.label) == ["Show more to the left", "Show more to the right"])
        #expect(CropReview.moves(Framing(zoom: 2), 2048, 1536).count == 4)
        let corner = CropReview.moves(Framing(zoom: 2, centreX: 0, centreY: 0), 2048, 1536)
        #expect(corner.map(\.label) == ["Show more to the right", "Show more below"])
    }

    // MARK: - The shared profile

    @Test func theSharedProfileOffersToTakeOrRetakeAPhotoAndToRemoveIt() {
        let none = SharedProfileState(account: account, profile: profile)
        #expect(SharedProfilePhotoCard.status(none) == "No photo. Connections see your initial.")
        var shared = profile
        shared.photo = "/9j/4AAQ"
        let withPhoto = SharedProfileState(account: account, profile: shared)
        #expect(SharedProfilePhotoCard.status(withPhoto) == "Every connection sees this photo.")
        var preview = withPhoto
        preview.pendingPhoto = PendingPhoto.of("/9j/4AAQ")
        #expect(SharedProfilePhotoCard.status(preview) == "Preview: save it to share it with every connection.")
        preview.photoBusy = true
        #expect(SharedProfilePhotoCard.status(preview) == "Working…")
        for s in [none, withPhoto, preview] {
            #expect(height(SharedProfileContent(state: s)) > 0)
        }
    }

    @Test func everyStateOfTheSharedProfileRenders() {
        var s = SharedProfileState(account: account, profile: profile)
        s.saved = true
        s.photoUnreadable = true
        s.photoSaved = true
        s.error = .network
        #expect(height(SharedProfileContent(state: s)) > 0)
        s.displayName = String(repeating: "é", count: 65)
        s.edited = true
        #expect(height(SharedProfileContent(state: s)) > 0)
        #expect(height(SharedProfileContent(state: SharedProfileState())) > 0, "before the profile is read")
    }

    /// A `limit` error names its limit; any other failure its own text.
    @Test func aLimitIsSaidWithItsBound() {
        let text = SharedProfileContent.errorText(.limit, VaultLimit("profile_size", max: 196_608, size: 200_000), timeScale: 1)
        #expect(text.contains("192") && text.contains("196"))
        #expect(SharedProfileContent.errorText(.network, nil, timeScale: 1) == FailureKind.network.message)
    }

    @Test func theSharedProfileGlyphIsTheIdCard() {
        #expect(sharedProfileSymbol == .badge)
        #expect(UIImage(systemName: VettIDSymbol.badge.rawValue) != nil)
    }

    @Test func settingsHasThePrivacySection() {
        #expect(ProfileStrings.sectionPrivacy == "Privacy" && ProfileStrings.privacyProfile == "Shared profile")
        #expect(height(SettingsContent(state: SettingsState(account: account), accountPhoto: UIImage(systemName: "person"))) > 0)
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }
}
#endif
