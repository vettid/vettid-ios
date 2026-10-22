import Foundation

/// One question per item and subject (VAULT-MESSAGING 0.23.0 §10.12 Overlapping rules): an item pending in several rules of
/// the same connection (or agent) is asked once. Since 0.23.0 the vault applies a `share.decide` of the item in one rule to
/// every rule of that subject where it waits (and a decline also where it is included), so the app shows it in the first of
/// those rules (by `rule_id`, the order `share.pending.list` keeps) and notes the others in ``ShareItem/alsoIn``. A rule left
/// with no item of its own is not shown. With a vault before 0.23.0 the item comes back in the next rule after the first
/// answer, as that vault still asks per rule. Mirrors vettid-android `ShareQuestions`.
public enum ShareQuestions {
    public static func dedupe(_ approvals: [PendingApproval]) -> [PendingApproval] {
        var shares: [ShareDecision] = []
        for a in approvals { if case .share(let s) = a { shares.append(s) } }
        guard shares.count >= 2 else { return approvals }
        // subject → item → the rules (in rule_id order) where it waits.
        var places: [String: [String: [String]]] = [:]
        for d in shares.sorted(by: { $0.ruleID < $1.ruleID }) {
            guard let s = subject(d) else { continue }
            for i in d.items { places[s, default: [:]][i.itemID, default: []].append(d.ruleID) }
        }
        return approvals.compactMap { a in
            guard case .share(var d) = a, let s = subject(d) else { return a }
            let items = d.items.compactMap { i -> ShareItem? in
                let rules = places[s]?[i.itemID] ?? []
                guard rules.isEmpty || rules[0] == d.ruleID else { return nil }
                var kept = i
                kept.alsoIn = Array(rules.dropFirst())
                return kept
            }
            if items.isEmpty { return nil }
            d.items = items
            return .share(d)
        }
    }

    static func subject(_ d: ShareDecision) -> String? {
        d.subjectConnectionID.map { "c:\($0)" } ?? d.subjectAgentID.map { "a:\($0)" }
    }
}
