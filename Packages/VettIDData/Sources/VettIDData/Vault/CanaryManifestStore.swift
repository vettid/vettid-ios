import Foundation
import Observation
import VettIDAltChan
import VettIDAttestation
import VettIDKeys

/// The installed canary manifest's file: the served document's exact bytes in the app's encrypted file store
/// (``EncryptedFileStore``, in the data directory that a wipe erases), and the ``CanaryManifestSource`` the alternate
/// channel reads it from before each enroll, unlock and recovery register. Safe from any thread: the file's own
/// process-wide lock makes the retire's compare-and-clear one step.
final class CanaryManifestStore: CanaryManifestSource, @unchecked Sendable {
    private let file: EncryptedFileStore
    private let lock = NSLock()
    private var changed: (@Sendable () -> Void)?

    init(file: EncryptedFileStore) { self.file = file }

    /// Told when the alternate channel retired the document (the published manifest reached it, or it no longer
    /// verifies).
    func onChange(_ body: @escaping @Sendable () -> Void) { lock.withLock { changed = body } }

    /// The document, nil when none is installed; throws when the file cannot be read now or does not decrypt.
    func load() throws -> [UInt8]? { try file.load() }

    func save(_ served: [UInt8]) throws { try file.save(served) }

    func clear() { try? file.clear() }

    // MARK: - CanaryManifestSource

    func served() -> [UInt8]? { (try? file.load()) ?? nil }

    func retire(_ served: [UInt8]) {
        guard file.exclusive({ clearIfCurrent(served) }) else { return }
        let body = lock.withLock { changed }
        body?()
    }

    /// Clears the file when it still holds [served] (another document may have replaced it meanwhile).
    private func clearIfCurrent(_ served: [UInt8]) -> Bool {
        guard let current = self.served(), current == served else { return false }
        return (try? file.clear()) != nil
    }
}

/// The canary manifest on this phone (``CanaryManifestRepository``): verified under this build's pinned manifest keys
/// (the published manifest's), refused when older than the serial this phone used or already published, installed in
/// ``CanaryManifestStore`` and used by the alternate channel through it. Mirrors vettid-android `CanaryManifestStore`.
@MainActor
@Observable
public final class CanaryManifestManager: CanaryManifestRepository {
    public private(set) var canaryManifest: CanaryManifestView?

    @ObservationIgnored let store: CanaryManifestStore
    @ObservationIgnored private let verifier: ManifestVerifier
    @ObservationIgnored private let seen: @MainActor () async throws -> UInt64
    @ObservationIgnored private let published: @Sendable () async throws -> [UInt8]
    @ObservationIgnored private var loaded = false
    /// Bumped by every wipe (``forget()``): an installation whose checks began before one saves nothing.
    @ObservationIgnored private var generation = 0

    /// [seen]: the highest manifest serial this phone has used for its vault (0 without one); [published]: the published
    /// manifest's served document (a ``MemberApiError`` 404 when nothing is published).
    init(
        store: CanaryManifestStore,
        trust: AltTrust,
        seen: @escaping @MainActor () async throws -> UInt64,
        published: @escaping @Sendable () async throws -> [UInt8]
    ) {
        self.store = store
        verifier = ManifestVerifier(pinned: trust.manifestKeys)
        self.seen = seen
        self.published = published
        store.onChange { [weak self] in
            Task { @MainActor in self?.reload() }
        }
    }

    /// Reads what is installed (once the first-run cleanup ran, IOS-PLAN §6.1): a document that no longer verifies, or
    /// a file that no longer decrypts, is dropped. Tried again while the file cannot be read yet.
    func loadIfNeeded() {
        guard !loaded else { return }
        let served: [UInt8]?
        do {
            served = try store.load()
        } catch KeysError.unavailable {
            return
        } catch {
            store.clear()
            served = nil
        }
        loaded = true
        canaryManifest = served.flatMap(verified)
    }

    /// The view of what the file holds now (after the alternate channel retired it).
    func reload() {
        guard loaded else { return }
        canaryManifest = store.served().flatMap(verified)
    }

    /// A wipe erased the file: nothing is installed, and the next start reads afresh.
    func forget() {
        generation += 1
        canaryManifest = nil
        loaded = false
    }

    /// [served] verified again; one that no longer verifies is retired.
    private func verified(_ served: [UInt8]) -> CanaryManifestView? {
        do {
            return CanaryManifestView(served: served, manifest: try verifier.verify(served))
        } catch {
            store.retire(served)
            return nil
        }
    }

    // MARK: - CanaryManifestRepository

    public func checkCanaryManifest(_ served: [UInt8]) async throws -> CanaryManifestView {
        CanaryManifestView(served: served, manifest: try await check(served))
    }

    public func installCanaryManifest(_ served: [UInt8]) async throws -> CanaryManifestView {
        let g = generation
        let v = CanaryManifestView(served: served, manifest: try await check(served))
        // A wipe ran during the checks: nothing of this phone's is written after it.
        guard g == generation else { throw VaultFailure(.other, code: "wiped") }
        do {
            try store.save(served)
        } catch {
            throw VaultFailures.map(error)
        }
        loaded = true
        canaryManifest = v
        return v
    }

    public func removeCanaryManifest() {
        store.clear()
        canaryManifest = nil
    }

    // MARK: - The installation checks (§11.10.1 "Installation")

    /// The size, then the signature under a pinned key and the strict format (nothing is fetched for a document this
    /// build refuses anyway; chosen; not in the spec), then the serial rules against this phone's serial and the
    /// published manifest's.
    private func check(_ served: [UInt8]) async throws -> ReleaseManifest {
        guard served.count <= ReleaseManifest.maxServed else { throw Self.refused(CanaryManifestCodes.tooLarge) }
        do {
            _ = try verifier.verify(served)
        } catch {
            throw Self.refusal(error)
        }
        let used = try await seenSerial()
        let publishedSerial = try await self.publishedSerial()
        do {
            return try CanaryManifests.check(verifier: verifier, served: served, seen: used, published: publishedSerial)
        } catch {
            throw Self.refusal(error)
        }
    }

    private func seenSerial() async throws -> UInt64 {
        do {
            return try await seen()
        } catch {
            throw Self.refused(CanaryManifestCodes.unchecked, cause: error)
        }
    }

    /// The published manifest's serial; nil only when nothing is published yet (a 404, before a channel's first
    /// release). Any other failure to read it, or a published manifest that fails verification, refuses the
    /// installation ("It could not be checked. Try again."): the check is what keeps a stale canary out (the owner's
    /// decision, vettid-ios #67; §11.10.1 would install, and vettid-android is changed to match).
    private func publishedSerial() async throws -> UInt64? {
        let doc: [UInt8]
        do {
            doc = try await published()
        } catch let e as MemberApiError where e.status == 404 && e.code == MemberApiError.manifestUnavailable {
            return nil
        } catch {
            throw Self.refused(CanaryManifestCodes.unchecked, cause: error)
        }
        do {
            return try verifier.verify(doc).serial
        } catch {
            throw Self.refused(CanaryManifestCodes.unchecked, cause: error)
        }
    }

    private static func refused(_ code: String, cause: (any Error)? = nil) -> VaultFailure {
        VaultFailure(.manifest, code: code, cause: cause)
    }

    /// The refusal of [e], an ``AttestationError`` (signature, key, format) or a ``CanaryManifestError`` (serial rules).
    private static func refusal(_ e: any Error) -> VaultFailure {
        if let c = e as? CanaryManifestError {
            return refused(c == .older ? CanaryManifestCodes.older : CanaryManifestCodes.published, cause: c)
        }
        switch (e as? AttestationError)?.kind {
        case .manifestKey?, .signature?: return refused(CanaryManifestCodes.signature, cause: e)
        default: return refused(CanaryManifestCodes.format, cause: e)
        }
    }
}
