import CryptoKit
import Foundation
import VettIDCrypto
@testable import VettIDData
import VettIDKeys
import VettIDKeysTesting

/// A clock the tests move (Unix ms).
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Int64

    static let day: Int64 = 24 * 60 * 60 * 1000

    init(_ ms: Int64 = 1_800_000_000_000) {
        self.ms = ms
    }

    var nowMs: Int64 {
        get { lock.withLock { ms } }
        set { lock.withLock { ms = newValue } }
    }

    func advance(_ by: Int64) { nowMs += by }

    var date: Date { Date(timeIntervalSince1970: Double(nowMs) / 1000) }
}

/// One phone: the software phone key, the records file in a fresh directory, a clock. [reopen] is the same phone after
/// the app was killed and started again (same key, same file).
final class TestPhone: @unchecked Sendable {
    let keys: SoftwarePhoneSecretSource
    let fileKeys = InMemoryFileKeyHolder()
    let protectedData = ProtectedDataFlag(available: true)
    let clock = TestClock()
    let url: URL
    private(set) var secrets: PhoneSecrets
    private let ephemeral: @Sendable () -> P256.KeyAgreement.PrivateKey

    init(
        keys: SoftwarePhoneSecretSource = SoftwarePhoneSecretSource(),
        ephemeral: @escaping @Sendable () -> P256.KeyAgreement.PrivateKey = { P256.KeyAgreement.PrivateKey() }
    ) throws {
        self.keys = keys
        self.ephemeral = ephemeral
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vettid-data-tests/\(UUID().uuidString)/VettID/phone-secrets")
        secrets = Self.make(keys, fileKeys, protectedData, clock, url, ephemeral)
    }

    /// The app killed and started again: a new `PhoneSecrets` over the same key and file.
    func reopen() {
        ChangesInFlight.forgetAll(url)
        secrets = Self.make(keys, fileKeys, protectedData, clock, url, ephemeral)
    }

    private static func make( // swiftlint:disable:this function_parameter_count
        _ keys: SoftwarePhoneSecretSource, _ fileKeys: InMemoryFileKeyHolder, _ protectedData: ProtectedDataFlag, _ clock: TestClock,
        _ url: URL, _ ephemeral: @escaping @Sendable () -> P256.KeyAgreement.PrivateKey
    ) -> PhoneSecrets {
        let store = EncryptedFileStore(url: url, purpose: PhoneSecrets.purpose, keys: fileKeys, protectedData: protectedData)
        return PhoneSecrets(keys: keys, store: store, now: { clock.date }, ephemeral: ephemeral)
    }

    var records: PhoneRecords { get throws { try secrets.records() } }
}

/// A vault that follows vettid-vault `vault/opendek.go` for the secret (§11.14.1, §11.14.2): `secret_check` and, while a
/// change is pending, `secret_check_next`; `device_secret` before the PIN; `bad_pin`; the current wrap drops a pending
/// `next` part, the next wrap completes it. A change whose state write is stored replaces the current secret.
final class OpenDEKVault: @unchecked Sendable {
    let vaultID = "test-vault-0001"
    let pepper = [UInt8](repeating: 0x32, count: 32)
    let pin = "123456"
    private(set) var secretCheck: [UInt8] = []
    private(set) var nextCheck: [UInt8]?
    /// The new phone of a transfer whose state write is not stored: the next wrap answers `transfer_incomplete`.
    var transferIncomplete = false
    /// Every unlock request it received.
    private(set) var unlocks = 0
    private(set) var changes = 0

    func check(_ secret: [UInt8]) -> [UInt8] {
        hmacSHA256(key: pepper, Array("vettid/vms/2/unlock-secret-check".utf8) + [0] + Array(vaultID.utf8) + [0] + secret)
    }

    func enroll(_ secret: [UInt8]) {
        precondition(secret.count == 32)
        secretCheck = check(secret)
        nextCheck = nil
    }

    func unlock(_ secret: [UInt8], pin: String? = nil) -> UnlockAnswer {
        unlocks += 1
        let c = check(secret)
        let cur = c == secretCheck
        let next = nextCheck == c
        guard cur || next else { return .refused(UnlockEpoch.deviceSecret) }
        guard (pin ?? self.pin) == self.pin else { return .refused("bad_pin") }
        if next {
            if transferIncomplete { return .refused(UnlockEpoch.transferIncomplete) }
            secretCheck = c
        }
        nextCheck = nil
        return .opened
    }

    enum ChangeFate {
        /// Stored and answered.
        case answered
        /// Stored (the state under the new secret), the answer lost.
        case lostAfterStoring
        /// The header has the `next` part, the state write never happened; the answer lost.
        case lostMidway
        /// The request never reached the vault.
        case neverArrived
    }

    /// A `pin.change` or `vault.secret.renew` carrying [next]; throws `noResponse` unless answered.
    func change(_ next: [UInt8], _ fate: ChangeFate) throws -> UnlockAnswer {
        precondition(next.count == 32)
        switch fate {
        case .answered, .lostAfterStoring:
            changes += 1
            secretCheck = check(next)
            nextCheck = nil
        case .lostMidway:
            changes += 1
            nextCheck = check(next)
        case .neverArrived:
            break
        }
        guard fate == .answered else { throw VaultFailure(.noResponse) }
        return .opened
    }

    /// An operator restore of the state from before a change (§11.14.2).
    func restore(to secret: [UInt8]) {
        secretCheck = check(secret)
        nextCheck = nil
    }
}

extension PhoneSecrets {
    /// A change sent to [vault] with [fate]; nil when no answer came.
    @discardableResult
    func renew(_ vault: OpenDEKVault, operation: String, _ fate: OpenDEKVault.ChangeFate) async throws -> UnlockAnswer? {
        do {
            return try await change(operation: operation, send: { try vault.change($0, fate) }, confirmed: { $0.ok })
        } catch let f as VaultFailure where f.kind == .noResponse {
            return nil
        }
    }

    func unlock(_ vault: OpenDEKVault, pin: String? = nil) async throws -> UnlockAnswer {
        try await unlock { vault.unlock($0, pin: pin) }
    }
}

/// The JSON fixture of `Resources/reference`.
struct ReferenceDoc {
    let o: JsonObject

    /// From the source tree, as `FailureTextTests` reads `Localizable.xcstrings`.
    static func load(_ name: String) throws -> ReferenceDoc {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/reference").appendingPathComponent(name)
        return ReferenceDoc(o: try StrictJson.parseObject(Array(try Data(contentsOf: url))))
    }

    func hex(_ name: String) throws -> [UInt8] { try Bytes.unhex(try o.string(name)) }
}

extension JsonObject {
    func hex(_ name: String) throws -> [UInt8] { try Bytes.unhex(try string(name)) }
}

extension PhoneSecrets {
    /// An epoch 1 whose operation succeeded (the enrollment answered, the transfer or the recovery done).
    @discardableResult
    func createConfirmed(keyVault: String) throws -> [UInt8] {
        let s = try create(keyVault: keyVault)
        try confirmCreate(id: s.id)
        return s.secret
    }
}

/// The record's fields on an entry, for short expectations.
extension PhoneRecords.Entry {
    var epoch: UInt64 { record.epoch }
    var keyVault: String { record.keyVault }
    var check: [UInt8] { record.check }
    var ephemeral: [UInt8] { record.ephemeral }
}

extension TestPhone {
    /// Writes [recs] over the records file as they are (a test's damaged or crafted file).
    func overwriteRecords(_ recs: PhoneRecords) throws {
        try EncryptedFileStore(url: url, purpose: PhoneSecrets.purpose, keys: fileKeys, protectedData: protectedData).save(recs.marshal())
    }
}
