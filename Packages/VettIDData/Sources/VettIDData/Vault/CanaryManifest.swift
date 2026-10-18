import Foundation
import Observation
import VettIDAttestation

/// A canary manifest as the member (VettID's tester) sees it before and after installing it: its serial, the pinned key
/// that signed it, the hash the requests name (VAULT-MESSAGING §11.5) and its releases. Mirrors vettid-android
/// `CanaryManifestView`.
public struct CanaryManifestView: Equatable, Sendable {
    public var serial: UInt64
    public var keyID: String
    public var sha256: String
    public var releases: [ReleaseView]

    public init(serial: UInt64, keyID: String, sha256: String, releases: [ReleaseView]) {
        self.serial = serial
        self.keyID = keyID
        self.sha256 = sha256
        self.releases = releases
    }

    /// [m], verified from the served document [served].
    init(served: [UInt8], manifest m: ReleaseManifest) {
        serial = m.serial
        keyID = (try? ServedManifest.parse(served).keyID) ?? ""
        sha256 = m.sha256Hex
        releases = m.releases.map {
            ReleaseView(number: $0.number, pcr0: $0.pcr0, status: $0.status.rawValue, endsAt: $0.endsAt, notes: $0.notes)
        }
    }
}

/// The canary manifest of VAULT-RELEASES §10.1 step 9 on this phone (VAULT-MESSAGING §11.10.1 "A canary manifest"): a
/// release manifest signed with a key this build pins but not published yet, handed to the app as a file, verified like
/// the published one and used instead of it only while its serial is higher (``VettIDAttestation/CanaryManifests``).
/// Failures are ``VaultFailure``s of kind ``FailureKind/manifest`` with one of ``CanaryManifestCodes``. Mirrors
/// vettid-android `CanaryManifestRepository`.
@MainActor
public protocol CanaryManifestRepository: AnyObject, Observable, Sendable {
    /// The installed canary manifest, or nil. Cleared when the published manifest reaches its serial.
    var canaryManifest: CanaryManifestView? { get }

    /// Verifies [served] (a served manifest document) without installing it, for the member's confirmation.
    func checkCanaryManifest(_ served: [UInt8]) async throws -> CanaryManifestView

    /// Verifies [served] again and installs it, replacing any installed one.
    func installCanaryManifest(_ served: [UInt8]) async throws -> CanaryManifestView

    /// Forgets the installed canary manifest (the published one is used again).
    func removeCanaryManifest()
}

/// The codes of a refused canary manifest (``VaultFailure/code``). Mirrors vettid-android `CanaryManifestRepository`'s
/// `CODE_*`.
public enum CanaryManifestCodes {
    /// Not a served manifest document, or a malformed manifest.
    public static let format = "canary_format"
    /// Signed with a key this build does not pin, or the signature does not verify.
    public static let signature = "canary_signature"
    /// Its serial is lower than one this phone has already used.
    public static let older = "canary_older"
    /// The published manifest already has this serial or a newer one.
    public static let published = "canary_published"
    /// Larger than a served manifest may be (§11.10.1: 90,112 bytes).
    public static let tooLarge = "canary_too_large"
    /// The serial rules could not be checked, so nothing is installed: the serial this phone has used for its vault could
    /// not be read (chosen; not in the spec), or the published manifest could not be read (other than a 404: nothing
    /// published yet) or did not verify (the owner's decision, vettid-ios #67).
    public static let unchecked = "canary_unchecked"
}

/// A served manifest document the app was handed (opened with VettID from Files or AirDrop, or picked in Settings →
/// Attestation), passed from the scene to the root of the UI, which verifies it and asks the member before anything is
/// installed. Observable: the root follows ``document``. Mirrors vettid-android `CanaryManifestInbox`.
@MainActor
@Observable
public final class CanaryManifestInbox {
    public private(set) var document: [UInt8]?

    public init() {}

    public func offer(_ served: [UInt8]) { document = served }

    public func consume() { document = nil }

    /// Bumped by every ``offerUnreadable()``: the root's dialog says the file could not be checked.
    public private(set) var unreadable = 0

    /// A file was picked but could not be read: nothing to verify.
    public func offerUnreadable() { unreadable += 1 }

    /// Bumped by every ``reset()``: the root's dialog follows it and drops what it was asking about.
    public private(set) var resets = 0

    /// A wipe of this phone: a document waiting is dropped, and so is one the dialog is asking about.
    public func reset() {
        document = nil
        resets += 1
    }

    /// Reads [url] up to one byte more than a served manifest may have (§11.10.1, 90,112 bytes), so that a larger file is
    /// refused as too large without being read to its end. A security-scoped URL (the file importer's) is accessed for
    /// the read only.
    public nonisolated static func readBounded(_ url: URL) throws -> [UInt8] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try readBounded(handle, limit: ReleaseManifest.maxServed + 1)
    }

    static nonisolated func readBounded(_ handle: FileHandle, limit: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        while out.count < limit {
            guard let chunk = try handle.read(upToCount: min(chunkSize, limit - out.count)), !chunk.isEmpty else { break }
            out += chunk
        }
        return out
    }

    private nonisolated static let chunkSize = 8192
}
