import Foundation
import VettIDVault

/// The names a feed item's text uses, from the app's in-memory caches as History resolves them (ANDROID-PLAN §4
/// Notifications, 4): the connections ("First Last"), the items of the Vault list (names only, never values; empty until
/// the Vault screens, IOS-PLAN §8 I3.1), and the Approvals entries by ``PendingApproval/key`` (a request's sender before
/// it is a connection, a grant's item). Mirrors vettid-android `FeedNames`.
public struct FeedNames: Equatable, Sendable {
    public var connections: [String: ConnectionInfo]
    public var items: [String: String]
    public var approvals: [String: PendingApproval]

    public init(connections: [String: ConnectionInfo] = [:], items: [String: String] = [:], approvals: [String: PendingApproval] = [:]) {
        self.connections = connections
        self.items = items
        self.approvals = approvals
    }

    /// From the lists the repositories hold.
    public init(connections: [ConnectionInfo], items: [String: String] = [:], approvals: [PendingApproval]) {
        self.init(
            connections: Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            items: items,
            approvals: Dictionary(approvals.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        )
    }
}

/// The member-facing text of each feed kind (IOS-PLAN §4.1 "Event titles", ANDROID-PLAN §4 Notifications, 4): the row's
/// title and second line, also the text of a notification (IOS-PLAN §6.7). One mapping for the Notifications screen,
/// its detail sheet and the notifications. Mirrors the text part of vettid-android `FeedKinds`.
public extension FeedKinds {
    /// The connection's "First Last" (never an alias), the request's sender, or "Removed connection".
    static func connectionName(_ item: FeedItem, _ names: FeedNames) -> String {
        let c = item.connectionID.flatMap { names.connections[$0] }
        let sender = FeedAsks.approvalKey(item.kind, ref: item.ref).flatMap { names.approvals[$0] }.flatMap(senderOf)
        if let name = c?.accountName ?? c.flatMap({ $0.name.isEmpty ? nil : $0.name }) ?? sender { return name }
        if c != nil { return DataStrings.feedNameNotShared }
        return item.connectionID != nil ? DataStrings.feedRemovedConnection : DataStrings.feedSomeone
    }

    /// The connection's first name (the short labels), else as ``connectionName(_:_:)``.
    static func firstName(_ item: FeedItem, _ names: FeedNames) -> String {
        if let first = item.connectionID.flatMap({ names.connections[$0] })?.firstName, !first.isEmpty { return first }
        return connectionName(item, names)
    }

    private static func senderOf(_ a: PendingApproval) -> String? {
        guard case .connection(let r) = a else { return nil }
        var name = r.name
        if name == nil, case .incoming(let x) = r { name = x.displayName }
        return name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    /// "Deleted item": a revealed item that is no longer in the vault (the detail sheet's Item line).
    static var deletedItem: String { DataStrings.feedDeletedItem }

    /// The item's name (never a value), when the item or the ask names one.
    static func itemName(_ item: FeedItem, _ names: FeedNames) -> String? {
        let ask = FeedAsks.approvalKey(item.kind, ref: item.ref).flatMap { names.approvals[$0] }
        let name: String?
        switch (item.kind, ask) {
        case ("item.revealed", _), ("leash.item.run", _), ("leash.item.proxy", _): name = item.ref.flatMap { names.items[$0] }
        case ("grant.request", .grant(let g)?): name = g.entries.count == 1 ? (g.entries[0].name ?? g.entries[0].label) : nil
        case ("critical-secret.use.request", .critical(let c)?): name = c.itemName
        default: name = nil
        }
        return name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    /// The row's title. [details] false (a notification with names only, ANDROID-PLAN §4 Notification modes 8): the
    /// connection's or device's name and the kind only, no item names or tags.
    static func title(_ item: FeedItem, _ names: FeedNames, details: Bool = true) -> String {
        if let t = connectionTitle(item, names) ?? askTitle(item, names, details: details) ?? deviceTitle(item)
            ?? checkTitle(item) ?? laterTitle(item, names) ?? eventTitle(item, names, details: details) {
            return t
        }
        return item.kind.hasPrefix("leash.") ? DataStrings.feedLeash : DataStrings.feedUnknown(item.kind)
    }

    /// The row's second line: the batch's "3 things", a guide's first line, a signer change, the event's second line of
    /// IOS-PLAN §4.1, or the item's name; nil for none.
    static func supporting(_ item: FeedItem, _ names: FeedNames) -> String? {
        if let n = item.count, n > 1 { return DataStrings.feedThings(n) }
        switch item.kind {
        case "guide":
            guard let body = item.body, !body.isEmpty else { return nil }
            return body.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init)
        case "device.signer_changed": return signerChangeText(item.ref)
        default: return eventLine(item) ?? itemName(item, names)
        }
    }

    /// `device.signer_changed`'s `ref` (§11.7.1) as "From … to …" in the member's words; nil when it does not read.
    static func signerChangeText(_ ref: String?) -> String? {
        guard let (old, new) = signerChange(ref) else { return nil }
        return DataStrings.feedSignerFromTo(signerLabel(old), signerLabel(new))
    }

    /// A signer class in the member's words; a class this app does not know reads "another signer".
    static func signerLabel(_ signerClass: String?) -> String {
        switch SignerClass.of(signerClass) {
        case .googlePlay: DataStrings.signerGooglePlay
        case .vettid: DataStrings.signerVettid
        case .development: DataStrings.signerDevelopment
        case nil: DataStrings.signerOther
        }
    }

    private static func connectionTitle(_ item: FeedItem, _ names: FeedNames) -> String? { // swiftlint:disable:this cyclomatic_complexity
        let who = { connectionName(item, names) }
        switch item.kind {
        case "connection.request": return DataStrings.feedConnectionRequest(who())
        case "connection.request.peer_declined": return DataStrings.feedConnectionPeerDeclined(who())
        case "connection.added": return DataStrings.feedConnectionAdded(who())
        case "connection.removed": return DataStrings.feedConnectionRemoved(who())
        case "connection.stale": return DataStrings.feedConnectionStale(who())
        case "connection.asks_paused": return DataStrings.feedAsksPaused(firstName(item, names))
        case "connection.authenticate.requested": return DataStrings.feedAuthenticate(who())
        case "message.received": return DataStrings.feedMessage(who())
        // §10.5.1: an outgoing photo that failed, an incoming one refused because the vault is full.
        case "message.attachment_failed": return DataStrings.feedPhotoFailed(who())
        case "message.attachment_refused": return DataStrings.feedPhotoRefused(who())
        case "call.missed": return DataStrings.feedCallMissed(who())
        default: return nil
        }
    }

    private static func askTitle(_ item: FeedItem, _ names: FeedNames, details: Bool) -> String? {
        let first = firstName(item, names)
        let thing = details ? itemName(item, names) : nil
        switch item.kind {
        case "grant.request":
            if let n = item.count, n > 1 { return DataStrings.feedGrantRequestBatch(first, n) }
            return thing.map { DataStrings.feedGrantRequest(first, $0) } ?? DataStrings.feedGrantRequestAny(first)
        case "grant.shared": return DataStrings.feedGrantShared(first)
        case "grant.revoked": return DataStrings.feedGrantRevoked(first)
        // The rule's tag comes with the share rules (IOS-PLAN §8 I3.2); until then the title without it.
        case "share.pending": return DataStrings.feedSharePendingAny(first)
        case "share.rate_limited": return DataStrings.feedShareRateLimited(first)
        case "critical-secret.use.request":
            return thing.map { DataStrings.feedCriticalUse(first, $0) } ?? DataStrings.feedCriticalUseAny(first)
        case "item.revealed":
            guard details else { return DataStrings.feedItemRevealedAny }
            return DataStrings.feedItemRevealed(itemName(item, names) ?? DataStrings.feedDeletedItem)
        default: return nil
        }
    }

    private static func deviceTitle(_ item: FeedItem) -> String? {
        switch item.kind {
        case "device.pair.pending": DataStrings.feedDevicePairPending
        case "device.paired": DataStrings.feedDevicePaired
        case "device.unlinked": DataStrings.feedDeviceUnlinked
        case "device.transferred": DataStrings.feedDeviceTransferred
        case "device.replaced": DataStrings.feedDeviceReplaced
        case "device.signer_changed": DataStrings.feedDeviceSignerChanged
        case "device.session.pending": DataStrings.feedDeviceSession
        case "approval.pending": DataStrings.feedDeviceApproval
        default: nil
        }
    }

    private static func checkTitle(_ item: FeedItem) -> String? { // swiftlint:disable:this cyclomatic_complexity
        switch item.kind {
        case "credential.alarm": return DataStrings.feedCredentialAlarm
        case "credential.password_failed": return DataStrings.feedPasswordFailed
        case "credential.rotated": return DataStrings.feedCredentialRotated
        case "credential.reset": return DataStrings.feedCredentialReset
        case "owner_check.failed":
            switch item.ref {
            case "pin": return DataStrings.feedCheckFailedPin
            case "password": return DataStrings.feedCheckFailedPassword
            default: return DataStrings.feedCheckFailed
            }
        case "owner_check.locked": return DataStrings.feedCheckLocked
        case "owner_check.hold_changed": return holdChangedTitle(item.ref)
        default: return nil
        }
    }

    /// `owner_check.hold_changed`'s `ref` (§3.6.7): on, off, off until a time (shown in local time), back on.
    private static func holdChangedTitle(_ ref: String?) -> String {
        switch holdChange(ref) {
        case .offUntil(let until?): DataStrings.feedHoldOffUntil(until.formatted(date: .abbreviated, time: .shortened))
        case .offUntil(nil), .off: DataStrings.feedHoldOff
        case .backOn: DataStrings.feedHoldBackOn
        case .on: DataStrings.feedHoldOn
        }
    }

    private static func laterTitle(_ item: FeedItem, _ names: FeedNames) -> String? { // swiftlint:disable:this cyclomatic_complexity
        let first = { firstName(item, names) }
        switch item.kind {
        case "guide": return item.title.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? DataStrings.feedGuide
        case "leash.rate_limited": return DataStrings.feedLeashRateLimited
        case "leash.item.read": return DataStrings.feedLeashItemRead
        case "leash.agent.suspended": return DataStrings.feedLeashSuspended
        case "leash.referrals_limited": return DataStrings.feedLeashReferrals
        case "action.request": return DataStrings.feedActionRequest(first())
        case "intro.request": return DataStrings.feedIntroRequest(first())
        case "location.shared": return DataStrings.feedLocationShared(first())
        case "location.request": return DataStrings.feedLocationRequest(first())
        case "wallet.signed": return DataStrings.feedWalletSigned
        default: return nil
        }
    }

    // swiftlint:disable cyclomatic_complexity
    /// Release R's kinds (IOS-PLAN §4.1 Notifications table). The History-only kinds have titles too, for a detail sheet.
    private static func eventTitle(_ item: FeedItem, _ names: FeedNames, details: Bool) -> String? {
        switch item.kind {
        case "vault.pin_changed": return DataStrings.feedPinChanged
        case "device.secret_renewed": return DataStrings.feedSecretRenewed
        case "credential.recovered": return DataStrings.feedCredentialRecovered
        case "recovery.device_paired": return DataStrings.feedRecoveryDevicePaired
        case "recovery.completed": return DataStrings.feedRecoveryCompleted
        case "recovery.attempt": return recoveryAttemptTitle(item)
        case "recovery.change_required":
            return item.ref == passwordRef ? DataStrings.feedChangeRequiredPassword : DataStrings.feedChangeRequired
        case "recovery.counter_unavailable": return DataStrings.feedCounterUnavailable
        // VAULT-MESSAGING 0.50.0 (owner decision of 2026-10-20): the vault makes this item only for `rollback`; another or
        // an unreadable `ref` never raises the alarm (the item is not listed, ``FeedKinds/isHidden(_:)``).
        case "recovery.generation_closed":
            return RecoveryRefs.rollback(item.kind, ref: item.ref) ? DataStrings.feedRecoveryRollback : DataStrings.feedUnknown(item.kind)
        case "identity.rotation_failed": return DataStrings.feedRotationFailed
        case "identity.rotate_conflict": return DataStrings.feedRotateConflict(connectionName(item, names))
        case "leash.item.run", "leash.item.proxy":
            let thing = details ? itemName(item, names) : nil
            return thing.map { DataStrings.feedLeashItemUsed($0) } ?? DataStrings.feedLeashItemUsedAny
        default: return nil
        }
    }
    // swiftlint:enable cyclomatic_complexity

    /// `recovery.attempt` (decision 2): urgent and not successful, "Someone tried to recover your vault"; urgent and
    /// successful, "Your vault was recovered"; not urgent (the member completed a recovery in that generation since),
    /// "Recovery attempt n of 10". Without a `ref` that reads, the same words without the number.
    private static func recoveryAttemptTitle(_ item: FeedItem) -> String {
        let of = RecoveryRefs.attempts
        switch (RecoveryRefs.attempt(item.ref), urgent(item)) {
        case (nil, true): return DataStrings.feedRecoveryAttemptSomeoneAny
        case (nil, false): return DataStrings.feedRecoveryAttemptAny
        case (let a?, false): return DataStrings.feedRecoveryAttempt(a.n, of)
        case (let a?, true) where a.success: return DataStrings.feedRecoveryAttemptRecovered(a.n, of)
        case (let a?, true): return DataStrings.feedRecoveryAttemptSomeone(a.n, of)
        }
    }

    /// The second line of IOS-PLAN §4.1, for the kinds that have one.
    private static func eventLine(_ item: FeedItem) -> String? {
        switch item.kind {
        case "recovery.change_required":
            item.ref == passwordRef ? DataStrings.feedChangeRequiredPasswordBody : DataStrings.feedChangeRequiredBody
        case "identity.rotation_failed": DataStrings.feedRotationFailedBody
        case "identity.rotate_conflict": DataStrings.feedRotateConflictBody
        case "recovery.generation_closed": RecoveryRefs.rollback(item.kind, ref: item.ref) ? DataStrings.feedRecoveryRollbackBody : nil
        default: nil
        }
    }

    private static var passwordRef: String { "password" }
}
