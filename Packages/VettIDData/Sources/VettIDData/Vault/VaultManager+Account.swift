import Foundation
import VettIDVault

/// What ``VaultManager/refreshAccount()`` keeps from an `account.get`. Mirrors vettid-android `AccountUpdate`.
struct AccountUpdate: Equatable, Sendable {
    let snapshot: AccountSnapshot?
    let nameRequest: NameRequest?
}

/// The account snapshot (VAULT-MESSAGING §11.13) as the record keeps it and the screens see it. Mirrors vettid-android
/// `accountUpdate`, `AccountSnapshot.toInfo` and `validEmail`.
enum AccountSnapshots {
    /// The account record after `account.get` [v] (§10.2, §11.13): the snapshot only when it is newer (`as_of`), and the
    /// name request whenever it changed (the one with the higher `seq`), whatever the snapshot's version (0.19.0: a change of the request alone repeats
    /// the version, so an `account.changed` is never skipped). Nil when nothing changed.
    static func update(stored: AccountSnapshot?, storedRequest: NameRequest?, view v: AccountView) -> AccountUpdate? {
        let newSnapshot = v.account.map { snap in stored.map { newer(snap.asOf, $0.asOf) } ?? true } ?? false
        let request = latest(v.nameRequest, storedRequest)
        if !newSnapshot && request == storedRequest { return nil }
        return AccountUpdate(snapshot: newSnapshot ? v.account : stored, nameRequest: request)
    }

    /// The request with the higher `seq` (the later one; the vault's on a tie, which carries its state).
    static func latest(_ a: NameRequest?, _ b: NameRequest?) -> NameRequest? {
        guard let a, let b else { return a ?? b }
        return a.seq >= b.seq ? a : b
    }

    /// Whether RFC 3339 [a] is later than [b] (a snapshot without a readable `as_of` replaces one only when none is
    /// stored).
    static func newer(_ a: String?, _ b: String?) -> Bool {
        let ia = OwnerCheckManager.instant(a)
        let ib = OwnerCheckManager.instant(b)
        guard let ia else { return b == nil }
        guard let ib else { return true }
        return ia > ib
    }

    /// The snapshot for display (§11.13): names that break the core rule and an implausible address are not shown.
    static func info(_ s: AccountSnapshot, fallbackHint: String) -> AccountInfo {
        let t = OwnerCheckManager.instant
        return AccountInfo(
            emailHint: s.emailHint ?? fallbackHint,
            state: s.state ?? "",
            accountStatus: s.accountStatus,
            deletesAt: t(s.deletesAt),
            termsNeedAcceptance: s.terms?.needsAcceptance ?? false,
            subscription: s.subscription.map {
                SubscriptionInfo(typeName: $0.typeName, status: $0.status, paid: $0.paid ?? false, expiresAt: t($0.expiresAt))
            },
            votingRights: s.votingRights ?? false,
            asOf: t(s.asOf),
            firstName: AccountNames.isValidCore(s.firstName) ? s.firstName : nil,
            lastName: AccountNames.isValidCore(s.lastName) ? s.lastName : nil,
            nameAllowedAfter: t(s.nameChange?.allowedAfter),
            email: s.email.flatMap { validEmail($0) ? $0 : nil }
        )
    }

    /// 3 to 1,016 bytes of UTF-8, an `@`, and no control character.
    static func validEmail(_ e: String) -> Bool {
        (3...1_016).contains(e.utf8.count) && e.contains("@") && !e.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}

// The account as the vault reports it (VAULT-MESSAGING §10.2 `account.get`, §11.13) and the account's names (§10.8).
extension VaultManager {
    static let syncAccountChanged = "account.changed"
    static let syncProfileChanged = "profile.changed"

    /// Re-reads the account snapshot (`account.get`, §11.13); kept only when newer (`as_of`), the name request whenever it
    /// changed, in memory only and only while the vault is open (``OwnAccount``, IOS-PLAN §4.7). Quiet on failure:
    /// display only, the last snapshot stays. Mirrors vettid-android `refreshAccount`.
    public func refreshAccount() async {
        // The record this answer is for: after a wipe or a reset meanwhile, nothing of it is kept.
        let rec = record.generation
        // And the own account's: an answer on its way when the vault closes is not kept.
        let mark = ownAccount.mark()
        guard let v = try? await guarded({ try await openApi(try await openSession()).accountGet() }) else { return }
        guard rec == record.generation, let kept = ownAccount.keep(mark: mark, view: v, open: { ownProfileOpen }) else { return }
        let u = kept.update
        try? record.refreshed(since: rec, u)
        publishAccount()
        // An applied name change brings new names to the shared profile's core too.
        if u.snapshot?.firstName != kept.before?.firstName || u.snapshot?.lastName != kept.before?.lastName {
            profiles.refreshQuietly()
        }
    }

    /// A name request this phone just sent (``ProfileManager``), kept in memory with the own account it was sent for
    /// ([since], ``OwnAccount/mark()``), while the vault is open.
    func keepNameRequest(_ r: NameRequestView, since: Int) {
        if ownAccount.request(mark: since, r.wire, open: { ownProfileOpen }) { publishAccount() }
    }

    /// What the app shows of the account now: the record's masked email and, while the vault is open, ``ownAccount``.
    func publishAccount() {
        account = record.value.info(snapshot: ownAccount.snapshot, nameRequest: ownAccount.nameRequest)
    }

    /// The vault is open for the own profile: unlocked, and neither held nor due (§3.6.3). Otherwise the member's names,
    /// full email and photo are not kept (IOS-PLAN §4.7).
    var ownProfileOpen: Bool { isOwnProfileOpen(phase, ownerChecks.ownerCheck) }

    /// The vault is not open (a lock, the hold or the due state, a sign-out, a reset, a wipe, a deletion): the own account
    /// and the own profile (the names, the full email, the photo) leave memory, and the shell shows the initial tile.
    func forgetOwnProfile() {
        ownAccount.forget()
        profiles.clear()
        publishAccount()
    }

    /// The vault opened again (a passed check): the own account and profile are read from it.
    func readOwnProfile() {
        Task { [weak self] in await self?.refreshAccount() }
        profiles.refreshQuietly()
    }

    /// `sync.event{kind: "account.changed"}` (§10.1): a newer snapshot or a changed name request (0.19.0: never skipped).
    func syncAccount(_ m: VaultMessage) {
        switch VaultJSON.string(m.object, "kind") {
        case Self.syncAccountChanged: Task { [weak self] in await self?.refreshAccount() }
        // §10.8: the profile object changed (on another of the member's devices, or here).
        case Self.syncProfileChanged: profiles.refreshQuietly()
        default: break
        }
    }

    /// The phase moved from [oldValue] to [phase]. (ANDROID-PLAN 0.1.134, as vettid-android #411) Unlocked, then only
    /// Unreachable, then Unlocked is the same opening: a status read that could not be made closed nothing. The feed is kept
    /// meanwhile, with its mark; any other phase in between ends the opening, and the feed with it.
    func openOrClose(_ phase: AppPhase, was oldValue: AppPhase) {
        let continued = openingPaused
        openingPaused = phase.isUnreachable && (oldValue == .unlocked || openingPaused)
        // The account is read again whenever the vault opens (an unlock, the end of onboarding, a start while open).
        if phase == .unlocked, oldValue != .unlocked { onOpened(continued: continued) }
        if phase != .unlocked, oldValue == .unlocked {
            forgetOpenLists(keepingFeed: openingPaused) // not kept once it is locked
            releaseUpdate.vaultClosed() // the release is checked anew at the next opening
        }
        if continued, !openingPaused, phase != .unlocked { feed.clear() }
    }

    /// The vault opened (an unlock, the end of onboarding, a start while open): the account is read again. [continued]: only
    /// a status read that could not be made came since the vault was last open, so the feed's opening goes on.
    func onOpened(continued: Bool = false) {
        Task { [weak self] in await self?.refreshAccount() }
        // (VAULT-MESSAGING 0.70.0 §10.4.2) A vault that did not know `pending.list` is asked again after each unlock, not
        // after a passed owner check.
        approvals.vaultOpened()
        // The open app shows nothing of the vault until its release is known (``ReleaseUpdateManager/required``). The lists
        // are read at once, as before (skipped while the vault is behind, and read when it no longer is: ``followBehind``).
        // The feed's mark: the phone's clock now, replaced by this moment on the vault's clock (its messages' `ts` are) once
        // the first answer to a request of this opening comes (a vault time learnt before it, or an event's `ts`, can be the
        // mailbox's days-old backlog at a cold start). Fixed in the feed, so a device let go meanwhile (a background)
        // changes nothing. A held event the vault sent before it is the backlog, never notified.
        // The same opening after only a status read that failed (as vettid-android #411): its mark is kept, so what the
        // vault sent meanwhile is judged against it (the vault was open before, so it has one). The release is checked
        // again all the same.
        if !continued {
            let opening = feed.vaultOpened(at: config.now())
            session?.device.beginOpening { [weak self] at in
                Task { @MainActor in self?.feed.openingMarked(at, opening: opening) }
            }
        }
        releaseUpdate.vaultOpened()
        refreshListsQuietly()
        // The clone alarm is read after every unlock, whatever event was or was not received (a held background's, a process that
        // ended): `credential.version` shows it (§3.5.9).
        Task { [weak self] in
            guard let self, let s = try? await openSession(), let api = try? openApi(s) else { return }
            await refreshAlarm(api)
        }
        // §10.5.1 "Compatibility": once after each unlock.
        Task { [weak self] in await self?.attachments.probe() }
        // A change whose answer was lost is decided as soon as the vault runs (§11.14.9 step 2).
        kickChangeCheck()
        // The proactive release notice (ANDROID-PLAN "Vault update"): the manifest, read after every unlock.
        Task { [weak self] in await self?.releaseUpdate.refreshOffer() }
    }
}

extension AppPhase {
    /// ``unreachable(_:longUnreachable:)``, whatever its kind.
    var isUnreachable: Bool {
        if case .unreachable = self { return true }
        return false
    }
}
