import Foundation
import VettIDAltChan
import VettIDAttestation
import VettIDVault

/// (IOS-PLAN §4.3) An unconfirmed move as the screens see it: the release it left ([from], "release N"), the one it moved
/// to ([to], "N+1"), and whether an unlock on [to] has failed for a reason that is not the member's ([failed]: the unlock
/// screen offers "Return to release N").
public struct UnconfirmedMove: Equatable, Sendable {
    public var from: ReleaseView
    public var to: ReleaseView
    public var failed: Bool

    public init(from: ReleaseView, to: ReleaseView, failed: Bool) {
        self.from = from
        self.to = to
        self.failed = failed
    }

    init(_ m: MoveUnconfirmed) {
        from = ReleaseView(number: m.from.number, pcr0: m.from.pcr0, status: "", endsAt: nil, notes: "")
        to = ReleaseView(number: m.to.number, pcr0: m.to.pcr0, status: "", endsAt: nil, notes: "")
        failed = m.failed
    }
}

// The way back to release N after leaving or a restart (IOS-PLAN §4.3, ANDROID-PLAN §4; VAULT-MESSAGING §11.10.4,
// §11.10.6). The marker lives in the device's release records (``AltState/moveUnconfirmed``), written with the new
// release at `update: moved` and cleared by any later opening (``AltRequests/applyUnlock(_:_:_:)``); here: `failed` set
// when the new release fails, the other clearings (`vault.release`, `wrong_release`, release N no longer available), and
// "Return to release N" from the unlock screen, which runs the release update's way back.
extension VaultManager {
    /// The way back's code when release N refused it with `wrong_release`: the move was already confirmed.
    public nonisolated static let codeReturnConfirmed = "wrong_release"
    /// The way back's code when release N can no longer be reached for it (`410 release_unavailable`, or N no longer in
    /// the trusted manifest).
    public nonisolated static let codeReturnUnavailable = "return_unavailable"
    /// The `sync.event` kind a vault sends after it first runs under a new release (§11.10.6).
    nonisolated static let kindVaultRelease = "vault.release"

    /// Whether [routed] is exactly the release the unconfirmed move of [state] left (number and PCR0).
    nonisolated static func routedToMoveOrigin(_ routed: Release, _ state: AltState) -> Bool {
        guard let m = state.moveUnconfirmed else { return false }
        return routed.pcr0 == m.from.pcr0 && routed.number == m.from.number
    }

    /// The codes of N+1's own failures (§4.3 point 2): it did not start in time (`release_starting` past its waits, a
    /// `503 vault_unavailable`), the route kept naming N, or its enclave answered an error decided before the PIN.
    nonisolated static let newReleaseFailureCodes: Set<String> = [
        MemberApiError.releaseStarting, MemberApiError.vaultUnavailable, codeReleaseNotRouted,
        "retry", "release_key", "vault_missing", "wrong_release",
    ]

    /// (§4.3 point 2) A failure of the new release, not the member's, listed: N+1 ended (`410 release_unavailable`),
    /// its instance did not verify, the unlock got no answer, or one of ``newReleaseFailureCodes``. Nothing else: never a
    /// wrong PIN, the backoff, a missing connection, a locked iPhone, a held change, this phone's own keys, records or
    /// attestation, or a cancellation.
    nonisolated static func failsNewRelease(_ a: UnlockAttempt) -> Bool {
        guard case .failed(let kind, let code, _) = a else { return false }
        switch kind {
        case .releaseEnded, .enclave, .releaseUnknown, .noResponse: return true
        case .vaultUnavailable, .retry, .other: return code.map(newReleaseFailureCodes.contains) ?? false
        default: return false
        }
    }

    /// After an unlock: `failed` set (once) when the new release failed (§4.3 point 2), never for the way back itself;
    /// the screens' copy of the marker read again.
    func noteMoveOutcome(_ a: UnlockAttempt, abandoning: Bool) async {
        defer { readMoveMarker() }
        guard !abandoning, Self.failsNewRelease(a), let d = session?.device, d.altState.moveUnconfirmed?.failed == false else {
            return
        }
        _ = try? await d.changeMoveMarker { a in
            var s = a
            if s.moveUnconfirmed != nil { s.moveFailed = true }
            return s
        }
    }

    /// The marker cleared (§4.3 point 4): the move was confirmed, or the way back can no longer be taken.
    func clearMoveMarker() async {
        guard let d = session?.device, d.altState.moveUnconfirmed != nil else { return }
        _ = try? await d.changeMoveMarker { $0.withoutMove() }
        readMoveMarker()
    }

    /// The screens' copy of the marker, from the device's records.
    func readMoveMarker() {
        let m = session?.device.altState.moveUnconfirmed.map(UnconfirmedMove.init)
        if m != unconfirmedMove { unconfirmedMove = m }
    }

    /// `sync.event{kind: "vault.release"}` naming the release moved to (or a later one): the move is confirmed.
    func syncRelease(_ m: VaultMessage) {
        let o = m.object
        guard VaultJSON.string(o, "kind") == Self.kindVaultRelease, let marker = session?.device.altState.moveUnconfirmed else {
            return
        }
        let release = VaultJSON.string(o, "release")
        let number = VaultJSON.int(o, "release_number").map { UInt64(max($0, 0)) } ?? 0
        guard release == marker.to.pcr0 || number >= marker.to.number else { return }
        Task { [weak self] in await self?.clearMoveMarker() }
    }

    /// The way back's own outcomes (§4.3 point 4): `wrong_release` from N (the move is confirmed for good), and N no
    /// longer reachable for it; both clear the marker. Nil for every other outcome.
    func returnEnded(_ a: UnlockAttempt) async -> UpdateStepResult? {
        guard case .failed(let kind, let code, _) = a else { return nil }
        if code == Self.codeReturnConfirmed {
            await clearMoveMarker()
            return .failed(kind, code: Self.codeReturnConfirmed)
        }
        // `410` for `?release=` N's PCR0 is the member API's answer for N itself; a release the manifest does not know is
        // whatever instance was served, so it ends the way back only when N itself is no longer in the trusted manifest.
        var ended = kind == .releaseEnded
        if kind == .releaseUnknown { ended = await moveOriginListed() == false }
        if ended {
            await clearMoveMarker()
            return .failed(kind, code: Self.codeReturnUnavailable)
        }
        return nil
    }

    /// Whether the trusted manifest lists release N (the marker's `from`, number and PCR0); nil without a marker or when
    /// the manifest cannot be read.
    func moveOriginListed() async -> Bool? {
        guard let s = session, s.device.altState.moveUnconfirmed != nil,
              let m = try? await s.alt.manifest(seen: s.device.altState.manifestSerial)
        else { return nil }
        return await pruneMoveMarker(m)
    }

    /// (§4.3 point 4) Each time the trusted manifest is read: release N gone from it ends the way back. Whether N is
    /// listed (true without a marker).
    @discardableResult
    func pruneMoveMarker(_ m: ReleaseManifest) async -> Bool {
        guard let marker = session?.device.altState.moveUnconfirmed else { return true }
        let listed = m.byPcr0(marker.from.pcr0)?.number == marker.from.number
        if !listed { await clearMoveMarker() }
        return listed
    }

    /// (§4.3 point 3) "Return to release N" on the unlock screen, confirmed, with the unlock screen's PIN: the way back
    /// as on the update screen, shown over every phase (``ReleaseUpdateManager/returnToPrevious(pin:generation:)``).
    /// False when it cannot start (no marker with `failed`, a step running, a change held).
    @discardableResult
    public func returnToPreviousRelease(pin: String) -> Bool {
        releaseUpdate.returnToPrevious(pin: pin, generation: nil)
    }
}
