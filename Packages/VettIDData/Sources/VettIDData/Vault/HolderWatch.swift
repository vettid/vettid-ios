import Foundation
import VettIDAltChan
import VettIDVault

/// What may tell the app that this phone no longer holds the vault, and which of it is proof (owner decision,
/// 2026-10-05: a replaced phone erases itself). A wipe destroys the only local copy of the credential, so only messages
/// the app has authenticated count. Mirrors vettid-android `HolderSignal`.
public enum HolderSignal: Equatable, Sendable {
    /// A vault message the device opened under its session with the vault (§5, §10.3), from the vault's relay key.
    case vaultEvent(type: String, reason: String?)
    /// The enclave's `vault.unlock.result` (§11.4), opened with this device's KEM key: sealed to it and answering this
    /// request's id, which travelled only inside the request sealed to the attested enclave.
    case sealedUnlockResult(ok: Bool, code: String?)
    /// Everything else: network errors, timeouts, HTTP statuses of the member API or the relay (relay token errors
    /// included), unreadable or unparseable results, vault error responses. Never proof.
    case failure(kind: FailureKind, code: String?)
}

/// Which ``HolderSignal``s prove that this phone was replaced. Mirrors vettid-android `HolderPolicy`.
public enum HolderPolicy {
    public static let deviceUnlinked = "device.unlinked"
    public static let reasonTransferred = "transferred"
    public static let reasonReplaced = "replaced"
    public static let codeUnknownDevice = "unknown_device"

    /// - `device.unlinked{reason: "transferred"}`: the vault completed a direct transfer (§6.7.1 step 4).
    /// - `device.unlinked{reason: "replaced"}`: a recovery completed on another phone (§11.11.5 step 3).
    /// - a sealed unlock result `unknown_device` (§11.4). (A conforming enclave answers an unknown device with random
    ///   bytes instead, which the app cannot read: that is a ``HolderSignal/failure(kind:code:)``.)
    ///
    /// Other `device.unlinked` reasons (`vault_deleted`, none) are not a replacement.
    public static func proves(_ s: HolderSignal) -> Bool {
        switch s {
        case .vaultEvent(let type, let reason): type == deviceUnlinked && (reason == reasonTransferred || reason == reasonReplaced)
        case .sealedUnlockResult(let ok, let code): !ok && code == codeUnknownDevice
        case .failure: false
        }
    }

    public static func of(_ m: VaultMessage) -> HolderSignal { .vaultEvent(type: m.type, reason: VaultJSON.string(m.object, "reason")) }

    public static func of(_ r: UnlockResult) -> HolderSignal { .sealedUnlockResult(ok: r.ok, code: r.code) }

    public static func of(_ e: VaultFailure) -> HolderSignal { .failure(kind: e.kind, code: e.code) }
}

/// Runs [wipe] once per proof (``HolderPolicy``) and lets a direct transfer's approval wait for the vault's confirmation.
/// The vault manager feeds it every vault event, every sealed unlock result and every failure. Mirrors vettid-android
/// `HolderWatch`.
@MainActor
final class HolderWatch {
    private let wipe: @MainActor () async -> Void
    private let gate = AsyncGate()
    private var waiters: [KickableWait] = []

    /// How many wipes this process ran.
    private(set) var count = 0

    init(wipe: @escaping @MainActor () async -> Void) {
        self.wipe = wipe
    }

    /// A vault event (§10.3). The wipe runs in a task of its own: the event observer that delivers this is stopped by the
    /// wipe. Returns whether the event proves a replacement.
    @discardableResult
    func onVaultEvent(_ signal: HolderSignal) -> Bool {
        let proof = HolderPolicy.proves(signal)
        if proof {
            let seen = count
            Task { @MainActor [weak self] in await self?.wipeOnce(seen) }
        }
        return proof
    }

    /// A sealed unlock result of this phone (§11.4); wipes before returning when it proves a replacement.
    func onSealedUnlockResult(_ signal: HolderSignal) async -> Bool {
        let proof = HolderPolicy.proves(signal)
        if proof { await wipeNow() }
        return proof
    }

    /// A failure: never proof (here so that every path goes through the policy).
    func onFailure(_ e: VaultFailure) -> Bool { HolderPolicy.proves(HolderPolicy.of(e)) }

    /// The old phone's approval of a direct transfer (§6.7.1 step 3, I3.3): [approve] is the `device.transfer.approve`
    /// request; its `{}` does not prove completion, so this then waits up to [wait] for the vault's
    /// `device.unlinked{transferred}` (which wipes). True when the wipe happened.
    func approveTransfer(
        wait: Duration, sleep: @escaping LockSleep = realLockSleep, approve: @MainActor () async throws -> Void
    ) async rethrows -> Bool {
        let before = count
        try await approve()
        if count > before { return true }
        let w = KickableWait()
        waiters.append(w)
        defer { waiters.removeAll { $0 === w } }
        await w.wait(wait, sleep: sleep)
        return count > before
    }

    /// Wipes now (or waits for the wipe that already runs): after a proof, or on the member's confirmed "Erase VettID from
    /// this phone", which needs no proof.
    func wipeNow() async { await wipeOnce(count) }

    /// One wipe per proof received before it: a proof that arrived while a wipe ran waits for it and does nothing more.
    private func wipeOnce(_ seen: Int) async {
        await gate.withLock {
            guard count == seen else { return }
            await wipe()
            count = seen + 1
            for w in waiters { w.kick() }
        }
    }
}
