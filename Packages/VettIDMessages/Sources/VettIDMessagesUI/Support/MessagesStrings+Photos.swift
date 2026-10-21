import Foundation

// The photo texts (vettid-android `feature/messages` `strings.xml`, word for word, under its string names), except
// "Saved to Photos": iOS saves to the Photos library, where vettid-android says "Saved to Pictures/VettID" (chosen; not
// in the spec).
extension MessagesStrings {
    static var photoAdd: String { String(localized: "messages_photo_add", defaultValue: "Add a photo", bundle: .module) }

    static var photoTake: String { String(localized: "messages_photo_take", defaultValue: "Take a photo", bundle: .module) }

    static var photoChoose: String { String(localized: "messages_photo_choose", defaultValue: "Choose photos", bundle: .module) }

    static var photoCloseCamera: String {
        String(localized: "messages_photo_close_camera", defaultValue: "Close the camera", bundle: .module)
    }

    static var photoSwitchCamera: String {
        String(localized: "messages_photo_switch_camera", defaultValue: "Switch camera", bundle: .module)
    }

    static var photoReview: String { String(localized: "messages_photo_review", defaultValue: "The photo you took", bundle: .module) }

    static var photoNoCamera: String {
        String(localized: "messages_photo_no_camera", defaultValue: "No camera could be opened on this phone.", bundle: .module)
    }

    static var photoRetake: String { String(localized: "messages_photo_retake", defaultValue: "Retake", bundle: .module) }

    static var photoUse: String { String(localized: "messages_photo_use", defaultValue: "Use photo", bundle: .module) }

    static var photoShutter: String { String(localized: "messages_photo_shutter", defaultValue: "Take photo", bundle: .module) }

    static var photoCameraPermission: String {
        String(
            localized: "messages_photo_camera_permission",
            defaultValue: "VettID needs the camera to take a photo here. The photo stays in memory until you send it.",
            bundle: .module
        )
    }

    static var photoCameraAllow: String {
        String(localized: "messages_photo_camera_allow", defaultValue: "Allow the camera", bundle: .module)
    }

    static var photoCameraSettings: String {
        String(localized: "messages_photo_camera_settings", defaultValue: "Open settings", bundle: .module)
    }

    static var photoStripped: String {
        String(
            localized: "messages_photo_stripped",
            defaultValue: "Location and camera details are removed before sending",
            bundle: .module
        )
    }

    static var photoCaption: String { String(localized: "messages_photo_caption", defaultValue: "Add a caption", bundle: .module) }

    static var photoCancel: String { String(localized: "messages_photo_cancel", defaultValue: "Cancel", bundle: .module) }

    static var photoRetry: String { String(localized: "messages_photo_retry", defaultValue: "Retry", bundle: .module) }

    static var photoTooLarge: String {
        String(localized: "messages_photo_too_large", defaultValue: "This photo is too large to send", bundle: .module)
    }

    static var photoUnsupported: String {
        String(
            localized: "messages_photo_unsupported",
            defaultValue: "This picture cannot be sent: the phone cannot read its format.",
            bundle: .module
        )
    }

    static var photoUnreadable: String {
        String(localized: "messages_photo_unreadable", defaultValue: "This picture could not be read.", bundle: .module)
    }

    static var photoMailboxFull: String {
        String(
            localized: "messages_photo_mailbox_full",
            defaultValue: "Your vault can't take more photos right now. Try again later.",
            bundle: .module
        )
    }

    static var photoVaultFull: String {
        String(
            localized: "messages_photo_vault_full",
            defaultValue: "Your vault is full. Delete messages with photos to make room.",
            bundle: .module
        )
    }

    static var photoNoAnswer: String {
        String(
            localized: "messages_photo_no_answer",
            defaultValue: "Your vault did not answer. Retry sends the same photo again, without uploading it again.",
            bundle: .module
        )
    }

    static var photoNotSent: String {
        String(localized: "messages_photo_not_sent", defaultValue: "This photo couldn't be sent", bundle: .module)
    }

    static var photoSending: String { String(localized: "messages_photo_sending", defaultValue: "Sending", bundle: .module) }

    static var photoDelivered: String { String(localized: "messages_photo_delivered", defaultValue: "Delivered", bundle: .module) }

    static var photoReceiving: String { String(localized: "messages_photo_receiving", defaultValue: "Receiving…", bundle: .module) }

    static var photoNotSentBubble: String {
        String(localized: "messages_photo_not_sent_bubble", defaultValue: "Not sent: this photo couldn't be sent", bundle: .module)
    }

    static var photoUnconfirmed: String {
        String(localized: "messages_photo_unconfirmed", defaultValue: "Not delivered: not confirmed after 7 days", bundle: .module)
    }

    static var photoNotDelivered: String {
        String(localized: "messages_photo_not_delivered", defaultValue: "Not delivered: couldn't be delivered", bundle: .module)
    }

    static var photoInFull: String {
        String(localized: "messages_photo_in_full", defaultValue: "Not received: your vault is full", bundle: .module)
    }

    static var photoInType: String {
        String(localized: "messages_photo_in_type", defaultValue: "This file type isn't supported", bundle: .module)
    }

    static var photoInNever: String {
        String(localized: "messages_photo_in_never", defaultValue: "Not received: it never arrived", bundle: .module)
    }

    static var photoCdOut: String { String(localized: "messages_photo_cd_out", defaultValue: "Photo you sent", bundle: .module) }

    static var photoViewerCd: String { String(localized: "messages_photo_viewer_cd", defaultValue: "Photo", bundle: .module) }

    static var photoSave: String { String(localized: "messages_photo_save", defaultValue: "Save to phone", bundle: .module) }

    static var photoShare: String { String(localized: "messages_photo_share", defaultValue: "Share", bundle: .module) }

    static var photoLeaves: String {
        String(
            localized: "messages_photo_leaves",
            defaultValue: "This puts the photo outside VettID. Other apps on this phone, and anyone you share it with, can keep it.",
            bundle: .module
        )
    }

    static var photoContinue: String { String(localized: "messages_photo_continue", defaultValue: "Continue", bundle: .module) }

    static var photoSaved: String { String(localized: "messages_photo_saved", defaultValue: "Saved to Photos", bundle: .module) }

    static var photoSaveFailed: String {
        String(localized: "messages_photo_save_failed", defaultValue: "The photo could not be saved.", bundle: .module)
    }

    static var photoBad: String {
        String(
            localized: "messages_photo_bad",
            defaultValue: "This photo could not be opened: it did not pass its checks.",
            bundle: .module
        )
    }

    static var photoUnavailable: String {
        String(localized: "messages_photo_unavailable", defaultValue: "This photo is not in your vault yet.", bundle: .module)
    }

    static var photoBusy: String {
        String(localized: "messages_photo_busy", defaultValue: "Your vault is busy right now. Try again in a minute.", bundle: .module)
    }

    static func photoTo(_ name: String) -> String {
        String(localized: "messages_photo_to", defaultValue: "Photo for \(name)", bundle: .module)
    }

    static func photoPeerNoPhotos(_ name: String) -> String {
        String(
            localized: "messages_photo_peer_no_photos",
            defaultValue: "Not delivered: \(name)'s VettID can't receive photos yet",
            bundle: .module
        )
    }

    static func photoInRate(_ name: String) -> String {
        String(localized: "messages_photo_in_rate", defaultValue: "Not received: too many photos from \(name) today", bundle: .module)
    }

    static func photoInWithdrawn(_ name: String) -> String {
        String(
            localized: "messages_photo_in_withdrawn",
            defaultValue: "Not received: \(name)'s vault can no longer send it",
            bundle: .module
        )
    }

    static func photoCdIn(_ name: String) -> String {
        String(localized: "messages_photo_cd_in", defaultValue: "Photo from \(name)", bundle: .module)
    }

    static func photoPreview(_ index: Int, _ count: Int) -> String {
        String(localized: "messages_photo_preview_cd", defaultValue: "Photo \(index) of \(count), as it will be sent", bundle: .module)
    }

    static func photoProgress(_ sent: Int, _ total: Int) -> String {
        String(localized: "messages_photo_progress", defaultValue: "\(sent) of \(total) sent", bundle: .module)
    }

    static func photoFailedPicks(_ count: Int) -> String {
        String(localized: "messages_photo_failed_picks", defaultValue: "\(count) picked pictures could not be used.", bundle: .module)
    }
}
