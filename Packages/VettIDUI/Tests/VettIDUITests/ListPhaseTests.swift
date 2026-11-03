import Testing
@testable import VettIDUI

/// A list whose read failed says so, never that it is empty; with rows, the failure is said above them.
@Suite struct ListPhaseTests {
    @Test func aFailedReadIsNeverTheEmptyState() {
        #expect(ListPhase.of(loading: true, empty: true, failed: false) == .loading)
        #expect(ListPhase.of(loading: true, empty: true, failed: true) == .loading)
        #expect(ListPhase.of(loading: false, empty: true, failed: true) == .failed)
        #expect(ListPhase.of(loading: false, empty: true, failed: false) == .empty)
    }

    @Test func rowsStayShownAndAFailedRefreshIsSaidAboveThem() {
        let rows = ListPhase.of(loading: false, empty: false, failed: true)
        #expect(rows == .rows && rows.failedAbove(failed: true))
        #expect(ListPhase.of(loading: true, empty: false, failed: false) == .rows)
        #expect(!ListPhase.rows.failedAbove(failed: false))
        #expect(!ListPhase.failed.failedAbove(failed: true) && !ListPhase.empty.failedAbove(failed: true))
    }
}
