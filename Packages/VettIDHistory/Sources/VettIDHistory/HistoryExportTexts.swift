import Foundation
import VettIDData
import VettIDVault

/// The export steps' texts that depend on the answer (ANDROID-PLAN §4 History "Export"), kept pure for tests. Mirrors
/// vettid-android `countLabel`, `rangeLabel`, the PIN step's error and `DoneStep`.
public enum HistoryExportTexts {
    /// "40 entries, 1 Oct 2026 – 8 Oct 2026": the count, and the days of `oldest_at` and `newest_at` in local time
    /// (`at` need not grow with `seq`); the count alone without them.
    public static func countAndRange(_ p: AuditExportAnswer) -> String {
        let count = HistoryStrings.exportCount(Int(p.count))
        guard let a = OwnerCheckManager.instant(p.oldestAt), let b = OwnerCheckManager.instant(p.newestAt) else { return count }
        let range = HistoryStrings.dateRange(day(min(a, b)), day(max(a, b)))
        return HistoryStrings.exportCountRange(count, range)
    }

    static func day(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .omitted) }

    /// The line under the keypad: the backoff's countdown, "Wrong PIN", the undated backoff, another failure; nil
    /// without one.
    public static func pinError(_ step: ExportPin, now: Date, timeScale: UInt64 = 1) -> String? {
        if let until = step.retryUntil, until > now {
            return HistoryStrings.exportPinBackoff(Int(until.timeIntervalSince(now).rounded(.up)))
        }
        switch step.error {
        case nil: return nil
        case .badPin?: return HistoryStrings.exportPinWrong
        case .backoff?: return HistoryStrings.exportPinBackoffUndated
        case let e?: return e.message(timeScale: timeScale)
        }
    }

    /// "3 entries exported.", or "38 of 40 entries exported; 2 older entries were removed by your vault's history limit
    /// meanwhile."
    public static func done(written: Int, authorised: Int64) -> String {
        Int64(written) < authorised
            ? HistoryStrings.exportDonePartial(written, Int(authorised), Int(authorised) - written)
            : HistoryStrings.exportDone(written)
    }
}
