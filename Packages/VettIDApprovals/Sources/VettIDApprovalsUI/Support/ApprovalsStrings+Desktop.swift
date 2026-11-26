import Foundation

// The texts of a desktop's held block or removal of a connection (ANDROID-PLAN 0.1.145, 0.1.146; owner-approved), word for word
// as vettid-android's `feature/approvals` `strings.xml` has them (`approvals_desktop_*`), under the same names.
extension ApprovalsStrings {
    static func desktopBlockTitle(_ who: String, _ target: String) -> String {
        String(localized: "approvals_desktop_block_title", defaultValue: "\(who) wants to block \(target)", bundle: .module)
    }

    static func desktopBlockBody(_ target: String) -> String {
        String(
            localized: "approvals_desktop_block_body",
            defaultValue: "Blocking ends your connection with \(target). They can't connect with you again until you unblock them.",
            bundle: .module
        )
    }

    static func desktopRemoveTitle(_ who: String, _ target: String) -> String {
        String(localized: "approvals_desktop_remove_title", defaultValue: "\(who) wants to remove \(target)", bundle: .module)
    }

    static func desktopRemoveBody(_ target: String) -> String {
        String(localized: "approvals_desktop_remove_body", defaultValue: "Removing ends your connection with \(target).", bundle: .module)
    }

    /// The label above a block's note: [who] is the desktop's name, isolated.
    static func desktopNoteFrom(_ who: String) -> String {
        String(localized: "approvals_desktop_note_from", defaultValue: "Note from \(who):", bundle: .module)
    }

    /// A connection's name with the day it was connected, when another connection has the same name.
    static func desktopNamesake(_ name: String, _ date: String) -> String {
        String(localized: "approvals_desktop_namesake", defaultValue: "\(name) (connected \(date))", bundle: .module)
    }
}
