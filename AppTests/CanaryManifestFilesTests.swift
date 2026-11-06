import Foundation
import Testing
import VettIDAttestation
import VettIDData
@testable import VettID

/// "Open in VettID" for a canary manifest (VAULT-RELEASES §10.1 step 9): JSON is declared in every configuration at rank
/// Alternate (VettID is never the default app for JSON) as a viewer, copied in rather than opened in place; an opened
/// file is only read, bounded, and its copy removed. Nothing is installed here: the root's dialog asks first.
@MainActor
@Suite struct CanaryManifestFilesTests {
    @Test func jsonIsDeclaredAsAnAlternateViewer() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        let types = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(types.count == 1)
        let t = try #require(types.first)
        #expect(t["LSItemContentTypes"] as? [String] == ["public.json"])
        #expect(t["LSHandlerRank"] as? String == "Alternate")
        #expect(t["CFBundleTypeRole"] as? String == "Viewer")
        #expect(info["LSSupportsOpeningDocumentsInPlace"] as? Bool == false)
    }

    @Test func anOpenedFileIsReadBoundedAndItsCopyRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canary-files-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let copy = inbox.appendingPathComponent("served-9.json")
        let doc = Array(#"{"manifest":"","sig":"","key_id":""}"#.utf8)
        try Data(doc).write(to: copy)
        #expect(CanaryManifestFiles.receive(copy, inbox: inbox) == doc)
        #expect(!FileManager.default.fileExists(atPath: copy.path), "the copy iOS made is removed")

        let large = inbox.appendingPathComponent("large.json")
        try Data(repeating: 0x20, count: ReleaseManifest.maxServed + 100).write(to: large)
        #expect(CanaryManifestFiles.receive(large, inbox: inbox)?.count == ReleaseManifest.maxServed + 1)

        // A file elsewhere (opened through a security scope) is read and left where it is.
        let elsewhere = root.appendingPathComponent("served-9.json")
        try Data(doc).write(to: elsewhere)
        #expect(CanaryManifestFiles.receive(elsewhere, inbox: inbox) == doc)
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))

        // Not a file: nothing.
        #expect(CanaryManifestFiles.receive(try #require(URL(string: "https://example.com/served-9.json")), inbox: inbox) == nil)
    }

    /// The launch sweep removes copies left in `Documents/Inbox` once they are old enough, never one being opened now.
    @Test func theLaunchSweepRemovesStrayCopies() throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent("canary-sweep-\(UUID().uuidString)/Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: inbox.deletingLastPathComponent()) }
        let old = inbox.appendingPathComponent("served-7.json")
        let fresh = inbox.appendingPathComponent("served-8.json")
        try Data([1]).write(to: old)
        try Data([2]).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: old.path)
        CanaryManifestFiles.sweepInbox(inbox)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    /// At app level, the pins of each build: a staging-signed document (staging.vettid.org's serial 17, as a canary of
    /// serial 17 would be) installs under this Debug build's pin (the staging key) and is refused under Release's.
    @Test func releaseRefusesAStagingSignedCanary() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/VettIDAttestation/Tests/VettIDAttestationTests/Resources/manifest")
            .appendingPathComponent("staging-pcr-manifest-serial17.json")
        let doc = try [UInt8](Data(contentsOf: fixture))
        let release = try #require(AppEnvironment(infoDictionary: AppEnvironmentTests.production)).trust()
        #expect(throws: AttestationError.manifestKey) {
            _ = try CanaryManifests.check(verifier: ManifestVerifier(pinned: release.manifestKeys), served: doc, seen: 0, published: nil)
        }
        let debug = try AppEnvironment.current.trust()
        let m = try CanaryManifests.check(verifier: ManifestVerifier(pinned: debug.manifestKeys), served: doc, seen: 0, published: nil)
        #expect(m.serial == 17)
    }
}
