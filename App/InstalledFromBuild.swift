import Foundation
import VettIDSettings

/// "Installed from" on Settings → Vault status (IOS-PLAN ID15), decided by the build configuration: Apple (App Store or
/// TestFlight) for Release and Staging, Xcode for the development builds (Debug, DevStack). The development text is
/// compiled into the development builds only; the release check refuses it in Release and Staging.
enum InstalledFromBuild {
    static var current: InstalledFrom {
        #if DEBUG
        .development(label: developmentLabel)
        #else
        .apple
        #endif
    }

    #if DEBUG
    /// IOS-PLAN §14 "Installed from (ID15)".
    static var developmentLabel: String {
        String(localized: "ios_settings_installed_development", defaultValue: "Installed from: Xcode (development)")
    }
    #endif
}
