import Foundation
import UserNotifications
import VettIDData
import VettIDKeys

/// What a wipe of this iPhone erases (``LocalWipe``): the app's data directory (`Application Support/VettID`, where the
/// wipe's marker is), its caches and temporary files (best effort: iOS writes its own there), every keychain item and
/// Secure Enclave key of the app (as the first-run cleanup finds them: ``KeychainEraser``, then each key source through
/// its protocol), and its notifications.
/// The first-run cleanup's marker stays (it holds nothing of the vault; chosen; not in the spec). Mirrors vettid-android
/// `AndroidWipeTargets`.
struct AppWipeTargets: WipeTargets {
    let data: URL
    let hardware: [any KeyEraser]

    var marker: URL { data.appendingPathComponent(LocalWipe.marker) }

    var dirs: [URL] { [data] }

    /// Best effort, unchecked: the caches, the temporary files, Documents and the cookies.
    var scratch: [URL] {
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
        return [
            fm.urls(for: .cachesDirectory, in: .userDomainMask).first, fm.temporaryDirectory,
            fm.urls(for: .documentDirectory, in: .userDomainMask).first, library?.appendingPathComponent("Cookies"),
        ].compactMap { $0 }
    }

    /// The app's own preferences domain (Library/Preferences), best effort.
    func clearSettings() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: id)
    }

    var kept: [URL] { [data.appendingPathComponent(FirstRunCleanup.markerName)] }

    var erasers: [any KeyEraser] { [KeychainEraser()] + hardware }

    func keysLeft() throws -> Bool { try KeychainEraser().itemsLeft() }

    func cancelNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}
