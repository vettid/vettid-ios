public extension ApprovalDetailState {
    /// A request open for a decision counts while it is open, typed or not (VAULT-MESSAGING §3.6.5: the daily check must
    /// not interrupt "an approval"). A decided, gone or withdrawn one does not.
    var holdsInput: Bool { approval != nil && !done && !gone && !withdrawn }
}
