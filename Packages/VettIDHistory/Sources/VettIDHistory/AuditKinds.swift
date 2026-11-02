import Foundation
import VettIDData

/// Member-facing text of the audit log's kinds (VAULT-MESSAGING §10.9; IOS-PLAN §4.1 "History"): one title per kind the
/// spec names, the `drop.<reason>` family ("Message blocked", with the reason), the hourly `<kind>.summary` entries of
/// agents (§10.11), and a generic title for a kind this app does not know (a newer vault's), which shows the kind itself.
/// The titles are keys of ``HistoryKindTexts``; ``HistoryText`` reads them. Mirrors vettid-android `AuditKinds`.
public enum AuditKinds {
    /// The Vault list's names by item id, read when asked (nil before the list is read); nil without the list.
    @MainActor
    static func itemNames(_ items: (any ItemsRepository)?) -> (@MainActor () -> [String: String]?)? {
        guard let items else { return nil }
        return { items.names }
    }

    /// The titles of the votes in memory by (connection, proposal) (``VoteTitles/key(_:_:)``), read when asked; nil without Votes.
    @MainActor
    static func voteTitles(_ votes: (any VotesRepository)?) -> (@MainActor () -> [String: String])? {
        guard let votes else { return nil }
        return {
            Dictionary(votes.votes.map { (VoteTitles.key($0.connectionID, $0.proposalID), $0.title) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// A vote entry's vote title, from [titles] by the pair (the entry's connection, the `ref`'s proposal id); nil when not known.
    static func voteTitle(_ kind: String, _ ref: String?, connectionID: String?, in titles: [String: String]?) -> String? {
        guard let id = voteOf(kind, ref), let t = titles?[VoteTitles.key(connectionID, id)], !t.isEmpty else { return nil }
        return t
    }

    /// The kinds whose `ref` is an `item_id` (§10.9: the vault's search reads the item's name for them), with
    /// `leash.item.run`, `.proxy` and `.changed` (IOS-PLAN §4.1).
    public static let itemRefKinds: Set<String> = [
        "item.added", "item.updated", "item.deleted", "item.sensitivity_changed", "item.revealed",
        "share.included", "share.declined", "share.withdrawn", "leash.item.read", "leash.item.used",
        "leash.item.run", "leash.item.proxy", "leash.item.changed",
    ]

    /// The item an entry refers to, if any.
    public static func itemOf(_ kind: String, _ ref: String?) -> String? {
        guard itemRefKinds.contains(kind), let ref, !ref.isEmpty else { return nil }
        return ref
    }

    public static let kindExported = "audit.exported"
    public static let kindLocked = "vault.locked"
    /// (Release L) `vault.locked`'s `ref` for the idle lock (VAULT-MESSAGING §3.6.8).
    public static let refIdle = "idle"

    /// An `audit.exported` entry's format and count from its `ref` (0.22.0 §10.9: `format=<csv|json>;count=<n>;…`), or
    /// nil for another kind or a summary that does not read.
    public static func exportSummary(_ kind: String, _ ref: String?) -> (format: String, count: Int)? {
        guard kind == kindExported, let ref else { return nil }
        var pairs: [String: String] = [:]
        for p in ref.split(separator: ";", omittingEmptySubsequences: false) {
            let kv = p.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2 { pairs[String(kv[0])] = String(kv[1]) }
        }
        guard let format = pairs["format"], format == "csv" || format == "json",
              let count = pairs["count"].flatMap({ Int($0) }), count >= 0 else { return nil }
        return (format, count)
    }

    public static let kindSignerBound = "device.signer_bound"
    public static let kindSignerChanged = "device.signer_changed"
    public static let kindSignerRefused = "device.signer_refused"

    /// What a signer entry's `ref` says (0.27.0 §10.9, §11.7.1; classes, never digests).
    public enum SignerDetail: Equatable, Sendable {
        case bound(String)
        case changed(from: String, to: String)
        /// [unbound]: no signer was recorded for the installation; otherwise its signer is not one the release accepts.
        case refused(unbound: Bool)
    }

    /// The signer entries' `ref`: `device.signer_bound` the class, `device.signer_changed` `<old class>:<new class>`,
    /// `device.signer_refused` `unpinned` or `unbound`. Nil for another kind or a `ref` that does not read.
    public static func signerDetail(_ kind: String, _ ref: String?) -> SignerDetail? {
        switch kind {
        case kindSignerBound:
            guard let ref, !ref.isEmpty, !ref.contains(":") else { return nil }
            return .bound(ref)
        case kindSignerChanged:
            guard let p = ref?.split(separator: ":", omittingEmptySubsequences: false), p.count == 2,
                  p.allSatisfy({ !$0.isEmpty }) else { return nil }
            return .changed(from: String(p[0]), to: String(p[1]))
        case kindSignerRefused:
            switch ref {
            case "unpinned": return .refused(unbound: false)
            case "unbound": return .refused(unbound: true)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Whose name a ``Title/named(_:any:who:)`` shows.
    public enum Who: Sendable { case connection, device, item }

    /// How a kind reads: a known title, a known title as an hourly summary, a dropped message, unknown, a title with
    /// numbers read from `ref` ([n] of [of] recovery attempts), or one that names the entry's connection, device or item
    /// ([any] without the name: the connection, device or item is gone or not known).
    public enum Title: Equatable, Sendable {
        case known(String)
        case summary(String)
        /// `drop.<reason>`: the reason with its underscores as spaces.
        case dropped(String)
        case unknown(String)
        case counted(String, n: Int, of: Int)
        case named(String, any: String, who: Who)
        /// A vote entry (ANDROID-PLAN 0.1.102 "Votes"): [key] names the vote's title in quotes, [any] is the same without it (the
        /// Votes list is not in memory); [service] puts the service's name first (the entry's connection, else "A service");
        /// [reason] is a refusal's reason (a ``HistoryKindTexts`` key), last.
        case vote(VoteTitle)
    }

    /// A vote entry's title: the text with the vote's title [key], without it [any]; [service] puts the service first; [reason].
    public struct VoteTitle: Equatable, Sendable {
        public let key: String
        public let any: String
        public let service: Bool
        public let reason: String?
    }

    /// The vote entries whose `ref` is `<proposal_id>` or `<proposal_id>:<detail>`: the pair is with the entry's connection.
    public static let voteKinds: Set<String> = [
        "vote.cast", "vote.recorded", "vote.refused", "vote.conflict", "vote.receipt_rejected", "vote.extended",
        "vote.extension_rejected", "vote.check_ok", "vote.check_unconfirmed", "vote.check_failed", "vote.check_gave_up",
        "vote.released",
    ]

    /// The proposal id of a vote entry's `ref`; nil for another kind or an empty id.
    public static func voteOf(_ kind: String, _ ref: String?) -> String? {
        guard voteKinds.contains(kind), let id = ref?.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first,
              !id.isEmpty else { return nil }
        return String(id)
    }

    public static let kindAttempt = RecoveryRefs.kindAttempt
    public static let kindAttemptsUsed = "recovery.attempts_used"
    public static let kindClosed = RecoveryRefs.kindClosed

    // swiftlint:disable cyclomatic_complexity
    /// How the entry of [kind] with [ref] reads (IOS-PLAN §4.1): the titles that depend on `ref` first, then those that
    /// name the connection, device or item, then the fixed titles.
    public static func title(_ kind: String, _ ref: String? = nil) -> Title {
        switch kind {
        case kindAttempt:
            return RecoveryRefs.attempt(ref).map { .counted("history_kind_recovery_attempt", n: $0.n, of: RecoveryRefs.attempts) }
                ?? .known("history_kind_recovery_attempt_any")
        case kindAttemptsUsed:
            return RecoveryRefs.attemptsUsed(ref).map { .counted("history_kind_recovery_attempts_used", n: $0, of: RecoveryRefs.attempts) }
                ?? .known("history_kind_recovery_attempts_used_any")
        case kindClosed:
            return .known(closedTitle(RecoveryRefs.closure(ref)?.reason))
        // (VAULT-MESSAGING §3.6.8, release L) The vault locked itself: `vault.locked` with `ref` `idle`.
        case kindLocked where ref == refIdle:
            return .known("history_kind_vault_locked_idle")
        default:
            break
        }
        if let v = voteTitle(kind, ref) { return v }
        if let n = named[kind] { return n }
        if let t = titles[kind] { return .known(t) }
        if kind.hasSuffix(summary), let t = titles[String(kind.dropLast(summary.count))] { return .summary(t) }
        if kind.hasPrefix(drop), kind.hasSuffix(malformed) { return .known("history_kind_drop_malformed") }
        if kind.hasPrefix(drop), kind.count > drop.count {
            return .dropped(String(kind.dropFirst(drop.count)).replacingOccurrences(of: "_", with: " "))
        }
        return .unknown(kind)
    }

    /// The vote kinds of ANDROID-PLAN 0.1.102 "Votes" (History): the title depends on `ref`'s suffix for some.
    private static func voteTitle(_ kind: String, _ ref: String?) -> Title? {
        let detail = ref.flatMap { r in r.firstIndex(of: ":").map { String(r[r.index(after: $0)...]) } }
        func vote(_ k: String, service: Bool = false, reason: String? = nil) -> Title {
            .vote(VoteTitle(key: "history_kind_vote_\(k)", any: "history_kind_vote_\(k)_any", service: service, reason: reason))
        }
        func service(_ k: String) -> Title { .named("history_kind_vote_\(k)", any: "history_kind_vote_\(k)_any", who: .connection) }
        switch kind {
        case "vote.cast": return vote("cast")
        case "vote.recorded": return vote("recorded", service: true)
        case "vote.refused": return vote("refused", service: true, reason: refusedReason(detail))
        case "vote.conflict": return vote("conflict", service: true)
        case "vote.receipt_rejected": return vote("receipt_rejected")
        case "vote.extended": return vote("extended")
        case "vote.extension_rejected": return vote("extension_rejected")
        case "vote.check_ok": return vote("check_ok")
        case "vote.check_unconfirmed": return vote("check_unconfirmed")
        case "vote.check_failed": return vote("check_failed")
        case "vote.check_gave_up": return vote("check_gave_up")
        case "vote.released": return vote("released")
        case "vote.proposal_rejected": return service("proposal_rejected")
        case "vote.proposal_conflict":
            switch detail {
            case "mismatch": return service("site_mismatch")
            case "not_listed": return service("not_listed")
            case "unpublished": return service("unpublished")
            default: return service("two_versions")
            }
        default: return nil
        }
    }

    // swiftlint:enable cyclomatic_complexity

    /// A refusal's reason in words; a code this app does not know is "not accepted".
    private static func refusedReason(_ code: String?) -> String {
        switch code {
        case "closed", "late": "history_vote_reason_closed"
        case "not_active": "history_vote_reason_not_active"
        case "not_eligible": "history_vote_reason_not_eligible"
        case "connection_ended": "history_vote_reason_connection_ended"
        default: "history_vote_reason_not_accepted"
        }
    }

    private static func closedTitle(_ reason: String?) -> String {
        switch reason {
        case "pin": "history_kind_recovery_closed_pin"
        case "password": "history_kind_recovery_closed_password"
        case "reset": "history_kind_recovery_closed_reset"
        case "backup_off": "history_kind_recovery_closed_backup_off"
        case "exhausted": "history_kind_recovery_closed_exhausted"
        case "delete": "history_kind_recovery_closed_delete"
        case RecoveryRefs.reasonRollback: "history_kind_recovery_closed_rollback"
        default: "history_kind_recovery_closed"
        }
    }

    /// Entries History does not list (IOS-PLAN §4.1, decision 4): `recovery.open` (its outcome is the matching attempt's
    /// detail), `device.unlinked_sent`, `drop.call_glare`, and a generation closed as `stale` (the harmless case). They stay
    /// in the log, in the chain check and in an export. A generation closed as `rollback` is shown.
    public static func hidden(_ kind: String, _ ref: String?) -> Bool {
        switch kind {
        case RecoveryRefs.kindOpen, "device.unlinked_sent", "drop.call_glare": true
        case kindClosed: RecoveryRefs.closure(ref)?.reason == RecoveryRefs.reasonStale
        default: false
        }
    }

    /// One line of an entry's **Details**.
    public enum Detail: Equatable, Sendable {
        case line(String)
        /// A line naming a duration the vault's time scale divides: [real] in real time, else [scaled] with
        /// [realSeconds] as the vault runs it (STAGING-TIME-SCALE).
        case scaled(String, scaled: String, realSeconds: TimeInterval)
        /// A line with a name the vault recorded.
        case named(String, name: String)
        /// A line with the entry's connection's "First Last", left out without it (chosen; not in the spec).
        case connection(String)
    }

    /// What is known of a `not_success` attempt's outcome (the matching `recovery.open`, ``RecoveryRefs/matches(_:)``).
    public enum Outcome: Equatable, Sendable {
        /// [phoneName]: the attempting phone's self-reported name, shown only as such; nil when the entry has none.
        case matched(String, phoneName: String? = nil)
        /// The entries were read and none matches: "Details not available."
        case none
        /// Not read (yet), or the read failed: no outcome line.
        case unknown
        /// The vault wrote this attempt again as `success`: "Later successful." instead of the not-success lines.
        case laterSuccessful
    }

    // swiftlint:disable cyclomatic_complexity
    /// The detail lines of IOS-PLAN §4.1 for the entry of [kind] with [ref].
    public static func details(_ kind: String, _ ref: String?, outcome: Outcome = .unknown) -> [Detail] {
        switch kind {
        case kindAttempt: return attemptDetails(ref, outcome)
        case kindAttemptsUsed: return [.line("history_detail_recovery_attempts_used")]
        case "recovery.armed": return [.line("history_detail_recovery_armed")]
        case kindClosed: return closedDetails(ref)
        case "recovery.presence_unrecorded":
            return [
                .scaled(
                    "history_detail_presence_unrecorded", scaled: "history_detail_presence_unrecorded_scaled", realSeconds: quietSeconds
                ),
            ]
        // VAULT-MESSAGING 0.69.2 §11.14.10: a rotation made for a transfer carries its `transfer_id` as the ref, a
        // recovery's the literal "recovery", a plain key replacement none.
        case "identity.rotated":
            guard let ref, !ref.isEmpty, ref != "recovery" else { return [] }
            return [.line("history_detail_rotated_transfer")]
        case "identity.rotation_failed": return [.line("history_detail_rotation_failed")]
        case "identity.rotate_conflict": return [.line("history_detail_rotate_conflict")]
        case "push.registered", "push.unregistered": return pushDetails(kind, ref)
        case "push.token_gone": return [.line("history_detail_push_token_gone")]
        case "leash.item.run": return [.line("history_detail_leash_item_run")]
        case "leash.item.proxy": return [.line("history_detail_leash_item_proxy")]
        case "credential.utk_resync": return [.line("history_detail_credential_utk_resync")]
        case "credential.holder_cleared": return [.line("history_detail_credential_holder_cleared")]
        case "connection.authenticate.withdrawn": return [.connection("history_authn_withdrawn_detail")]
        default: return []
        }
    }
    // swiftlint:enable cyclomatic_complexity

    private static func pushDetails(_ kind: String, _ ref: String?) -> [Detail] {
        let lines: [String: String] = kind == "push.registered"
            ? ["fcm": "history_detail_push_google", "apns": "history_detail_push_apple"]
            : ["app": "history_detail_push_off_app", "transferred": "history_detail_push_off_transferred",
               "replaced": "history_detail_push_off_replaced"]
        return ref.flatMap { lines[$0] }.map { [.line($0)] } ?? []
    }

    private static func attemptDetails(_ ref: String?, _ outcome: Outcome) -> [Detail] {
        guard let a = RecoveryRefs.attempt(ref) else { return [] }
        if a.success { return [.line("history_detail_attempt_success")] }
        if outcome == .laterSuccessful { return [.line("history_detail_attempt_later_success")] }
        var out: [Detail] = [.line("history_detail_attempt_not_success")]
        switch outcome {
        case .matched(let o, let phone):
            if let line = outcomeLine(o) { out.append(line) }
            // Self-reported: shown in that form only, and never changing the title, the priority or the channel.
            if let phone { out.append(.named("history_detail_attempt_phone", name: phone)) }
        case .none:
            out.append(.line("history_detail_attempt_no_details"))
        case .unknown, .laterSuccessful:
            break
        }
        return out
    }

    /// A counted open's outcome in words (§11.14.11); nil for one this app does not know.
    public static func outcomeLine(_ outcome: String) -> Detail? {
        switch outcome {
        case "wrong": .line("history_detail_outcome_wrong")
        case "attempt_lost": .line("history_detail_outcome_attempt_lost")
        case "quiet": .scaled("history_detail_outcome_quiet", scaled: "history_detail_outcome_quiet_scaled", realSeconds: quietSeconds)
        case "wait": .line("history_detail_outcome_wait")
        case "exhausted": .line("history_detail_outcome_exhausted")
        case "closed": .line("history_detail_outcome_closed")
        default: nil
        }
    }

    private static func closedDetails(_ ref: String?) -> [Detail] {
        guard let c = RecoveryRefs.closure(ref) else { return [] }
        let first: String
        switch c.reason {
        case "pin", "password", "reset": first = "history_detail_recovery_closed_reset"
        case "backup_off": first = "history_detail_recovery_closed_backup_off"
        case "exhausted": first = "history_detail_recovery_closed_exhausted"
        case "delete": first = "history_detail_recovery_closed_delete"
        case RecoveryRefs.reasonRollback: first = "history_detail_recovery_closed_rollback"
        default: return []
        }
        return [.line(first)] + (c.unconfirmed ? [.line("history_detail_recovery_closed_unconfirmed")] : [])
    }

    /// The quiet period (§11.14.5): three days, divided by the vault's time scale.
    static let quietSeconds = TimeScales.recoveryQuiet
    private static let malformed = "_malformed"
    private static let summary = ".summary"
    private static let drop = "drop."

    private static let secretUsed = Title.named(
        "history_kind_leash_item_secret_used", any: "history_kind_leash_item_secret_used_any", who: .item
    )

    /// The titles that name the entry's connection, device or item (IOS-PLAN §4.1).
    static let named: [String: Title] = [
        "identity.rotate_conflict": .named("history_kind_rotate_conflict", any: "history_kind_rotate_conflict_any", who: .connection),
        "identity.rotate_resolved": .named("history_kind_rotate_resolved", any: "history_kind_rotate_resolved_any", who: .connection),
        "call.permission_off": .named("history_kind_call_permission_off", any: "history_kind_call_permission_off_any", who: .connection),
        "call.permission_on": .named("history_kind_call_permission_on", any: "history_kind_call_permission_on_any", who: .connection),
        // VAULT-MESSAGING 0.77.0 §6.8, §10.9: a denied session request (`device_id`, `ref` = `request_id`). Android has no
        // key for it; the texts are chosen (not in the spec beyond "Session request from <device> denied").
        "device.session.denied": .named("history_kind_device_session_denied", any: "history_kind_device_session_denied_any", who: .device),
        "push.registered": .named("history_kind_push_registered", any: "history_kind_push_registered_any", who: .device),
        "push.unregistered": .named("history_kind_push_unregistered", any: "history_kind_push_unregistered_any", who: .device),
        "push.token_gone": .named("history_kind_push_token_gone", any: "history_kind_push_token_gone_any", who: .device),
        "leash.item.run": secretUsed,
        "leash.item.proxy": secretUsed,
        "leash.item.changed": .named("history_kind_leash_item_changed", any: "history_kind_leash_item_changed_any", who: .item),
    ]

    // swiftlint:disable cyclomatic_complexity
    /// The filter chip label of each category (ANDROID-PLAN §4 History).
    public static func categoryLabel(_ c: AuditCategory) -> String {
        switch c {
        case .vaultAccess: HistoryStrings.categoryVaultAccess
        case .security: HistoryStrings.categorySecurity
        case .devices: HistoryStrings.categoryDevices
        case .connections: HistoryStrings.categoryConnections
        case .messages: HistoryStrings.categoryMessages
        case .items: HistoryStrings.categoryItems
        case .agents: HistoryStrings.categoryAgents
        case .location: HistoryStrings.categoryLocation
        case .account: HistoryStrings.categoryAccount
        case .dropped: HistoryStrings.categoryDropped
        case .other: HistoryStrings.categoryOther
        }
    }
    // swiftlint:enable cyclomatic_complexity
}
