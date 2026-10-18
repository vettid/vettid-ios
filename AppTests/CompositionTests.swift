import CryptoKit
import Foundation
import Testing
import VettIDAltChan
import VettIDData
import VettIDKeys
import VettIDRelay
import VettIDTesting
@testable import VettID

/// The app's wiring (IOS-PLAN §5, §6.1): the vault manager talks to this build's environment, the first-run cleanup ran
/// at launch, the keys are the Secure Enclave's and App Attest where the device has them, and without them (the
/// simulator) every setup is refused before anything is sent.
@MainActor
@Suite struct CompositionTests {
    @Test func theManagerUsesTheBuildsEnvironment() {
        let c = AppComposition.shared
        #expect(c.vault.apiOrigin == AppEnvironment.current.apiOrigin)
        #expect(c.firstRun.isOpen, "the first-run cleanup ran at launch")
    }

    /// A start that could not read this phone's state (the iPhone locked) is read again when the app becomes active or
    /// protected data becomes available; no other phase is.
    @Test func onlyAStartThatReadNothingIsReadAgain() {
        #expect(AppRoot.readsAgain(.starting))
        #expect(AppRoot.readsAgain(.unreachable(.phoneLocked)))
        #expect(AppRoot.readsAgain(.unreachable(.phoneLocked, longUnreachable: true)))
        for p: AppPhase in [.signedOut, .setup(.newVault), .locked, .unlocked, .unreachable(.network)] {
            #expect(!AppRoot.readsAgain(p), "\(p)")
        }
    }

    /// The Secure Enclave's keys and App Attest wherever the device has a Secure Enclave (App Attest refuses each call
    /// itself where it is unsupported); the refusing placeholder elsewhere.
    @Test func theKeysAreTheSecureEnclavesWhereThereIsOne() {
        let h = AppComposition.shared.hardware
        #if targetEnvironment(simulator)
        #expect(!HardwareKeys.available)
        #else
        #expect(HardwareKeys.available == SecureEnclave.isAvailable)
        #endif
        if HardwareKeys.available {
            #expect(h.appKeys is SecureEnclaveAppKeyStore && h.seedWrap is SecureEnclaveSeedWrapKeySource)
            #expect(h.phone is SecureEnclavePhoneSecretSource && h.phone.sourceID == SecureEnclavePhoneSecretSource.tag)
            #expect(h.attester is AppAttestAttester && h.appLock is SecureEnclaveAppLockKeys)
        } else {
            #expect(h.appKeys is NoSecureHardware && h.attester is NoSecureHardware && h.appLock is NoAppLockKeys)
        }
    }

    /// IOS-PLAN ID17: without a Secure Enclave the app lock cannot be turned on, and it is off. (On an iPhone turning it on
    /// shows Face ID: the owner's manual checklist.)
    @Test(.enabled(if: !HardwareKeys.available))
    func theAppLockIsOffWithoutASecureEnclave() async {
        let c = AppComposition.shared
        c.startAppLock()
        #expect(c.appLock.state == .disabled)
        await #expect(throws: KeysError.noSecureHardware) { _ = try await c.appLock.enable(.biometrics, reason: "Unlock VettID") }
        #expect(c.appLock.state == .disabled)
    }

    /// A wipe erases the app's data directory (the wipe's marker in it), its caches and temporary files, and every
    /// keychain item and key; the first-run cleanup's marker stays.
    @Test func theWipeErasesTheAppsDirectoriesAndKeys() throws {
        let data = try AppDirectories.data()
        let t = AppWipeTargets(data: data, hardware: [NoSecureHardware(sourceID: "test")])
        #expect(t.dirs == [data] && t.scratch.count == 4)
        #expect(t.marker.deletingLastPathComponent() == data)
        #expect(t.kept == [data.appendingPathComponent(FirstRunCleanup.markerName)])
        #expect(t.erasers.first is KeychainEraser)
    }

    /// The placeholder never declares keys missing on an iPhone (where it may stand in for keys it cannot see): its
    /// lookups are refused for now there, and missing only on the simulator.
    @Test func thePlaceholderNeverDeclaresKeysMissingOnAnIPhone() throws {
        let h = NoSecureHardware(sourceID: "test")
        #if targetEnvironment(simulator)
        #expect(isMissing((h as any AppKeyStore).lookup()) && isMissing(h.lookup(keyVault: "v", keyID: "k")))
        #expect(try h.keyNames().isEmpty)
        #else
        #expect(isUnavailable((h as any AppKeyStore).lookup()) && isUnavailable(h.lookup(keyVault: "v", keyID: "k")))
        #expect(throws: KeysError.unavailable("phone keys")) { _ = try h.keyNames() }
        #expect(KeysUsableCheck.appKey(h) == .unavailable)
        #endif
    }

    @Test func theSecureHardwarePlaceholderRefusesEverything() {
        let h = NoSecureHardware(sourceID: "test")
        #expect(throws: KeysError.noSecureHardware) { _ = try (h as any AppKeyStore).getOrCreate() }
        #expect(throws: KeysError.noSecureHardware) { _ = try (h as any SeedWrapKeySource).getOrCreate() }
        #expect(throws: KeysError.noSecureHardware) { _ = try h.create(keyVault: "v") }
        #expect(throws: KeysError.noSecureHardware) { _ = try h.attest([1]) }
        #expect(throws: KeysError.noSecureHardware) { _ = try h.assert(.challenge([1])) }
    }

    /// A setup code is refused with "This phone cannot keep your vault's keys in its secure hardware." and nothing
    /// reaches the member API.
    @Test func aSetupIsRefusedBeforeAnythingIsSent() async throws {
        let server = FakeHTTPServer()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vettid-composition-tests/\(UUID().uuidString)")
        let h = NoSecureHardware(sourceID: "test-\(UUID().uuidString)")
        let on = ProtectedDataFlag(available: true)
        let m = VaultManager(config: VaultManagerConfig(
            apiOrigin: server.baseURL, manifestURL: server.baseURL + MemberApiClient.manifestPath, relayURL: server.baseURL,
            trust: .production, transport: HTTPTransport(session: server.session), directory: dir,
            keys: VaultKeys(appKeys: h, seedWrap: h, wrapped: InMemoryWrapped(), phone: h, files: InMemoryFiles()),
            attester: h, protectedData: on, enrolledAttestation: .nitro(roots: []), deviceName: "iPhone", prepare: {}
        ))
        do {
            _ = try await m.redeemSetupCode(.secret("AbCdEfGhIjKlMnOpQrStUv"))
            Issue.record("redeemed")
        } catch let f as VaultFailure {
            #expect(f.kind == .hardwareKeys)
        }
        #expect(server.requestCount == 0)
    }
}

/// Wrapped seeds in memory (the keychain's are the app's own, not a test's).
private final class InMemoryWrapped: WrappedKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [KeySlot: [UInt8]] = [:]

    func get(_ slot: KeySlot) throws -> [UInt8]? { lock.withLock { blobs[slot] } }
    func put(_ slot: KeySlot, _ blob: [UInt8]) throws { lock.withLock { blobs[slot] = blob } }
    func remove(_ slot: KeySlot) throws { _ = lock.withLock { blobs.removeValue(forKey: slot) } }
}

/// The file key in memory.
private final class InMemoryFiles: FileKeyHolder, @unchecked Sendable {
    private let stored = SymmetricKey(size: .bits256)

    func key() throws -> SymmetricKey { stored }
    func deleteAll() throws {}
}
