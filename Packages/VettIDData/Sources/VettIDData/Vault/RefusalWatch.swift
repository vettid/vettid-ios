import Foundation

/// A phone replaced while it was offline, whose vault the new phone already unlocked, sees the vault `unlocked` and opens
/// the app, never the unlock screen, so it never meets the unreadable unlock result that offers "Erase VettID from this
/// phone". What it meets instead is the relay refusing its deposits to the vault (`token_revoked`: the vault denylisted
/// its relay key, RELAY-PROTOCOL; VAULT-MESSAGING §7.4). Mirrors vettid-android `RefusalWatch`.
///
/// [threshold] such refusals in a row, with no message from the vault in between, send the open app to the unlock screen
/// ([route]: the phase becomes ``AppPhase/locked``) with ``suspected`` set, where the member's PIN asks the enclave
/// itself. The relay's refusals are not authenticated, so this never wipes anything: only an authenticated
/// `device.unlinked` or a sealed `unknown_device` does (``HolderPolicy``).
@MainActor
final class RefusalWatch {
    /// Refused deposits in a row (each a separate request: the app retries none of them, §8.6).
    static let threshold = 3

    private let limit: Int
    private let route: @MainActor () -> Void

    /// The vault refused this phone [threshold] times in a row while it was open; cleared by any sign that it knows it.
    private(set) var suspected = false

    init(threshold: Int = RefusalWatch.threshold, route: @escaping @MainActor () -> Void) {
        limit = threshold
        self.route = route
    }

    /// The device's count of consecutive refusals changed, in [phase]. Routes once, from the open app only, when the count
    /// reaches the threshold; a count back at 0 (the vault spoke to this phone) clears the suspicion. Returns whether it
    /// routed.
    @discardableResult
    func onRefusals(_ count: Int, phase: AppPhase) -> Bool {
        if count == 0 { suspected = false }
        let routes = count >= limit && !suspected && phase == .unlocked
        if routes {
            suspected = true
            route()
        }
        return routes
    }

    /// A sealed unlock result (any): the enclave knows this phone.
    func clear() { suspected = false }
}
