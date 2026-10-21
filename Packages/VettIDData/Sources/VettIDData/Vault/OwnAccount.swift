import Foundation
import VettIDVault

/// The member's own account as the open vault reported it (IOS-PLAN §4.7): the snapshot of `account.get` (the names,
/// the full email address, the membership) and the latest name request. **Memory only**: never in the account record,
/// the Keychain, `UserDefaults`, a file or state restoration, and forgotten (``forget()``) whenever the vault is not open
/// (a lock, the hold or the due state, a sign-out, a reset, a wipe, a deletion). It comes back from the vault after the
/// next unlock (or the passed check).
///
/// Every write is dropped when a ``forget()`` came after the ``mark()`` read before the request it answers was sent, or
/// when the vault is not open at the moment of the write: an answer on its way when the vault locks never brings the
/// names back. On the main actor, so without vettid-android's lock. Mirrors vettid-android `OwnAccount`.
@MainActor
final class OwnAccount {
    private var generation = 0
    private(set) var snapshot: AccountSnapshot?
    private(set) var nameRequest: NameRequest?

    /// What ``keep(mark:view:open:)`` kept: the snapshot [before] it and the [update].
    struct Kept: Equatable {
        let before: AccountSnapshot?
        let update: AccountUpdate
    }

    /// Read before a request whose answer is to be kept (``keep(mark:view:open:)``, ``request(mark:_:open:)``).
    func mark() -> Int { generation }

    /// Keeps what is new in `account.get`'s [v] (``AccountSnapshots/update(stored:storedRequest:view:)``, against the
    /// snapshot and the request held now: an older answer never replaces a newer one) while no ``forget()`` came after
    /// [mark] and [open] still says the vault is open. Nil when nothing was kept.
    func keep(mark: Int, view v: AccountView, open: () -> Bool) -> Kept? {
        guard mark == generation, open() else { return nil }
        let before = snapshot
        guard let u = AccountSnapshots.update(stored: before, storedRequest: nameRequest, view: v) else { return nil }
        snapshot = u.snapshot
        nameRequest = u.nameRequest
        return Kept(before: before, update: u)
    }

    /// A name request the vault stored (`account.name.set`), under the same conditions as ``keep(mark:view:open:)``: the
    /// later of it and the one held.
    func request(mark: Int, _ r: NameRequest, open: () -> Bool) -> Bool {
        guard mark == generation, open() else { return false }
        nameRequest = AccountSnapshots.latest(r, nameRequest)
        return true
    }

    /// The vault is not open: the snapshot and the name request go; every answer still on its way is dropped.
    func forget() {
        generation += 1
        snapshot = nil
        nameRequest = nil
    }
}

/// Whether the vault is open for the own profile (IOS-PLAN §4.7): [phase] unlocked and the owner check ([check]) neither
/// held nor due (VAULT-MESSAGING §3.6.3; none read yet counts as open). Otherwise the member's names, full email and
/// photo are not kept. Mirrors vettid-android `isOwnProfileOpen`.
func isOwnProfileOpen(_ phase: AppPhase, _ check: OwnerCheckView?) -> Bool {
    phase == .unlocked && (check?.state ?? .ok) == .ok
}

/// What the vault manager does with the own profile when the phase or the owner check moves (IOS-PLAN §4.7). Mirrors
/// vettid-android `OwnProfileStep`.
enum OwnProfileStep: Equatable {
    /// Forget the own account and profile (the vault is not open).
    case forget
    /// Read them again from the vault (it opened again).
    case read
    case none

    /// The phase moved to [phase]: unlocked reads, starting does nothing, every other phase forgets.
    static func onPhase(_ phase: AppPhase) -> OwnProfileStep {
        switch phase {
        case .unlocked: .read
        case .starting: .none
        default: .forget
        }
    }

    /// The owner check moved from [wasHeld] to [held] (held or due) during [phase].
    static func onCheck(wasHeld: Bool, held: Bool, phase: AppPhase) -> OwnProfileStep {
        if held && !wasHeld { return .forget }
        if !held && wasHeld && phase == .unlocked { return .read }
        return .none
    }

    /// Held or due (§3.6.3).
    static func held(_ v: OwnerCheckView?) -> Bool { v.map { $0.state != .ok } ?? false }
}

/// The account record's keys an older build kept the own account under (``LocalAccount``).
private let legacyOwnAccountKeys: Set<String> = ["snapshot", "name_request"]

/// Whether the account record's JSON [raw] still holds the own account of an older build (the snapshot or the name
/// request): ``AccountRecord/load()`` then writes the record again without it. Mirrors vettid-android
/// `holdsLegacyOwnAccount`.
func holdsLegacyOwnAccount(_ raw: [UInt8]) -> Bool {
    guard let o = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any] else { return false }
    return o.keys.contains { legacyOwnAccountKeys.contains($0) }
}

public extension Optional where Wrapped == AccountInfo {
    /// What the top bar, the avatar sheet and the Settings account card may show of the account (IOS-PLAN §4.7): the
    /// account only while it comes from the open vault's snapshot (kept in memory only while the vault is open); nil
    /// otherwise, and they show only the initial tile: no name, no address, not even the masked hint (which only the
    /// unlock screen shows). Mirrors vettid-android `AccountInfo?.shownInShell`.
    var shownInShell: AccountInfo? {
        guard let a = self, a.hasSnapshot else { return nil }
        return a
    }
}
