import Foundation

// A challenge its challenger withdrew (VAULT-MESSAGING 0.80.0 §10.4 "Withdrawing a challenge"): the vault closes the ask
// and tells every owner device with `sync.event{connection.authenticate.decided, approved: false, withdrawn: true}`. The
// app closes it as for a decision on another device, remembers that it was withdrawn so that a screen showing it says so,
// and marks its feed item read itself (the vault leaves the item as it is): only once no ask of its batch is open
// (§10.4.1). Mirrors ANDROID-PLAN 0.1.101 "Withdrawn requests".
extension ApprovalsManager {
    /// §10.4.1: a batch is a connection's asks within 10 minutes of the first of them (as VettIDApprovals' `AskBatches`).
    static let batchWindow: TimeInterval = 10 * 60

    public func wasWithdrawn(_ key: String) -> Bool { withdrawnKeys.contains(key) }

    /// The ask [key] was withdrawn by its challenger: noted (an unknown one too, harmlessly), and closed. [apply] false: a
    /// list already read after the event judges whether a held ask is open, as for any closing event (0.70.0 §10.4.2).
    ///
    /// Its feed item: an item that stands for this ask alone (`count` below 2) is always read, held or not, since reading
    /// is harmless; an item standing for a batch is read once no ask of the batch is open. The batch is judged by the
    /// asks' arrival here (§10.4.1's 10 minutes), which a list read blurs (every listed ask arrives at the read), so only a
    /// batch's own item waits on it (chosen; not in the spec).
    func withdrawn(_ key: String, ts: Date, apply: Bool) {
        withdrawnKeys.removeAll { $0 == key }
        withdrawnKeys.append(key)
        if withdrawnKeys.count > Self.maxClosedAsks { withdrawnKeys.removeFirst() }
        guard let (_, ref) = FeedAsks.of(key) else { return }
        guard let ask = approvals.first(where: { $0.key == key }), let conn = ask.connectionID else {
            // Not held here (its `.pending` not yet arrived, or a read on its way): the screens show nothing, and a late
            // `.pending` or a list read begun before does not bring it back.
            if apply { drop(key, closedAt: ts) }
            onAskRead(ref, true)
            return
        }
        guard apply else { return }
        let batch = Self.batch(of: ask, connection: conn, in: approvals)
        drop(key, closedAt: ts)
        onAskRead(ref, true)
        let others = Set(batch.map(\.key)).subtracting([key])
        if others.isEmpty {
            onAskRead(ref, false)
        } else if batch.first?.key == key {
            // A batch's item is its first ask's: read once the others close.
            withdrawnBatches[ref] = others
        }
    }

    /// After a list read: a batch waiting on asks the lists no longer hold (decided elsewhere or expired without an event
    /// here) has its item read.
    func withdrawnBatchesListed() {
        let held = Set(approvals.map(\.key))
        for (ref, open) in withdrawnBatches {
            let left = open.intersection(held)
            withdrawnBatches[ref] = left.isEmpty ? nil : left
            if left.isEmpty { onAskRead(ref, false) }
        }
    }

    /// An ask closed (decided here or elsewhere, or withdrawn): a batch waiting on it whose first ask was withdrawn has its
    /// item read once none of it is open.
    func batchAskClosed(_ key: String) {
        for (ref, open) in withdrawnBatches where open.contains(key) {
            let left = open.subtracting([key])
            withdrawnBatches[ref] = left.isEmpty ? nil : left
            if left.isEmpty { onAskRead(ref, false) }
        }
    }

    /// The open asks of [ask]'s batch on [connection], oldest first: its asks within ``batchWindow`` of the batch's first.
    static func batch(of ask: PendingApproval, connection: String, in approvals: [PendingApproval]) -> [PendingApproval] {
        var batches: [[PendingApproval]] = []
        let asks = approvals.filter { isAsk($0) && $0.connectionID == connection }.sorted { $0.receivedAt < $1.receivedAt }
        for a in asks {
            if let start = batches.last?.first?.receivedAt, a.receivedAt < start.addingTimeInterval(batchWindow) {
                batches[batches.count - 1].append(a)
            } else {
                batches.append([a])
            }
        }
        return batches.first { $0.contains { $0.key == ask.key } } ?? [ask]
    }

    /// An ask of a connection, of the kinds a batch is made of (VAULT-MESSAGING 0.23.0 §10.4.1): an authentication, a
    /// grant request or a critical-item use.
    static func isAsk(_ a: PendingApproval) -> Bool {
        switch a {
        case .authentication, .grant, .critical: true
        default: false
        }
    }
}
