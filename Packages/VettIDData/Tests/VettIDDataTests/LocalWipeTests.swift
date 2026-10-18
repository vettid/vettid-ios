import Foundation
import Testing
@testable import VettIDData
import VettIDKeys

/// The wipe of a replaced phone (owner decision, 2026-10-05) on an app data directory laid out as on the iPhone, with a
/// fake keychain: afterwards the state equals a fresh install (the first-run cleanup's marker excepted); an interrupted
/// wipe finishes at the next start. Mirrors vettid-android `LocalWipeTest`, test for test.
@Suite struct LocalWipeTests {
    /// A keychain in memory: its items, and names whose deletion fails (once each).
    final class FakeKeychain: KeyEraser, @unchecked Sendable {
        private let lock = NSLock()
        private var itemsValue: Set<String> = []
        private var failingValue = false

        var items: Set<String> {
            get { lock.withLock { itemsValue } }
            set { lock.withLock { itemsValue = newValue } }
        }

        /// The next deletion fails (a keychain busy, a crash midway).
        var failsOnce: Bool {
            get { lock.withLock { failingValue } }
            set { lock.withLock { failingValue = newValue } }
        }

        func deleteAll() throws {
            try lock.withLock {
                if failingValue {
                    failingValue = false
                    itemsValue.remove("vettid.seed.identity.v1")
                    throw KeysError.unavailable("keychain")
                }
                itemsValue = []
            }
        }
    }

    /// The app's data directory and keychain, as the app lays them out.
    final class Phone: WipeTargets, @unchecked Sendable {
        let data: URL
        let caches: URL
        let keychain = FakeKeychain()
        private let lock = NSLock()
        private var notificationsValue = 3

        init() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("vettid-wipe-tests/\(UUID().uuidString)")
            data = root.appendingPathComponent("Application Support/VettID")
            caches = root.appendingPathComponent("Caches")
            for d in [data, caches] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        }

        var notifications: Int { lock.withLock { notificationsValue } }
        var marker: URL { data.appendingPathComponent(LocalWipe.marker) }
        var dirs: [URL] { [data] }
        var scratch: [URL] { [caches] }
        var kept: [URL] { [data.appendingPathComponent(FirstRunCleanup.markerName)] }
        var erasers: [any KeyEraser] { [keychain] }
        func keysLeft() throws -> Bool { !keychain.items.isEmpty }
        func cancelNotifications() { lock.withLock { notificationsValue = 0 } }

        /// Everything an enrolled app with an account, the owner check and the app lock keeps.
        func enrolled() throws {
            for name in [FirstRunCleanup.markerName, "account", "vault-device", "phone-secrets", "lock-record", "owner-check", "app-lock"] {
                try write(data, name)
            }
            try write(caches, "relay/journal")
            keychain.items = ["vettid.local_files.v1", "vettid.seed.identity.v1", "vettid.seed.relay.v1", "app key", "phone key"]
        }

        /// A fresh install: no file but the first-run marker, no key, no notification, no wipe marker.
        func expectFresh() {
            let left = (dirs + scratch).flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }
            #expect(left == [FirstRunCleanup.markerName], "files left: \(left)")
            #expect(keychain.items.isEmpty, "keys left: \(keychain.items)")
            #expect(notifications == 0)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }

        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: data.appendingPathComponent(name).path) }

        private func write(_ dir: URL, _ path: String) throws {
            let f = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("state".utf8).write(to: f)
        }
    }

    @MainActor
    final class Memory {
        var resets = 0
    }

    @Test @MainActor func aWipeLeavesAFreshInstall() async throws {
        let p = try Phone()
        try p.enrolled()
        let memory = Memory()
        let w = LocalWipe(targets: p, hooks: [{ memory.resets += 1 }, { memory.resets += 1 }])
        #expect(try await w.run())
        p.expectFresh()
        #expect(memory.resets == 2, "every in-memory reset ran")
        #expect(!w.pending)
    }

    @Test func theMarkerIsWrittenBeforeAnythingIsDeleted() throws {
        let p = try Phone()
        try p.enrolled()
        let w = LocalWipe(targets: p)
        try w.begin()
        #expect(w.pending)
        #expect(p.exists("account"))
    }

    @Test func aWipeInterruptedByTheProcessEndingFinishesAtTheNextStart() throws {
        let p = try Phone()
        try p.enrolled()
        // The process ends after the marker and part of the erase.
        try LocalWipe(targets: p).begin()
        try FileManager.default.removeItem(at: p.data.appendingPathComponent("vault-device"))
        p.keychain.items.remove("app key")
        // Next start, before anything reads local state:
        let next = LocalWipe(targets: p)
        #expect(next.resumeIfPending())
        p.expectFresh()
        #expect(!next.resumeIfPending())
    }

    @Test func aStepThatFailsKeepsTheMarkerAndTheNextStartFinishes() throws {
        let p = try Phone()
        try p.enrolled()
        p.keychain.failsOnce = true
        let w = LocalWipe(targets: p)
        try w.begin()
        #expect(!w.erase())
        // The files are gone already; the keys that could not be deleted, and the marker, stay.
        #expect(w.pending)
        #expect(!p.exists("account"))
        #expect(!p.keychain.items.isEmpty)
        #expect(LocalWipe(targets: p).resumeIfPending())
        p.expectFresh()
    }

    @Test func withoutAMarkerTheStartTouchesNothing() throws {
        let p = try Phone()
        try p.enrolled()
        #expect(!LocalWipe(targets: p).resumeIfPending())
        #expect(p.exists("account") && p.exists("phone-secrets"))
        #expect(p.keychain.items.count == 5)
        #expect(p.notifications == 3)
    }

    /// Release R: the old phone's wipe at the end of a kept transfer leaves its notice, also when a crash interrupted it.
    @Test func theMovedAwayNoticeSurvivesTheWipeAndACrash() throws {
        let p = try Phone()
        try p.enrolled()
        let wipe = LocalWipe(targets: p)
        try wipe.begin(reason: LocalWipe.reasonMovedAway)
        #expect(!wipe.movedAway)
        // The process ends here; the next start finishes the wipe.
        #expect(LocalWipe(targets: p).resumeIfPending())
        #expect(wipe.movedAway)
        wipe.acknowledgeMovedAway()
        #expect(!wipe.movedAway)
    }

    @Test @MainActor func anOtherWipeLeavesNoNotice() async throws {
        let p = try Phone()
        try p.enrolled()
        let wipe = LocalWipe(targets: p)
        #expect(try await wipe.run())
        #expect(!wipe.movedAway)
    }

    /// "Erase VettID's data on this phone" (vettid-android `AppDataClear`): everything, the wipe's marker included, without
    /// writing one; false when something stays.
    @Test func clearingTheDataErasesTheMarkerToo() throws {
        let p = try Phone()
        try p.enrolled()
        try LocalWipe(targets: p).begin()
        p.keychain.failsOnce = true
        let w = LocalWipe(targets: p)
        #expect(!w.clearAll())
        #expect(w.clearAll())
        p.expectFresh()
    }
}
