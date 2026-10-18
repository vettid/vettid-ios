import Foundation
import Observation
import VettIDData

/// A screen that loads one value: loading, the value, or a failure. Mirrors vettid-android `LoadState`.
public struct LoadState<T: Equatable & Sendable>: Equatable, Sendable {
    public var loading: Bool
    public var value: T?
    public var error: FailureKind?

    public init(loading: Bool = true, value: T? = nil, error: FailureKind? = nil) {
        self.loading = loading
        self.value = value
        self.error = error
    }

    /// [load]'s value, or its failure.
    @MainActor static func of(_ load: @MainActor () async throws -> T) async -> LoadState {
        do {
            return LoadState(loading: false, value: try await load())
        } catch {
            return LoadState(loading: false, error: failureKind(error))
        }
    }
}

/// Vault status: the member API's advisory status and the vault's own `vault.status`. Mirrors vettid-android
/// `VaultStatusViewModel`.
@MainActor
@Observable
public final class VaultStatusViewModel {
    public private(set) var state = LoadState<VaultOverview>()

    @ObservationIgnored private let vault: any VaultRepository
    @ObservationIgnored private let work = Work()

    public init(vault: any VaultRepository) {
        self.vault = vault
        load()
    }

    deinit { work.cancelAll() }

    public func load() {
        state.loading = true
        state.error = nil
        // The model is held only to write the answer back: a screen that went away cancels the read.
        let vault = vault
        work.launch { [weak self] in
            let s = await LoadState.of { try await vault.overview() }
            self?.state = s
        }
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}

/// Attestation details: this phone's key and the enclave release last verified, and the canary manifest when one is
/// installed (VAULT-RELEASES §10.1 step 9: only on VettID's test phones). Mirrors vettid-android `AttestationViewModel`.
@MainActor
@Observable
public final class AttestationViewModel {
    public private(set) var state = LoadState<AttestationInfo>()

    @ObservationIgnored private let vault: any VaultRepository
    @ObservationIgnored private let canaryManifests: (any CanaryManifestRepository)?
    @ObservationIgnored private let work = Work()

    deinit { work.cancelAll() }

    public init(vault: any VaultRepository, canary: (any CanaryManifestRepository)? = nil) {
        self.vault = vault
        canaryManifests = canary
        work.launch { [weak self] in
            let s = await LoadState.of { try await vault.attestationInfo() }
            self?.state = s
        }
    }

    /// The installed canary manifest, or nil (then nothing about it is shown).
    public var canary: CanaryManifestView? { canaryManifests?.canaryManifest }

    /// Stops using the canary manifest: the published one is used again.
    public func removeCanary() { canaryManifests?.removeCanaryManifest() }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
