import Foundation

/// The shared profile's and the profile photo's texts (vettid-android `feature/settings` `strings_profile.xml` and the
/// Privacy section of `strings.xml`, word for word, under the same keys); `ios_settings_photo_capture_permission_blocked` is
/// the iPhone's own (Android's names its phone's Permissions screen; chosen; not in the spec).
enum ProfileStrings {
    static var title: String {
        String(localized: "settings_profile_title", defaultValue: "Shared profile", bundle: .module)
    }

    static var body: String {
        String(
            localized: "settings_profile_body",
            defaultValue: """
                What every connection sees of you: the name on your VettID account and your vault key, always; a display \
                name and the items you tag @profile, if you add them.
                """,
            bundle: .module
        )
    }

    static var names: String {
        String(localized: "settings_profile_names", defaultValue: "VettID account name", bundle: .module)
    }

    static var namesNone: String {
        String(localized: "settings_profile_names_none", defaultValue: "Not received from your vault yet", bundle: .module)
    }

    static var namesNote: String {
        String(
            localized: "settings_profile_names_note",
            defaultValue: """
                Every connection sees this name. VettID does not check it against any ID.
                """,
            bundle: .module
        )
    }

    static var changeName: String {
        String(localized: "settings_profile_change_name", defaultValue: "Change name", bundle: .module)
    }

    static var displayName: String {
        String(localized: "settings_profile_display_name", defaultValue: "Display name (optional)", bundle: .module)
    }

    static var displayNameHint: String {
        String(
            localized: "settings_profile_display_name_hint",
            defaultValue: """
                Shown to your connections next to your name, for example a nickname. Leave it empty for none.
                """,
            bundle: .module
        )
    }

    static var displayNameTooLong: String {
        String(localized: "settings_profile_display_name_too_long", defaultValue: "At most 128 bytes.", bundle: .module)
    }

    static var save: String {
        String(localized: "settings_profile_save", defaultValue: "Save display name", bundle: .module)
    }

    static var saved: String {
        String(
            localized: "settings_profile_saved",
            defaultValue: """
                Display name saved. Your connections get it with your profile.
                """,
            bundle: .module
        )
    }

    static var key: String {
        String(localized: "settings_profile_key", defaultValue: "Your vault key fingerprint", bundle: .module)
    }

    static var keyNote: String {
        String(
            localized: "settings_profile_key_note",
            defaultValue: """
                Your connections see this fingerprint for your vault. It changes only when your vault rotates its key.
                """,
            bundle: .module
        )
    }

    static var error: String {
        String(localized: "settings_profile_error", defaultValue: "Could not save", bundle: .module)
    }

    static var photo: String {
        String(localized: "settings_profile_photo", defaultValue: "Profile photo", bundle: .module)
    }

    static var photoNone: String {
        String(localized: "settings_profile_photo_none", defaultValue: "No photo. Connections see your initial.", bundle: .module)
    }

    static var photoShared: String {
        String(localized: "settings_profile_photo_shared", defaultValue: "Every connection sees this photo.", bundle: .module)
    }

    static var photoPreview: String {
        String(
            localized: "settings_profile_photo_preview",
            defaultValue: """
                Preview: save it to share it with every connection.
                """,
            bundle: .module
        )
    }

    static var photoWorking: String {
        String(localized: "settings_profile_photo_working", defaultValue: "Working…", bundle: .module)
    }

    static var photoTake: String {
        String(localized: "settings_profile_photo_take", defaultValue: "Take a photo", bundle: .module)
    }

    static var photoRetake: String {
        String(localized: "settings_profile_photo_retake", defaultValue: "Retake photo", bundle: .module)
    }

    static var photoSave: String {
        String(localized: "settings_profile_photo_save", defaultValue: "Save photo", bundle: .module)
    }

    static var photoDiscard: String {
        String(localized: "settings_profile_photo_discard", defaultValue: "Cancel", bundle: .module)
    }

    static var photoRemove: String {
        String(localized: "settings_profile_photo_remove", defaultValue: "Remove photo", bundle: .module)
    }

    static var photoRemoveTitle: String {
        String(localized: "settings_profile_photo_remove_title", defaultValue: "Remove your photo?", bundle: .module)
    }

    static var photoRemoveBody: String {
        String(localized: "settings_profile_photo_remove_body", defaultValue: "Your connections see your initial instead.", bundle: .module)
    }

    static var photoUnreadable: String {
        String(
            localized: "settings_profile_photo_unreadable",
            defaultValue: """
                That photo could not be used. Take another one.
                """,
            bundle: .module
        )
    }

    static var photoSaved: String {
        String(localized: "settings_profile_photo_saved", defaultValue: "Photo saved. Your connections receive it.", bundle: .module)
    }

    static var photoNote: String {
        String(
            localized: "settings_profile_photo_note",
            defaultValue: """
                Taken with this app's camera, cropped to the circle you chose and made smaller on this phone. It is not \
                saved to your gallery, and no location or camera details are sent.
                """,
            bundle: .module
        )
    }

    static var captureTitle: String {
        String(localized: "settings_photo_capture_title", defaultValue: "Take your photo", bundle: .module)
    }

    static var captureBody: String {
        String(
            localized: "settings_photo_capture_body",
            defaultValue: """
                Centre your face in the square. Every connection sees this photo.
                """,
            bundle: .module
        )
    }

    static var captureShutter: String {
        String(localized: "settings_photo_capture_shutter", defaultValue: "Take photo", bundle: .module)
    }

    static var captureToBack: String {
        String(localized: "settings_photo_capture_to_back", defaultValue: "Use the rear camera", bundle: .module)
    }

    static var captureToFront: String {
        String(localized: "settings_photo_capture_to_front", defaultValue: "Use the front camera", bundle: .module)
    }

    static var captureReviewTitle: String {
        String(localized: "settings_photo_capture_review_title", defaultValue: "Use this photo?", bundle: .module)
    }

    static var captureReviewBody: String {
        String(
            localized: "settings_photo_capture_review_body",
            defaultValue: """
                Pinch or use the zoom controls, and drag, until your face fills the circle. Your connections see what is \
                inside it.
                """,
            bundle: .module
        )
    }

    static var captureUse: String {
        String(localized: "settings_photo_capture_use", defaultValue: "Use photo", bundle: .module)
    }

    static var captureRetake: String {
        String(localized: "settings_photo_capture_retake", defaultValue: "Retake", bundle: .module)
    }

    static var captureAllow: String {
        String(localized: "settings_photo_capture_allow", defaultValue: "Allow camera", bundle: .module)
    }

    static var captureOpenSettings: String {
        String(localized: "settings_photo_capture_open_settings", defaultValue: "Open settings", bundle: .module)
    }

    static var capturePermissionTitle: String {
        String(localized: "settings_photo_capture_permission_title", defaultValue: "Camera needed", bundle: .module)
    }

    static var capturePermissionBody: String {
        String(
            localized: "settings_photo_capture_permission_body",
            defaultValue: """
                Your profile photo is taken with the camera, in this app. Allow the camera to take it.
                """,
            bundle: .module
        )
    }

    static var capturePermissionBlocked: String {
        String(
            localized: "ios_settings_photo_capture_permission_blocked",
            defaultValue: """
                The camera is turned off for VettID. To take your profile photo, open the app's settings and turn on \
                Camera.
                """,
            bundle: .module
        )
    }

    static var captureNoCameraTitle: String {
        String(localized: "settings_photo_capture_no_camera_title", defaultValue: "No camera", bundle: .module)
    }

    static var captureNoCameraBody: String {
        String(
            localized: "settings_photo_capture_no_camera_body",
            defaultValue: """
                This phone has no camera VettID can use, so a profile photo cannot be taken. Connections see your \
                initial.
                """,
            bundle: .module
        )
    }

    static var captureFailed: String {
        String(localized: "settings_photo_capture_failed", defaultValue: "The photo could not be taken. Try again.", bundle: .module)
    }

    static var cropFrame: String {
        String(localized: "settings_photo_crop_frame", defaultValue: "Your photo in the round frame", bundle: .module)
    }

    static func cropZoomState(_ s: String) -> String {
        String(localized: "settings_photo_crop_zoom_state", defaultValue: "Zoomed \(s) times", bundle: .module)
    }

    static var cropZoom: String {
        String(localized: "settings_photo_crop_zoom", defaultValue: "Zoom", bundle: .module)
    }

    static var cropZoomIn: String {
        String(localized: "settings_photo_crop_zoom_in", defaultValue: "Zoom in", bundle: .module)
    }

    static var cropZoomOut: String {
        String(localized: "settings_photo_crop_zoom_out", defaultValue: "Zoom out", bundle: .module)
    }

    static var cropReset: String {
        String(localized: "settings_photo_crop_reset", defaultValue: "Reset", bundle: .module)
    }

    static var cropShowLeft: String {
        String(localized: "settings_photo_crop_show_left", defaultValue: "Show more to the left", bundle: .module)
    }

    static var cropShowRight: String {
        String(localized: "settings_photo_crop_show_right", defaultValue: "Show more to the right", bundle: .module)
    }

    static var cropShowUp: String {
        String(localized: "settings_photo_crop_show_up", defaultValue: "Show more above", bundle: .module)
    }

    static var cropShowDown: String {
        String(localized: "settings_photo_crop_show_down", defaultValue: "Show more below", bundle: .module)
    }

    static var captureNote: String {
        String(
            localized: "settings_photo_capture_note",
            defaultValue: """
                The photo stays in this app until you use it: it is never saved to your gallery.
                """,
            bundle: .module
        )
    }

    static var sectionPrivacy: String {
        String(localized: "settings_section_privacy", defaultValue: "Privacy", bundle: .module)
    }

    static var privacyProfile: String {
        String(localized: "settings_privacy_profile", defaultValue: "Shared profile", bundle: .module)
    }

    static var privacyProfileBody: String {
        String(
            localized: "settings_privacy_profile_body",
            defaultValue: """
                Your account name, display name and the items you tag @profile
                """,
            bundle: .module
        )
    }
}
