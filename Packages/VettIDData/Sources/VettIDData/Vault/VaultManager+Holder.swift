import Foundation
import VettIDVault

// Another phone became the holder (VAULT-MESSAGING 0.51.1; IOS-PLAN 0.1.13 §6.3; ANDROID-PLAN 0.1.55): a `forbidden`
// answer from the vault to any request that decides an unresolved change, renew or reset (the resend of the same request,
// `credential.version`, `credential.get`, `credential.ack`, `credential.utk.get`, …), also after `credential.version`
// showed "applied", ends it. Only the vault's own answer counts: a ``VaultOpError`` with that code, opened under the
// device's session and answering that request's id. A transport error, a timeout, an HTTP status, an error of the relay,
// the member API or the host, or an answer that does not open is no answer: the marker stays ("unreachable"). Nothing is
// erased: this answer is not a proof that the phone was replaced (``HolderPolicy``); the keys and local state stay until
// the vault's own `device.unlinked{transferred|replaced}`.
extension VaultManager {
    /// The code of a change ended because the vault answered `forbidden` (another phone is the holder).
    public nonisolated static let codeNotHolder = "forbidden"

    /// Whether [error] is the vault's own `forbidden` answer to a request.
    nonisolated static func notHolder(_ error: any Error) -> Bool { (error as? VaultOpError)?.code == codeNotHolder }

    /// The unresolved change [marker] ends: its marker, and a PIN change's candidate, cleared in one write (the PIN is not
    /// left uncertain; the gate opens), and the one-time notice "Your vault moved to a new phone", with no "Try again".
    func notTheHolder(_ marker: UnresolvedChange) {
        try? phoneSecrets.abandonUnresolved(marker)
        if marker.operation != nil, marker.operation == pinChangeOperation { pinChangeOperation = nil }
        heldChange = nil
        changeCheck = ChangeCheck(marker.type, .notHolder)
        refreshPinStep()
    }

    /// Runs [body], a request of the decision of [marker] whose other failures change nothing; true when the vault
    /// answered it `forbidden` and the change ended (``notTheHolder(_:)``).
    func endedByForbidden(_ marker: UnresolvedChange, _ gen: Int, _ body: () async throws -> Void) async -> Bool {
        do {
            try await body()
            return false
        } catch {
            guard Self.notHolder(error), stillUnresolved(marker, gen) else { return false }
            notTheHolder(marker)
            return true
        }
    }

    /// A renew being decided before a PIN change (``settleRenews(_:)``) was answered `forbidden`: the renews' candidates
    /// go, the PIN change is refused with the same notice, and nothing is sent.
    func renewsEndedByForbidden(_ operations: Set<String>, _ error: VaultOpError) -> VaultFailure {
        try? phoneSecrets.dropCandidates(operations: operations)
        if let op = renewOperation, operations.contains(op) { renewOperation = nil }
        changeCheck = ChangeCheck(.pin, .notHolder)
        refreshPinStep()
        return VaultFailure(.other, code: Self.codeNotHolder, cause: error)
    }
}
