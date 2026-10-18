import Foundation
import Testing
@testable import VettIDKeys
import VettIDKeysTesting

/// The first-run cleanup (IOS-PLAN §6.1) with fakes: it deletes every key on a genuine first run only, and a launch
/// before the first unlock deletes nothing.
@Suite struct FirstRunCleanupTests {
    let eraser = RecordingEraser()
    let phone = SoftwarePhoneSecretSource()
    let app = SoftwareAppKeyStore()

    func cleanup(
        _ dir: URL,
        _ protectedData: any ProtectedData = ProtectedDataFlag(available: true),
        dataFiles: [URL] = [URL(fileURLWithPath: "/nonexistent/vettid")]
    ) -> FirstRunCleanup {
        FirstRunCleanup(directory: dir, protectedData: protectedData, erasers: [eraser, phone, app], dataFiles: dataFiles)
    }

    @Test func aFirstRunDeletesEveryKeyAndWritesTheMarker() throws {
        let dir = try scratchDirectory().appendingPathComponent("VettID", isDirectory: true)
        _ = try phone.create(keyVault: "stale-vault")
        _ = try app.getOrCreate()
        let c = cleanup(dir)
        #expect(try c.run() == .cleaned)
        #expect(eraser.runs == 1)
        #expect(phone.keyVaults.isEmpty)
        #expect(app.lookup().isMissing)
        #expect(try Array(Data(contentsOf: c.markerURL)) == FirstRunCleanup.markerContent)
        #expect(AppDirectories.isExcludedFromBackup(dir))
        // The next launch reads the marker and deletes nothing.
        _ = try phone.create(keyVault: "new-vault")
        #expect(try c.run() == .alreadyDone)
        #expect(eraser.runs == 1)
        #expect(phone.keyVaults == ["new-vault"])
    }

    /// A launch before the first unlock (a background launch after a reboot) deletes nothing and leaves the check.
    @Test func aLaunchBeforeTheFirstUnlockDeletesNothing() throws {
        let dir = try scratchDirectory()
        _ = try phone.create(keyVault: "v1")
        let locked = ProtectedDataFlag()
        #expect(try cleanup(dir, locked).run() == .deferred)
        #expect(eraser.runs == 0)
        #expect(phone.keyVaults == ["v1"])
        #expect(!FileManager.default.fileExists(atPath: cleanup(dir).markerURL.path))
        // Protected data that goes away during the marker's lookup: still nothing.
        #expect(try cleanup(dir, FadingProtectedData(availableReads: 2)).run() == .deferred)
        #expect(eraser.runs == 0)
        // Later, unlocked: the cleanup runs.
        locked.set(true)
        #expect(try cleanup(dir, locked).run() == .cleaned)
        #expect(eraser.runs == 1)
    }

    /// A marker that exists but cannot be read (a file-protection refusal) is not a first run.
    @Test func anUnreadableMarkerIsNotAFirstRun() throws {
        let dir = try scratchDirectory()
        let c = cleanup(dir)
        #expect(try c.run() == .cleaned)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: c.markerURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: c.markerURL.path) }
        #expect(try c.run() == .deferred)
        #expect(eraser.runs == 1)
    }

    /// A marker with content this build does not expect (damaged) counts as done: nothing is deleted.
    @Test func aDamagedMarkerCountsAsDone() throws {
        let dir = try scratchDirectory()
        let c = cleanup(dir)
        try Data("garbage".utf8).write(to: c.markerURL)
        _ = try phone.create(keyVault: "v1")
        #expect(try c.run() == .alreadyDone)
        #expect(eraser.runs == 0)
        #expect(phone.keyVaults == ["v1"])
    }

    /// The app's own data files exist (the records file): not a fresh install, whatever happened to the marker. Nothing
    /// is deleted and the marker is written; a data file that cannot be read now defers the check.
    @Test func existingDataFilesRefuseTheCleanup() throws {
        let dir = try scratchDirectory()
        let records = dir.appendingPathComponent("phone-secrets")
        try Data([1, 2, 3]).write(to: records)
        _ = try phone.create(keyVault: "v1")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: records.path)
        #expect(try cleanup(dir, dataFiles: [records]).run() == .deferred)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: records.path)
        #expect(try cleanup(dir, dataFiles: [records]).run() == .dataPresent)
        #expect(eraser.runs == 0)
        #expect(phone.keyVaults == ["v1"])
        #expect(try cleanup(dir, dataFiles: [records]).run() == .alreadyDone)
    }

    /// A deletion that fails writes no marker, so the next launch runs the cleanup again.
    @Test func aFailedDeletionIsRetriedAtTheNextLaunch() throws {
        let dir = try scratchDirectory()
        eraser.fails = true
        #expect(throws: KeysError.unavailable("eraser")) { try cleanup(dir).run() }
        #expect(!FileManager.default.fileExists(atPath: cleanup(dir).markerURL.path))
        eraser.fails = false
        #expect(try cleanup(dir).run() == .cleaned)
    }
}

extension ItemLookup {
    var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }
}
