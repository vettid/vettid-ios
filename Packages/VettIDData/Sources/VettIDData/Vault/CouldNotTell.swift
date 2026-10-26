import Foundation
import VettIDAltChan
import VettIDKeys

/// Where a phone that could not tell whether an open recovered the vault stands (IOS-PLAN 0.1.35 §4.9; VAULT-MESSAGING 0.62.0
/// §11.14.6 "A phone that could not tell", "Two identities at most"; MEMBER-API 2.12.0).
public enum CouldNotTellStage: Equatable, Sendable {
    /// The rule does not apply: no open went out unanswered, or the recovery still shows `registered` (the phone opens again).
    case none
    /// A status read was made; the next, at least 5 minutes later with the clock checked, decides.
    case waiting(until: Date)
    /// The vault may have taken this phone: the PIN unlocks with its secret (``MoveRepository/resumeLostOk(pin:)``), first with
    /// the new identity if it registered, then with the earlier one. Two reads answered `200` (never proof of adoption by
    /// itself), or the claim answered `409 key_in_use`.
    case finishWithPin
    /// The recovery ended (two reads of `401` or `410 recovery_ended`): the member may start a new recovery on the account
    /// site and use this phone for it. The text "We could not tell whether your last attempt recovered the vault. You can
    /// start a new recovery on the account site and use this phone for it; nothing on this phone is deleted."
    case newCode
    /// A day of refusals to the unlock after `409 key_in_use` (K is the vault's `app_key`): the text "Your vault took this phone,
    /// but it cannot be unlocked right now. Contact VettID."
    case contact
    /// (IOS-PLAN 0.1.35 §4.9, "Two identities at most") The new identity's recovery ended too: the phone keeps both identities,
    /// the PIN tries the lost-ok unlock (the new identity first, then the earlier one) whenever the member asks, and a new
    /// recovery the member starts is registered with the new identity again (the code steps are offered beside the PIN).
    case unlockOrNewCode
}

/// (§4.9) A status read of the rule: what it said, and when (this phone's clock and its monotonic clock, which keeps
/// counting while the phone sleeps).
struct CouldNotTellRead: Codable, Equatable, Sendable {
    /// `true`: `401` or `410 recovery_ended`; `false`: a `200` that does not show the recovery `registered`.
    var ended: Bool
    var atMs: Int64
    var uptime: Double
    /// (IOS-PLAN 0.1.35 §4.9) A `200` that shows the recovery `registered`: the phone acts on it only with the pair too.
    var registered = false

    enum CodingKeys: String, CodingKey {
        case ended
        case atMs = "at_ms"
        case uptime
        case registered
    }

    init(ended: Bool, atMs: Int64, uptime: Double, registered: Bool = false) {
        (self.ended, self.atMs, self.uptime, self.registered) = (ended, atMs, uptime, registered)
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ended = try c.decode(Bool.self, forKey: .ended)
        atMs = try c.decode(Int64.self, forKey: .atMs)
        uptime = try c.decode(Double.self, forKey: .uptime)
        registered = try c.decodeIfPresent(Bool.self, forKey: .registered) ?? false
    }
}

/// (§4.9) What a phone that could not tell keeps, until the vault answered `ok` and the pairing completed: every identity it made
/// (its keys, its device state with its `recovery_id` and the history of its opens) and the phone-secret record. K, the app key,
/// is the phone's own and is never replaced meanwhile.
///
/// Persisted as `could_not_tell` in the account record: `identities` (oldest first, indexes into the keys `relay`, `relay2`, …
/// and the device state files `vault-device`, `vault-device-2`, …; the first is the identity of the open that could not be told),
/// the flags below, and the run of refusals. Two identities at most, the earlier one (E) and a new one (N), never a third: every
/// further recovery registers N again (IOS-PLAN 0.1.35 §4.9, owner decision of 2026-10-25).
struct CouldNotTell: Codable, Equatable, Sendable {
    /// The identities, oldest first.
    var identities: [IdentitySet]
    /// Two reads said the recovery ended: a new recovery may be started with this phone.
    var ended = false
    /// What is left is the lost-ok unlock (``CouldNotTellStage/finishWithPin``).
    var unlock = false
    /// ``unlock`` came from two reads of `200` (K may be only the vault's orphaned pending key), not from a key in use: the status
    /// is read again, and two reads of `401`/`410` make it ``ended``. It never leads to the second text (that is for a vault that
    /// took this phone, §4.9).
    var unlockByReads = false
    /// N's recovery ended too (two reads of `401`/`410` with N there): both identities are kept, the unlock with each, N first, is
    /// tried, and a new code registers N again (``ended`` and ``unlock`` are both set). Never the text of a vault that took this
    /// phone (``keyInUse``).
    var bothEnded = false
    /// The `recovery_id` of the last register POST of N, written before it is posted: every later POST for the same code is a
    /// repeat, which the member API may refuse because the first was recorded (IOS-PLAN 0.1.37 §4.9 "A failed register").
    var registerTried: String?
    /// The `recovery_id` for which a POST left N maybe registered (it got a `202`) or unknown: a `401` or a readable refusal to a
    /// later POST for it keeps N's registration.
    var registerKept: String?
    /// The unlock answered `transfer_incomplete`: only an open repeats the recovery. Both kinds of read then mean "ended" unless
    /// the recovery shows `registered`.
    var transferIncomplete = false
    /// While the unlock of other identities is tried (a trial, the unlock with each), the identity to go back to when it does not
    /// end: a kill meanwhile goes back to it (``VaultManager/settleTrial()``).
    var returnTo: IdentitySet?
    /// The floors the identities before the newest have seen (`min_state_seq`, `min_header_seq`, the release, the manifest serial),
    /// written in the same save that makes a new identity and applied to it when it is made and whenever it is used again (never
    /// below them). The device's own copy is a later save: a kill between the two is made good by the next use, which always
    /// comes before anything is registered or opened with the identity.
    var floors: AltFloors?
    /// The first refusal of the unlock since the last that did not refuse (Unix ms, this phone's clock), and the period after
    /// which it is told as the second text (a day, divided by the vault's time scale then). A network error neither counts nor
    /// ends the run; an answer only a key the vault holds gets (`bad_pin`) ends it.
    var refusalsSinceMs: Int64?
    var refusalsForMs: Int64?

    /// The identity of the open that could not be told.
    var earlier: IdentitySet { identities[0] }
    /// The newest identity, when there is one beside the first.
    var new: IdentitySet? { identities.count > 1 ? identities.last : nil }
    /// The unlock is what is left because K is the vault's key (`409 key_in_use`, or an earlier open's readable `ok`): the only
    /// case of the text "Your vault took this phone…" after a day of refusals.
    var keyInUse: Bool { unlock && !unlockByReads && !bothEnded }
    var newest: IdentitySet { identities[identities.count - 1] }
    /// The lowest index no identity of the rule uses (nil when all ``IdentitySet/limit`` are in use).
    var nextFree: IdentitySet? { IdentitySet.all.first { !identities.contains($0) } }

    enum CodingKeys: String, CodingKey {
        case identities, ended, unlock
        case bothEnded = "both_ended"
        case registerTried = "register_tried"
        case registerKept = "register_kept"
        case floors
        case returnTo = "return_to"
        case unlockByReads = "unlock_by_reads"
        case transferIncomplete = "transfer_incomplete"
        case refusalsSinceMs = "refusals_since_ms"
        case refusalsForMs = "refusals_for_ms"
    }

    init(earlier: IdentitySet) { identities = [earlier] }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let all = try c.decodeIfPresent([IdentitySet].self, forKey: .identities) ?? []
        identities = all.isEmpty ? [.first] : all
        ended = try c.decodeIfPresent(Bool.self, forKey: .ended) ?? false
        unlock = try c.decodeIfPresent(Bool.self, forKey: .unlock) ?? false
        bothEnded = try c.decodeIfPresent(Bool.self, forKey: .bothEnded) ?? false
        registerTried = try c.decodeIfPresent(String.self, forKey: .registerTried)
        registerKept = try c.decodeIfPresent(String.self, forKey: .registerKept)
        unlockByReads = try c.decodeIfPresent(Bool.self, forKey: .unlockByReads) ?? false
        transferIncomplete = try c.decodeIfPresent(Bool.self, forKey: .transferIncomplete) ?? false
        returnTo = try c.decodeIfPresent(IdentitySet.self, forKey: .returnTo)
        floors = try c.decodeIfPresent(AltFloors.self, forKey: .floors)
        refusalsSinceMs = try c.decodeIfPresent(Int64.self, forKey: .refusalsSinceMs)
        refusalsForMs = try c.decodeIfPresent(Int64.self, forKey: .refusalsForMs)
    }
}

/// What an identity has seen of the vault's state, kept for the identities made after it (see ``CouldNotTell/floors``).
struct AltFloors: Codable, Equatable, Sendable {
    var stateSeq: UInt64
    var manifestSerial: UInt64
    var headerSeq: [String: UInt64]
    var release: String
    var releaseNumber: UInt64

    init(_ a: AltState) {
        stateSeq = a.stateSeq
        manifestSerial = a.manifestSerial
        headerSeq = a.headerSeq
        release = a.release
        releaseNumber = a.releaseNumber
    }

    /// The larger of the two, per floor.
    func merged(with other: AltFloors) -> AltFloors {
        var out = self
        out.stateSeq = max(stateSeq, other.stateSeq)
        out.manifestSerial = max(manifestSerial, other.manifestSerial)
        for (k, v) in other.headerSeq { out.headerSeq[k] = max(out.headerSeq[k] ?? 0, v) }
        if other.releaseNumber > releaseNumber { (out.release, out.releaseNumber) = (other.release, other.releaseNumber) }
        return out
    }

    var altState: AltState {
        var a = AltState()
        a.stateSeq = stateSeq
        a.manifestSerial = manifestSerial
        a.headerSeq = headerSeq
        a.release = release
        a.releaseNumber = releaseNumber
        return a
    }
}
