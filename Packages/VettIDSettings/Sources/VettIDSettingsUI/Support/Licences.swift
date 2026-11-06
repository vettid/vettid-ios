import Foundation

/// One third-party component bundled in the app, or the app itself, with its licence text (Help > Licenses).
struct LicenceEntry: Decodable, Equatable, Sendable, Identifiable {
    /// The SwiftPM identity for a package, otherwise a fixed name (`vettid`, `mlkem-native`, `font-inter`, ...).
let id: String
let name: String
    /// Empty for the app and the fonts.
let version: String
    /// The SPDX-style name of the licence.
let licence: String
let url: String
    /// The licence file, and the package's NOTICE file after it when it has one.
let text: String
}

/// The licences of what the app bundles: `Resources/Licences.json`, written by `scripts/licences.sh` from the resolved
/// packages' own licence files, the app's own first (AGPL-3.0, `LICENSE`). `scripts/release-check.sh` and the tests fail
/// when a dependency of a `Package.resolved` is missing from it.
enum Licences {
static func all() -> [LicenceEntry] {
        guard let url = Bundle.module.url(forResource: "Licences", withExtension: "json"), let data = try? Data(contentsOf: url) else {
            return []
        }
        return (try? JSONDecoder().decode([LicenceEntry].self, from: data)) ?? []
    }
}
