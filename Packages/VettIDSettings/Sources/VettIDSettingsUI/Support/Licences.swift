import Foundation

/// One third-party component bundled in the app, or the app itself, with its license text (Help > Licenses).
struct LicenceEntry: Decodable, Equatable, Sendable, Identifiable {
    /// The SwiftPM identity for a package, otherwise a fixed name (`vettid`, `mlkem-native`, `font-inter`, ...).
    let id: String
    let name: String
    /// Empty for the app and the fonts.
    let version: String
    /// The SPDX-style name of the license.
    let licence: String
    let url: String
    /// The license file, and the package's NOTICE file after it when it has one.
    let text: String

    /// The text in paragraphs (split at blank lines), so that a screen reader moves through a long license one paragraph at a time.
    var paragraphs: [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// The licenses of what the app bundles: `Resources/Licences.json`, written by `scripts/licences.sh` from the resolved
/// packages' own license files, the app's own first (AGPL-3.0, `LICENSE`). `scripts/release-check.sh` and the tests fail
/// when a dependency of a `Package.resolved` is missing from it.
enum Licences {
    /// Read once, on first use.
    private static let loaded: [LicenceEntry] = {
        guard let url = Bundle.module.url(forResource: "Licences", withExtension: "json"), let data = try? Data(contentsOf: url) else {
            return []
        }
        return (try? JSONDecoder().decode([LicenceEntry].self, from: data)) ?? []
    }()

    static func all() -> [LicenceEntry] { loaded }
}
