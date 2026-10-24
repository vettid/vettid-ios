import Foundation
import VettIDCrypto
import VettIDVault

/// The old phone's keys after a transfer it approved (release R, VAULT-MESSAGING §11.14.10; owner decision 2026-10-15):
/// kept until the vault's `device.unlinked{transferred}` (after the new phone's first unlock from storage) or for at most
/// 7 days. Mirrors vettid-android `KeptTransfer`.
public enum KeptTransfer {
    /// At most this long after the approval (in real time; divided by the vault's time scale when the approval starts it).
    public static let keepPeriodMs: Int64 = 7 * 24 * 60 * 60 * 1000

    /// (STAGING-TIME-SCALE, S10) The keep period an approval starts on a vault of [timeScale].
    public static func keepMs(timeScale: UInt64) -> Int64 { TimeScale.scaledMs(keepPeriodMs, by: timeScale) }

    public enum Decision: Equatable, Sendable {
        /// The 7 days are over: this phone's keys go.
        case erase
        /// Still kept, for [remainingMs].
        case keep(remainingMs: Int64)
    }

    /// When the 7 days count from: the approval, or now when the clock is behind it (stored, so that a clock kept behind
    /// cannot extend them at every check).
    public static func start(approvedAtMs: Int64, nowMs: Int64) -> Int64 { min(approvedAtMs, nowMs) }

    /// What an answered `device.list` says of this phone (VAULT-MESSAGING §11.14.10 "The day-7 check").
    public enum ListVerdict: Equatable, Sendable {
        /// The list holds this phone's id with kind `app`: still the vault's app (result 2).
        case stillTheApp
        /// The list does not hold this phone's id: no longer the vault's app (result 1).
        case removed
        /// No answer, no id of this phone's own, or the id with another kind: not a definite answer (result 3).
        case undecided
    }

    /// The verdict on the vault's `device.list` answer [deviceList] over this phone's session. The phone is still the vault's
    /// app only if the list holds its own device id [deviceID] with kind `app`, and no longer only if the list does not hold
    /// that id at all; the id with another kind is not a definite answer (owner decision, 2026-10-23).
    public static func verdict(deviceList: [DeviceEntry]?, deviceID: String?) -> ListVerdict {
        guard let deviceID, let deviceList else { return .undecided }
        let mine = deviceList.filter { $0.id == deviceID }
        if mine.isEmpty { return .removed }
        return mine.contains { $0.kind == "app" } ? .stillTheApp : .undecided
    }

    /// Whether an approval that failed with [kind] may still have reached the vault: no answer came. Any other failure (a
    /// refusal, the network before sending) means the transfer was not approved.
    public static func mayHaveReached(_ kind: FailureKind) -> Bool { kind == .noResponse }

    /// [approvedAtMs] and [nowMs] are wall-clock times; [keepMs] the keep period the approval started
    /// (``keepMs(timeScale:)``, kept with it: a scale learnt later does not change it). A clock set before the approval
    /// counts from now, so that it never lengthens the keep beyond the period from the moment it is noticed.
    public static func decide(approvedAtMs: Int64, nowMs: Int64, keepMs: Int64 = KeptTransfer.keepPeriodMs) -> Decision {
        let elapsed = nowMs - approvedAtMs
        if elapsed >= keepMs { return .erase }
        if elapsed < 0 { return .keep(remainingMs: keepMs) }
        return .keep(remainingMs: keepMs - elapsed)
    }
}

/// What ends "Finish the move" on the new phone (release R, §11.14.10). Mirrors vettid-android `FinishMoveProof`.
public enum FinishMoveProof {
    /// An unlock the vault answered `ok` (every `ok` comes from reading the stored header and state with this phone's own
    /// secret) whose result this phone took: not [overtaken] by a lock or a wipe meanwhile.
    public static func provedBy(resultOk: Bool, overtaken: Bool) -> Bool { resultOk && !overtaken }
}
