import CryptoKit
import Foundation

/// Holds the AES-256 key of the app's encrypted files: on the iPhone a keychain item, `AfterFirstUnlockThisDeviceOnly`
/// and not synchronizable (``KeychainFileKeyHolder``); in tests an in-memory key.
public protocol FileKeyHolder: KeyEraser {
    /// The key, made when the lookup genuinely found none. Throws ``KeysError/unavailable(_:)`` while it cannot be read.
    func key() throws -> SymmetricKey
}

/// A file encrypted under a keychain-held AES-256-GCM key (IOS-PLAN §6.1), in vettid-android `KeystoreFileStore`'s
/// format: ``AesGcmBlob`` with `aad = "vettid/file/1" || 0x00 || purpose`.
///
/// - Writes go to a temporary file in the same directory that is synced and renamed over the old one, so a crash leaves
///   either the old or the new content (ack after persist, VAULT-MESSAGING §8.3).
/// - Files are `NSFileProtectionCompleteUntilFirstUserAuthentication`, and their directory is excluded from backups
///   (``AppDirectories``). Never Caches or tmp: a lost record is a lost secret (IOS-PLAN §6.3).
/// - ``lookup()`` tells "no such file" apart from "protected data unavailable": a lookup during which protected data
///   went away is not "missing" (IOS-PLAN §6.3).
/// - One lock per file path, process-wide (``exclusive(_:)``): two stores over the same file never interleave a
///   read-modify-write.
public final class EncryptedFileStore: @unchecked Sendable {
    public static let label = "vettid/file/1"

    public let url: URL
    private let purpose: String
    private let keys: any FileKeyHolder
    private let protectedData: any ProtectedData
    private let lock: NSRecursiveLock

    /// [url] is the file (its directory is created and excluded from backups on the first write); [purpose] binds the
    /// content to its use (another purpose cannot read it).
    public init(url: URL, purpose: String, keys: any FileKeyHolder, protectedData: any ProtectedData) {
        self.url = url
        self.purpose = purpose
        self.keys = keys
        self.protectedData = protectedData
        lock = FileLocks.lock(for: url)
    }

    /// Runs [body] holding this file's process-wide lock (recursive): a read-modify-write of the file in one piece.
    public func exclusive<T>(_ body: () throws -> T) rethrows -> T { try lock.withLock(body) }

    /// The decrypted content, classified by IOS-PLAN §6.3. A file that exists but does not decrypt throws
    /// ``KeysError/corrupt(_:)``, one in a format this app does not know ``KeysError/unknownFormat(_:)``; a key that cannot be read now throws ``KeysError/unavailable(_:)``.
    public func lookup() throws -> ItemLookup<[UInt8]> {
        try lock.withLock {
            switch ProtectedLookup.run(protectedData, { FileIO.read(url) }) {
            case .found(let blob): .found(try AesGcmBlob.open(try keys.key(), aad: aad, blob, what: url.lastPathComponent))
            case .missing: .missing
            case .unavailable: .unavailable
            }
        }
    }

    /// The content, nil when the file is genuinely missing; throws ``KeysError/unavailable(_:)`` when it cannot be
    /// read now. The shape of VettIDVault's `DeviceStateStore`.
    public func load() throws -> [UInt8]? {
        switch try lookup() {
        case .found(let b): b
        case .missing: nil
        case .unavailable: throw KeysError.unavailable(url.lastPathComponent)
        }
    }

    /// Encrypts and atomically replaces the file. Durable when it returns.
    public func save(_ data: [UInt8]) throws {
        try lock.withLock {
            let blob = try AesGcmBlob.seal(try keys.key(), aad: aad, data)
            try FileIO.atomicWrite(blob, to: url)
        }
    }

    /// Removes the file (a wipe).
    public func clear() throws {
        try lock.withLock { try FileIO.remove(url) }
    }

    private var aad: [UInt8] { Array(Self.label.utf8) + [0] + Array(purpose.utf8) }
}

/// One recursive lock per standardized file path, for the whole process.
enum FileLocks {
    private static let registry = NSLock()
    nonisolated(unsafe) private static var locks: [String: NSRecursiveLock] = [:]

    static func lock(for url: URL) -> NSRecursiveLock {
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        return registry.withLock {
            if let l = locks[key] { return l }
            let l = NSRecursiveLock()
            locks[key] = l
            return l
        }
    }
}

/// The app's directories (IOS-PLAN §6.1): its data lives in `Application Support/VettID`, excluded from backups, with
/// files `CompleteUntilFirstUserAuthentication`.
public enum AppDirectories {
    public static let dataFolder = "VettID"

    /// `Application Support/VettID` (not created here).
    public static func data() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent(dataFolder, isDirectory: true)
    }

    /// Creates [directory] when needed and marks it excluded from backups.
    public static func prepare(_ directory: URL) throws {
        var attributes: [FileAttributeKey: Any] = [:]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var dir = directory
            try dir.setResourceValues(values)
        } catch {
            throw KeysError.unavailable("data directory")
        }
    }

    /// Whether [directory] is marked excluded from backups.
    public static func isExcludedFromBackup(_ directory: URL) -> Bool {
        (try? directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }
}

/// POSIX file access, so that "no such file" (`ENOENT`) is told apart from every other answer.
enum FileIO {
    static func read(_ url: URL) -> RawLookup<[UInt8]> {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { return errno == ENOENT ? .noSuchItem : .failed }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size >= 0 else { return .failed }
        var out = [UInt8](repeating: 0, count: Int(st.st_size))
        var done = 0
        while done < out.count {
            let n = out.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + done, $0.count - done) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return .failed }
            done += n
        }
        return .found(out)
    }

    /// Writes [bytes] to a temporary file next to [url], syncs it, renames it over [url] and syncs the directory.
    static func atomicWrite(_ bytes: [UInt8], to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try AppDirectories.prepare(dir)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        #if os(iOS)
        // Created empty with its protection class first, then filled: the content never sits in a weaker class.
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o600,
        ]
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: attributes) else {
            throw KeysError.unavailable(url.lastPathComponent)
        }
        let fd = Darwin.open(tmp.path, O_WRONLY | O_TRUNC | O_CLOEXEC)
        #else
        let fd = Darwin.open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        #endif
        guard fd >= 0 else {
            unlink(tmp.path)
            throw KeysError.unavailable(url.lastPathComponent)
        }
        var ok = writeAll(fd, bytes) && fsync(fd) == 0
        ok = Darwin.close(fd) == 0 && ok
        guard ok, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw KeysError.unavailable(url.lastPathComponent)
        }
        let dfd = Darwin.open(dir.path, O_RDONLY | O_CLOEXEC)
        if dfd >= 0 {
            fsync(dfd)
            Darwin.close(dfd)
        }
    }

    static func remove(_ url: URL) throws {
        if unlink(url.path) != 0, errno != ENOENT { throw KeysError.unavailable(url.lastPathComponent) }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + done, $0.count - done) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return false }
            done += n
        }
        return true
    }
}
