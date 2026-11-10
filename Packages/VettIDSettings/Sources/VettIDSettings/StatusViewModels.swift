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

/// Vault status's Credential key row (ANDROID-PLAN 0.1.119 §4 "Owner check and status"; VAULT-MESSAGING 0.83.8 §10.8):
/// never blank, and never an old value without saying so. Mirrors vettid-android `CredentialKeyUi`.
public enum CredentialKeyRow: Equatable, Sendable, CustomStringConvertible {
    /// `credential.version` is being asked.
    case loading
    /// The vault could not be asked right now (an error, a timeout, a locked vault): "Try again" asks again.
    case unknown
    /// `exists: false`.
    case none
    /// The fingerprint of the credential key, `e939 754d 09aa a93a`. Not a secret.
    case shown(String)

    public var description: String {
        switch self {
        case .loading: "loading"
        case .unknown: "unknown"
        case .none: "none"
        case .shown: "shown"
        }
    }
}

/// Vault status: the member API's advisory status and the vault's own `vault.status`, and the Credential key row, asked
/// on its own (``credentialKey``). Mirrors vettid-android `VaultStatusViewModel`.
@MainActor
@Observable
public final class VaultStatusViewModel {
    public private(set) var state = LoadState<VaultOverview>()
    public private(set) var credentialKey = CredentialKeyRow.loading

    @ObservationIgnored private let vault: any VaultRepository
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let followers = TaskBag()
    @ObservationIgnored private var keyAsk: Task<Void, Never>?
    /// The ``VaultRepository/credentialKeyChange`` this screen has taken into account. Compared whole, not by `seq`: a
    /// wipe or the vault's deletion clears the change, and its count starts again.
    @ObservationIgnored private var keySeen: CredentialKeyChange?

    public init(vault: any VaultRepository) {
        self.vault = vault
        keySeen = vault.credentialKeyChange
        load()
        // A create, rotate or reset answered while this screen is up: the new fingerprint, or, when the
        // answer named no key, a new ask (the old fingerprint is not shown unflagged).
        followers.add(follow(self, read: { $0.vault.credentialKeyChange }, apply: { $0.keyChanged($1) }))
    }

    deinit {
        work.cancelAll()
        followers.cancelAll()
        keyAsk?.cancel()
    }

    /// Asks `credential.version` (each time the screen opens, and Try again). A newer ask replaces an older one.
    public func loadCredentialKey() {
        keyAsk?.cancel()
        credentialKey = .loading
        let vault = vault
        keyAsk = Task { @MainActor [weak self] in
            let row: CredentialKeyRow
            do {
                let a = try await vault.credentialKey()
                row = !a.exists ? .none : a.fingerprint.map(CredentialKeyRow.shown) ?? .unknown
            } catch {
                row = .unknown
            }
            guard !Task.isCancelled else { return }
            self?.credentialKey = row
        }
    }

    private func keyChanged(_ change: CredentialKeyChange?) {
        guard let change, change != keySeen else { return }
        keySeen = change
        guard let fp = change.fingerprint else {
            loadCredentialKey()
            return
        }
        keyAsk?.cancel() // an ask still out may be older than this answer
        credentialKey = .shown(fp)
    }

    /// Back in the foreground: the key is asked again, since it may have changed meanwhile (a recovery or a move
    /// elsewhere) with no answer to this phone (chosen; not in the spec).
    public func sceneBecameActive() { loadCredentialKey() }

    /// TEST ONLY: returns once the key's ask under way has ended.
    func settleKey() async { await keyAsk?.value }

    public func load() {
        loadCredentialKey() // Try again asks the key too
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
