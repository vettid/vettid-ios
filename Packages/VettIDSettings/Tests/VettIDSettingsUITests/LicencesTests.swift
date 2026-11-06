#if os(iOS)
import Foundation
import Testing
@testable import VettIDSettingsUI

/// The licenses screen's list (Help > Licenses): the app's own license first, every bundled component with its own
/// text, and no dependency of a `Package.resolved` missing from it (the same check as `scripts/licences.sh --verify`).
@Suite struct LicencesTests {
    /// The repository root, from this file: Packages/VettIDSettings/Tests/VettIDSettingsTests/LicencesTests.swift.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func theAppsOwnLicenseIsFirst() throws {
        let all = Licences.all()
        let first = try #require(all.first)
        #expect(first.id == "vettid" && first.licence == "AGPL-3.0")
        let license = try String(contentsOf: Self.root.appendingPathComponent("LICENSE"), encoding: .utf8)
        #expect(first.text == license.trimmingCharacters(in: .newlines))
    }

    @Test func aLongLicenseIsInParagraphs() throws {
        let first = try #require(Licences.all().first)
        #expect(first.paragraphs.count > 50)
        #expect(first.paragraphs.allSatisfy { !$0.isEmpty && $0.count < 5_000 })
        #expect(first.paragraphs.joined().filter { !$0.isWhitespace } == first.text.filter { !$0.isWhitespace })
    }

    @Test func everyEntryHasItsOwnText() {
        let all = Licences.all()
        #expect(all.count >= 9)
        #expect(Set(all.map(\.id)).count == all.count)
        for e in all {
            #expect(e.text.count > 200, "\(e.id)")
            #expect(!e.name.isEmpty && !e.licence.isEmpty && URL(string: e.url)?.scheme == "https", "\(e.id)")
        }
        // The notable texts: libsodium's ISC (swift-sodium), PhoneNumberKit's MIT, Apache-2.0 for the Apple packages.
        func text(_ id: String) -> String { all.first { $0.id == id }?.text ?? "" }
        #expect(text("swift-sodium").contains("ISC License"))
        #expect(text("phonenumberkit").contains("MIT"))
        #expect(text("swift-crypto").contains("Apache License"))
        #expect(text("mlkem-native").contains("Apache"))
        #expect(text("font-inter").contains("OFL") || text("font-inter").contains("Open Font License"))
        #expect(text("font-plus-jakarta-sans").contains("Open Font License"))
    }

    @Test func noResolvedDependencyIsMissing() throws {
        let listed = Set(Licences.all().map(\.id))
        let packages = Self.root.appendingPathComponent("Packages")
        var resolved = [Self.root.appendingPathComponent("VettID.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")]
        for dir in try FileManager.default.contentsOfDirectory(at: packages, includingPropertiesForKeys: nil) {
            resolved.append(dir.appendingPathComponent("Package.resolved"))
        }
        var checked = 0
        for file in resolved {
            guard let data = try? Data(contentsOf: file) else { continue }
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            for pin in root["pins"] as? [[String: Any]] ?? [] {
                let id = try #require(pin["identity"] as? String)
                #expect(listed.contains(id), "\(id) of \(file.path) is missing from Licences.json (scripts/licences.sh)")
                checked += 1
            }
        }
        #expect(checked >= 5)
    }

    @Test func theAppsResolvedVersionsAreTheListedOnes() throws {
        let file = Self.root.appendingPathComponent("VettID.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let all = Licences.all()
        for pin in root["pins"] as? [[String: Any]] ?? [] {
            let id = try #require(pin["identity"] as? String)
            let version = try #require((pin["state"] as? [String: Any])?["version"] as? String)
            #expect(all.first { $0.id == id }?.version == version, "\(id)")
        }
    }
}
#endif
