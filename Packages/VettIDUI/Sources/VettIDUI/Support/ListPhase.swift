/// What a list screen shows in its place: the first read under way, the read's failure, the empty state, or the rows. A
/// list whose read failed never says it is empty: it says the read failed, with "Try again". With rows to show, a failed
/// read keeps them and says so above them (``failedAbove(failed:)``).
public enum ListPhase: Equatable, Sendable {
    case loading, failed, empty, rows

    /// [loading]: a read is under way; [empty]: nothing to list; [failed]: the last read failed.
    public static func of(loading: Bool, empty: Bool, failed: Bool) -> ListPhase {
        guard empty else { return .rows }
        if loading { return .loading }
        return failed ? .failed : .empty
    }

    /// Whether the failure of a read is said above the rows (a refresh that failed while the list was shown).
    public func failedAbove(failed: Bool) -> Bool { self == .rows && failed }
}
