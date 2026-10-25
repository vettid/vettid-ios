import Foundation
import VettIDKeys

/// Where a phone that could not tell whether an open recovered the vault stands (IOS-PLAN 0.1.33 §4.9; VAULT-MESSAGING 0.59.0
/// §11.14.6 "A phone that could not tell"; MEMBER-API 2.12.0).
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
    /// A day of refusals to the unlock: the text "Your vault took this phone, but it cannot be unlocked right now. Contact
    /// VettID."
    case contact
}

/// (§4.9) A status read of the rule: what it said, and when (this phone's clock and its monotonic clock, which keeps
/// counting while the phone sleeps).
struct CouldNotTellRead: Codable, Equatable, Sendable {
    /// `true`: `401` or `410 recovery_ended`; `false`: a `200` that does not show the recovery `registered`.
    var ended: Bool
    var atMs: Int64
    var uptime: Double

    enum CodingKeys: String, CodingKey {
        case ended
        case atMs = "at_ms"
        case uptime
    }
}

/// (§4.9) What a phone that could not tell keeps, until the vault answered `ok` and the pairing completed: every identity it made
/// (its keys, its device state with its `recovery_id` and the history of its opens) and the phone-secret record. K, the app key,
/// is the phone's own and is never replaced meanwhile.
///
/// Persisted as `could_not_tell` in the account record: `identities` (oldest first, indexes into the keys `relay`, `relay2`, …
/// and the device state files `vault-device`, `vault-device-2`, …; the first is the identity of the open that could not be told),
/// the flags below, and the run of refusals. Chosen; not in the spec: a new code makes a new identity whenever the newest one
/// may hold an invitation (an unanswered open), up to ``IdentitySet/limit``.
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
    /// The unlock answered `transfer_incomplete`: only an open repeats the recovery. Both kinds of read then mean "ended" unless
    /// the recovery shows `registered`.
    var transferIncomplete = false
    /// While the unlock of other identities is tried (a trial, the unlock with each), the identity to go back to when it does not
    /// end: a kill meanwhile goes back to it (``VaultManager/settleTrial()``).
    var returnTo: IdentitySet?
    /// The first refusal of the unlock since the last that did not refuse (Unix ms, this phone's clock), and the period after
    /// which it is told as the second text (a day, divided by the vault's time scale then). A network error neither counts nor
    /// ends the run; an answer only a key the vault holds gets (`bad_pin`) ends it.
    var refusalsSinceMs: Int64?
    var refusalsForMs: Int64?

    /// The identity of the open that could not be told.
    var earlier: IdentitySet { identities[0] }
    /// The newest identity, when there is one beside the first.
    var new: IdentitySet? { identities.count > 1 ? identities.last : nil }
    var newest: IdentitySet { identities[identities.count - 1] }

    enum CodingKeys: String, CodingKey {
        case identities, ended, unlock
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
        unlockByReads = try c.decodeIfPresent(Bool.self, forKey: .unlockByReads) ?? false
        transferIncomplete = try c.decodeIfPresent(Bool.self, forKey: .transferIncomplete) ?? false
        returnTo = try c.decodeIfPresent(IdentitySet.self, forKey: .returnTo)
        refusalsSinceMs = try c.decodeIfPresent(Int64.self, forKey: .refusalsSinceMs)
        refusalsForMs = try c.decodeIfPresent(Int64.self, forKey: .refusalsForMs)
    }
}
