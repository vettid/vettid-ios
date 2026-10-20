import Foundation
import VettIDData

/// A row of the Approvals list: one approval, or a batch of one connection's asks (VAULT-MESSAGING 0.23.0 §10.4.1).
/// Mirrors vettid-android `ApprovalEntry`.
public enum ApprovalEntry: Equatable, Sendable {
    case one(PendingApproval)
    /// "Dr Lee asks for 3 things": [asks] oldest first, all from [connectionID].
    case batch(connectionID: String, asks: [PendingApproval])

    public var key: String {
        switch self {
        case .one(let a): a.key
        case .batch(_, let asks): "batch:\(asks.first?.key ?? "")"
        }
    }

    public var receivedAt: Date {
        switch self {
        case .one(let a): a.receivedAt
        case .batch(_, let asks): asks.map(\.receivedAt).max() ?? .distantPast
        }
    }
}

/// Batches of a connection's asks (§10.4.1 Batching): asks from one connection that reached the member within 10 minutes
/// of the first of them are one batch, and the app MUST present a batch as one approval entry listing its asks. The
/// vault batches the same way (its feed item's `count`); the app groups the per-type lists it shows, so that a batch
/// reads the same whether its asks came as events or from the lists. Asks are the connection's grant requests,
/// critical-item uses and authentication challenges (share questions are the member's own rules, and connection requests
/// come from not-yet-connections: neither is an ask). Mirrors vettid-android `AskBatches`.
public enum AskBatches {
    /// §10.4.1: 10 minutes from the first ask of a batch.
    public static let window: TimeInterval = 10 * 60

    /// The connection an ask comes from; nil for an approval that is not an ask.
    public static func connectionOf(_ a: PendingApproval) -> String? {
        switch a {
        case .authentication(let x): x.connectionID
        case .grant(let x): x.connectionID
        case .critical(let x): x.connectionID
        default: nil
        }
    }

    /// [approvals] as rows, newest first: a batch of two or more asks takes the place of its newest.
    public static func group(_ approvals: [PendingApproval]) -> [ApprovalEntry] {
        var batchOf: [String: ApprovalEntry] = [:]
        let byConnection = Dictionary(grouping: approvals.filter { connectionOf($0) != nil }) { connectionOf($0) ?? "" }
        for (conn, asks) in byConnection {
            var current: [PendingApproval] = []
            func close() {
                if current.count > 1 {
                    let b = ApprovalEntry.batch(connectionID: conn, asks: current)
                    for a in current { batchOf[a.key] = b }
                }
                current = []
            }
            for a in asks.sorted(by: { $0.receivedAt < $1.receivedAt }) {
                if let start = current.first?.receivedAt, a.receivedAt >= start.addingTimeInterval(window) { close() }
                current.append(a)
            }
            close()
        }
        var out: [ApprovalEntry] = []
        var shown = Set<String>()
        for a in approvals.sorted(by: { $0.receivedAt > $1.receivedAt }) {
            if let b = batchOf[a.key] {
                if shown.insert(b.key).inserted { out.append(b) }
            } else {
                out.append(.one(a))
            }
        }
        return out
    }
}

/// Why a share question's item is asked and what an answer does (VAULT-MESSAGING 0.23.0 §10.12 Overlapping rules): an item
/// an `ask` rule of the subject holds ("Also covered by …, which asks you first"), and an item another rule of the subject
/// already shares, which a decline stops sharing. The rules a question's item also waits in, and the rules' names (by
/// their tags), come with the share rules (IOS-PLAN §8 I3.2): until then a rule reads "another of your rules" (chosen; not
/// in the spec). Mirrors vettid-android `ShareExplanations`.
public enum ShareExplanations {
    public enum Line: Equatable, Sendable {
        /// `ask_rule_id`: the `ask` rule of the subject that holds the item.
        case asksFirst(ruleID: String)
        /// `shared`: another rule of the subject already shares it; declining stops that.
        case alreadyShared
    }

    public static func of(_ item: ShareItem, _ decision: ShareDecision) -> [Line] {
        var out: [Line] = []
        if let asker = item.askRuleID, asker != decision.ruleID { out.append(.asksFirst(ruleID: asker)) }
        if item.shared { out.append(.alreadyShared) }
        return out
    }
}
