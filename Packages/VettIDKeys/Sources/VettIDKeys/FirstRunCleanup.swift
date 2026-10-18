import Foundation

/// The first-run cleanup (IOS-PLAN §6.1; VAULT-MESSAGING §11.14.1 "On an iPhone", "Removal and deletion"). Keychain
/// items survive removing the app while its files do not, so on its first run after an install the app deletes every
/// VettID keychain item and Secure Enclave key it finds before it does anything else: stale keys are never taken for
/// usable ones.
///
/// - "First run" is decided by **reading the content** of a marker file in `Application Support/VettID` (excluded from
///   backups like the rest of the app's data, so a restore also counts as a first run), never from `UserDefaults`,
///   which reads as empty before the first unlock.
/// - It runs only while protected data is available and the marker's absence is a genuine "no such file" (IOS-PLAN
///   §6.3): a launch before the first unlock (a background launch after a reboot) deletes nothing and leaves the check
///   for a later launch.
/// - The marker is written after the cleanup, by atomic replace; a cleanup interrupted before it runs again.
/// - It refuses to delete anything while one of the app's own data files (the phone-secret records, the device state)
///   exists: files that survived mean this is not a fresh install, whatever happened to the marker; the marker is then
///   written and nothing is deleted (chosen; not in the spec).
public struct FirstRunCleanup: Sendable {
    public static let markerName = "installed"
    /// The marker's content. A readable marker with other content is left alone and counts as done (chosen; not in the
    /// spec): deleting the keys of an enrolled vault on a damaged marker would lose the vault.
    public static let markerContent = Array("vettid-installed-v1\n".utf8)

    public enum Outcome: Equatable, Sendable {
        /// The marker was there: nothing deleted.
        case alreadyDone
        /// A first run: every key and item deleted, the marker written.
        case cleaned
        /// Protected data unavailable, or the marker or a data file could not be read: nothing deleted; try later.
        case deferred
        /// No marker, but the app's data files exist: nothing deleted, the marker written.
        case dataPresent
    }

    private let directory: URL
    private let protectedData: any ProtectedData
    private let erasers: [any KeyEraser]
    private let dataFiles: [URL]

    /// [directory] holds the marker (``AppDirectories/data()`` in the app); [erasers] remove every keychain item and key
    /// (``KeychainEraser`` first, then each key source through its protocol); [dataFiles] are the app's own data files
    /// whose presence refuses the cleanup (required: a caller cannot forget them).
    public init(directory: URL, protectedData: any ProtectedData, erasers: [any KeyEraser], dataFiles: [URL]) {
        self.directory = directory
        self.protectedData = protectedData
        self.erasers = erasers
        self.dataFiles = dataFiles
    }

    public var markerURL: URL { directory.appendingPathComponent(Self.markerName) }

    /// Runs the check, and the cleanup when this is a first run. Throws when a deletion or the marker's write fails
    /// (the marker is then not written, so the next launch runs the cleanup again).
    public func run() throws -> Outcome {
        guard protectedData.isAvailable else { return .deferred }
        switch ProtectedLookup.run(protectedData, { FileIO.read(markerURL) }) {
        case .found: return .alreadyDone
        case .unavailable: return .deferred
        case .missing: break
        }
        for file in dataFiles {
            switch ProtectedLookup.run(protectedData, { FileIO.read(file) }) {
            case .missing: continue
            case .unavailable: return .deferred
            case .found:
                try FileIO.atomicWrite(Self.markerContent, to: markerURL)
                return .dataPresent
            }
        }
        for eraser in erasers { try eraser.deleteAll() }
        try FileIO.atomicWrite(Self.markerContent, to: markerURL)
        return .cleaned
    }
}
