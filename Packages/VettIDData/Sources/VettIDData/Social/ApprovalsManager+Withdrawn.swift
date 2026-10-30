import Foundation

// A challenge its challenger withdrew (VAULT-MESSAGING 0.80.0 §10.4 "Withdrawing a challenge"): the vault closes the ask
// and tells every owner device with `sync.event{connection.authenticate.decided, approved: false, withdrawn: true}`. The
// app closes it as for a decision on another device, and remembers that it was withdrawn so that a screen showing it says
// so. Mirrors ANDROID-PLAN 0.1.101 "Withdrawn requests".
extension ApprovalsManager {
    public func wasWithdrawn(_ key: String) -> Bool { withdrawnKeys.contains(key) }

    /// The ask [key] was withdrawn by its challenger: noted (an unknown one too, harmlessly), and one held here closes. Its
    /// feed item is the app's to mark read (0.80.0 §10.4 "Closing"), the vault leaving it as it is.
    func withdrawn(_ key: String, ts: Date) {
        withdrawnKeys.removeAll { $0 == key }
        withdrawnKeys.append(key)
        if withdrawnKeys.count > Self.maxClosedAsks { withdrawnKeys.removeFirst() }
        guard let conn = approvals.first(where: { $0.key == key })?.connectionID else { return }
        drop(key, closedAt: ts)
        let othersOpen = approvals.contains { Self.isAsk($0) && $0.connectionID == conn }
        if let (_, ref) = FeedAsks.of(key) { onWithdrawn(ref, conn, othersOpen) }
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
