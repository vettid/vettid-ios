import UIKit

/// The app delegate's two jobs (IOS-PLAN §6.1, §6.5): refusing third-party keyboards app-wide, and keeping the app's
/// data out of backups.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Self.excludeFromBackup()
        return true
    }

    /// ID11: a keyboard extension with full access could read every field, including visible codes; only Apple's
    /// keyboard is offered.
    func application(_ application: UIApplication, shouldAllowExtensionPointIdentifier id: UIApplication.ExtensionPointIdentifier) -> Bool {
        Self.allows(id)
    }

    static func allows(_ id: UIApplication.ExtensionPointIdentifier) -> Bool { id != .keyboard }

    /// §6.1: data excluded from backups (vettid-android `allowBackup=false`): the directories the app writes to are
    /// marked, so that nothing the app keeps reaches iCloud or a computer's backup. Failures are not fatal: the data is
    /// encrypted under keys that are never backed up. Nothing sensitive goes in UserDefaults (Library/Preferences is
    /// backed up); stores live under these directories.
    static func excludeFromBackup(_ fm: FileManager = .default) {
        for dir in [FileManager.SearchPathDirectory.applicationSupportDirectory, .documentDirectory] {
            guard var url = try? fm.url(for: dir, in: .userDomainMask, appropriateFor: nil, create: true) else { continue }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }
}
