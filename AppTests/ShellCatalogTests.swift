import SwiftUI
import Testing
import UIKit
@testable import VettID
import VettIDSettings
import VettIDUI

/// The shell and Settings entries of the debug screen catalog render in both themes; "Installed from" follows the build
/// configuration (IOS-PLAN ID15).
@MainActor
struct ShellCatalogTests {
    @Test func everyCatalogStateRenders() {
        #expect(Set(ShellCatalog.entries.map(\.id)).count == ShellCatalog.entries.count)
        for mode in [ThemeMode.dark, .light] {
            for entry in ShellCatalog.entries {
                let host = UIHostingController(rootView: ShellCatalog.screen(entry).vettIDTheme(mode))
                #expect(host.sizeThatFits(in: CGSize(width: 390, height: 844)).height > 0, "\(entry.id)")
            }
        }
    }

    /// The tests run the Debug configuration: a development build, installed from Xcode.
    @Test func aDebugBuildIsInstalledFromXcode() {
        #expect(AppEnvironment.current.kind == .debug)
        #expect(InstalledFromBuild.current == .development(label: "Installed from: Xcode (development)"))
    }
}
