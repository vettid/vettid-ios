import Foundation
import VettIDCrypto
import VettIDVault

/// A share rule's mode (VAULT-MESSAGING §10.12): `ask` (the default: the member decides each new item) or `auto`. Mirrors
/// vettid-android `ShareMode`.
public enum ShareMode: String, Sendable {
    case ask
    case auto

    public var wire: String { rawValue }

    public static func of(_ w: String?) -> ShareMode { w == ShareMode.auto.rawValue ? .auto : .ask }
}

/// Who a share rule is for (§10.12 `subject`): a connection or an agent. Mirrors vettid-android `ShareSubject`.
public struct ShareSubject: Equatable, Sendable {
    public var connectionID: String?
    public var agentID: String?

    public init(connectionID: String? = nil, agentID: String? = nil) {
        self.connectionID = connectionID
        self.agentID = agentID
    }
}

/// A rule an item would gain (§10.7 Dry run): asked about (`ask`) or included at once (`auto`); [usable] for a critical
/// item; [askRuleID] (0.23.0): an `auto` rule that asks because this `ask` rule of the same subject holds the item.
/// Mirrors vettid-android `EffectShare`.
public struct EffectShare: Equatable, Sendable {
    public var ruleID: String
    public var subject: ShareSubject
    public var mode: ShareMode
    public var usable: Bool
    public var askRuleID: String?

    public init(ruleID: String, subject: ShareSubject, mode: ShareMode, usable: Bool = false, askRuleID: String? = nil) {
        self.ruleID = ruleID
        self.subject = subject
        self.mode = mode
        self.usable = usable
        self.askRuleID = askRuleID
    }
}

/// A rule an item would leave, where it is [state] `pending` or `included` (§10.7 Dry run). Mirrors vettid-android
/// `EffectWithdrawal`.
public struct EffectWithdrawal: Equatable, Sendable {
    public var ruleID: String
    public var subject: ShareSubject
    public var state: String

    public init(ruleID: String, subject: ShareSubject, state: String) {
        self.ruleID = ruleID
        self.subject = subject
        self.state = state
    }
}

/// What saving an item (or its tags) would do to sharing, as the vault plans it (`item.put` / `item.tag` with `dry_run`,
/// VAULT-MESSAGING 0.21.0 §10.7): the rules it gains ([shares]) and leaves ([withdrawals]); [version] the item's current
/// one (nil for a new item). Mirrors vettid-android `ShareEffect`.
public struct ShareEffect: Equatable, Sendable {
    public var version: Int64?
    public var shares: [EffectShare]
    public var withdrawals: [EffectWithdrawal]

    public init(version: Int64? = nil, shares: [EffectShare] = [], withdrawals: [EffectWithdrawal] = []) {
        self.version = version
        self.shares = shares
        self.withdrawals = withdrawals
    }

    public var isEmpty: Bool { shares.isEmpty && withdrawals.isEmpty }

    /// A dry run's answer (`{version?, shares, withdrawals}`); entries without `rule_id` are skipped; `usable` counts only
    /// as a JSON `true`.
    public static func of(_ o: JsonObject) -> ShareEffect {
        func subject(_ e: JsonObject) -> ShareSubject {
            let s = VaultJSON.obj(e, "subject")
            return ShareSubject(
                connectionID: s.flatMap { VaultJSON.string($0, "connection_id") }, agentID: s.flatMap { VaultJSON.string($0, "agent_id") }
            )
        }
        return ShareEffect(
            version: VaultJSON.int(o, "version"),
            shares: VaultJSON.objects(o, "shares").compactMap { e in
                guard let r = VaultJSON.string(e, "rule_id") else { return nil }
                return EffectShare(
                    ruleID: r, subject: subject(e), mode: ShareMode.of(VaultJSON.string(e, "mode")),
                    usable: VaultJSON.bool(e, "usable") == true, askRuleID: VaultJSON.string(e, "ask_rule_id")
                )
            },
            withdrawals: VaultJSON.objects(o, "withdrawals").compactMap { e in
                guard let r = VaultJSON.string(e, "rule_id") else { return nil }
                return EffectWithdrawal(ruleID: r, subject: subject(e), state: VaultJSON.string(e, "state") ?? "included")
            }
        )
    }
}
