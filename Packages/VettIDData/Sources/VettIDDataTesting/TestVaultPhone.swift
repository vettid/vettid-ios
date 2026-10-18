#if DEBUG
import Foundation
import VettIDAltChan
import VettIDCrypto
import VettIDData
import VettIDKeys
import VettIDKeysTesting
import VettIDRelay
import VettIDVault

/// TEST ONLY. A device attestation the fake enclave does not check (the TEST iOS attester of I1.3 replaces it): an
/// iOS-shaped attestation and assertion over the challenge.
public struct TestAttester: Attester {
    public init() {}

    public func attest(_ challenge: [UInt8]) throws -> DeviceAttest {
        try DeviceAttest.iosAttestation(keyID: Bytes.sha256(challenge), attestation: Array("test-attestation".utf8))
    }

    public func assert(_ signed: AttestSigned) throws -> DeviceAssertion {
        try DeviceAssertion.iosAssertion(Bytes.sha256(signed.clientDataHash))
    }
}

/// TEST ONLY. One iPhone running the app against a ``FakeVaultService``: software keys behind the Secure Enclave's
/// protocols (VettIDKeysTesting), the encrypted files in a fresh directory, the TEST attester, the fake's manifest key
/// pinned and its enclave check, and `vault.enrolled`'s attestation skipped. ``restart()`` is the same phone after the
/// app was killed and started again (the same keys and files, a new manager).
@MainActor
public final class TestVaultPhone {
    public let service: FakeVaultService
    public let appKeys = SoftwareAppKeyStore()
    public let seedWrap = SoftwareSeedWrapKeySource()
    public let wrapped = InMemoryWrappedKeyStore()
    public let phoneKeys = SoftwarePhoneSecretSource()
    public let fileKeys = InMemoryFileKeyHolder()
    public let protectedData = ProtectedDataFlag(available: true)
    public let directory: URL
    /// What the first-run gate answers; a test sets it to make it refuse ("Unlock your iPhone").
    public var prepareFailure: (any Error & Sendable)? {
        get { gate.failure }
        set { gate.failure = newValue }
    }
    public private(set) var manager: VaultManager
    /// Moves this phone's clock (seconds ahead of the real one).
    public var clockAhead: TimeInterval {
        get { clock.ahead }
        set { clock.ahead = newValue }
    }
    private let gate = PrepareSwitch()
    private let clock = TestPhoneClock()

    public init(service: FakeVaultService) throws {
        self.service = service
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vettid-manager-tests/\(UUID().uuidString)/VettID")
        manager = VaultManager(config: try Self.config(
            service, appKeys, seedWrap, wrapped, phoneKeys, fileKeys, protectedData, directory, gate, clock
        ))
    }

    /// The app killed and started again: a new manager over the same keys and files.
    public func restart() throws {
        manager.stopCollecting()
        manager = VaultManager(config: try Self.config(
            service, appKeys, seedWrap, wrapped, phoneKeys, fileKeys, protectedData, directory, gate, clock
        ))
    }

    /// Stops the mailbox collection (the end of a test).
    public func close() { manager.stopCollecting() }

    // swiftlint:disable:next function_parameter_count
    private static func config(
        _ service: FakeVaultService, _ appKeys: SoftwareAppKeyStore, _ seedWrap: SoftwareSeedWrapKeySource,
        _ wrapped: InMemoryWrappedKeyStore, _ phoneKeys: SoftwarePhoneSecretSource, _ fileKeys: InMemoryFileKeyHolder,
        _ protectedData: ProtectedDataFlag, _ directory: URL, _ gate: PrepareSwitch, _ clock: TestPhoneClock
    ) throws -> VaultManagerConfig {
        VaultManagerConfig(
            apiOrigin: service.api.baseURL,
            manifestURL: service.api.baseURL + MemberApiClient.manifestPath,
            relayURL: service.relay.baseURL,
            trust: try service.trust,
            transport: HTTPTransport(session: service.api.session, sleep: { _ in }),
            directory: directory,
            keys: VaultKeys(appKeys: appKeys, seedWrap: seedWrap, wrapped: wrapped, phone: phoneKeys, files: fileKeys),
            attester: TestAttester(),
            protectedData: protectedData,
            // The fake's "attestation" is the nonce of the request that made the vault: checked as the document's is.
            enrolledAttestation: .verify { doc, _, nonce, _, _ in
                guard doc == nonce else { throw KeysError.invalid("enrolled nonce") }
            },
            enclaveCheck: FakeVaultService.enclaveCheck,
            deviceName: "iPhone",
            prepare: { try gate.check() },
            pollWait: 1,
            requestTimeout: 5,
            enrolledGrace: 0.5,
            now: { clock.now }
        )
    }
}

/// A test phone's clock: the real one, moved ahead.
final class TestPhoneClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0

    var ahead: TimeInterval {
        get { lock.withLock { offset } }
        set { lock.withLock { offset = newValue } }
    }

    var now: Date { Date().addingTimeInterval(ahead) }
}

/// The first-run gate of a test phone: open unless a test sets a failure.
final class PrepareSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (any Error & Sendable)?

    var failure: (any Error & Sendable)? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    func check() throws {
        if let failure { throw failure }
    }
}
#endif
