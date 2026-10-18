import Foundation
import Testing
import UIKit
@testable import VettID
import VettIDUI

/// IOS-PLAN §6.1 and §6.5 at the app level: third-party keyboards refused, the app's data out of backups, and
/// "Allow screenshots" on from the start only in the development builds (ID10).
struct SecureInputTests {
    @Test func thirdPartyKeyboardsAreRefused() {
        #expect(!AppDelegate.allows(.keyboard))
    }

    @Test func theAppsDirectoriesAreExcludedFromBackup() throws {
        AppDelegate.excludeFromBackup()
        for dir in [FileManager.SearchPathDirectory.applicationSupportDirectory, .documentDirectory] {
            let url = try FileManager.default.url(for: dir, in: .userDomainMask, appropriateFor: nil, create: false)
            #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true, "\(dir)")
        }
    }

    /// §6.4 protections 1 and 2 are installed on the app's window scene, hidden while the scene is active and not captured.
    @MainActor
    @Test func thePrivacyShieldIsInstalledOnTheScene() async throws {
        var scene: UIWindowScene?
        for _ in 0..<100 {
            scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            if let s = scene, PrivacyShieldState.isShown(in: s) != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let s = try #require(scene)
        guard let shown = PrivacyShieldState.isShown(in: s) else {
            Issue.record("no privacy shield on the scene")
            return
        }
        #expect(shown == (s.activationState != .foregroundActive || s.traitCollection.sceneCaptureState == .active))
    }

    @Test func screenshotsAreAllowedFromTheStartOnlyInDevelopmentBuilds() {
        #expect(AppEnvironment.Kind.debug.screenshotsByDefault && AppEnvironment.Kind.devstack.screenshotsByDefault)
        #expect(!AppEnvironment.Kind.production.screenshotsByDefault && !AppEnvironment.Kind.staging.screenshotsByDefault)
    }
}
