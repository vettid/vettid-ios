import Foundation
import Testing
@testable import VettIDData
import VettIDVault

// Fixtures and expected texts stay on one line each.
// swiftlint:disable line_length

/// The feed's titles and second lines, word for word: release R's kinds as IOS-PLAN §4.1 "Event titles" gives them
/// (approved by the owner), the earlier kinds as vettid-android's, the names they use and the History-only kinds. Mirrors
/// vettid-android `FeedEventTitlesTest`, with every kind's words checked.
@Suite struct FeedEventTitlesTests {
    static func item(_ kind: String, _ ref: String? = nil, _ priority: String = "normal", connection: String? = nil, count: Int? = nil) -> FeedItem {
        var i = FeedItem(itemID: "i", seq: 1, kind: kind, at: "2026-10-19T12:00:00Z", status: "active", priority: priority, connectionID: connection, ref: ref)
        i.count = count
        return i
    }

    static let names: FeedNames = {
        var sam = ConnectionInfo(id: "c1", name: "", state: .active)
        sam.firstName = "Sam"
        sam.lastName = "Lee"
        let unnamed = ConnectionInfo(id: "c2", name: "", state: .active)
        let grant = GrantRequest(
            requestID: "g1", connectionID: "c1", entries: [GrantEntry(kind: "item", ref: "01ITEM", label: "Token", available: true, name: "GitHub token")],
            receivedAt: Date(), exp: nil
        )
        let critical = CriticalUse(requestID: "k1", connectionID: "c1", itemName: "Signing key", fieldLabel: "Seed", operation: "sign", payload: "", payloadSha256: "", receivedAt: Date(), exp: nil)
        let request = PendingConnection.incoming(ConnectionRequest(pendingID: "p1", sas: "123456", remote: false, name: "Ada Lovelace", receivedAt: Date(), exp: nil))
        return FeedNames(
            connections: ["c1": sam, "c2": unnamed], items: ["01ITEM": "GitHub token"],
            approvals: ["grant:g1": .grant(grant), "critical:k1": .critical(critical), request.key: .connection(request)]
        )
    }()

    func title(_ i: FeedItem, details: Bool = true) -> String { FeedKinds.title(i, Self.names, details: details) }
    func line(_ i: FeedItem) -> String? { FeedKinds.supporting(i, Self.names) }

    /// IOS-PLAN §4.1 Notifications table, row by row.
    @Test func releaseRKindsHaveTheApprovedTitles() {
        #expect(title(Self.item("device.secret_renewed")) == "Your phone now uses a new secret for your vault")
        #expect(title(Self.item("recovery.completed", "01REC")) == "Recovery finished: your vault is on your new phone")
        #expect(title(Self.item("recovery.counter_unavailable", nil, "urgent")) == "Your vault cannot check its recovery attempts")
        #expect(line(Self.item("recovery.counter_unavailable", nil, "urgent")) == nil)
        #expect(title(Self.item("identity.rotation_failed", "recovery", "high")) == "Your vault could not update its keys")
        #expect(line(Self.item("identity.rotation_failed")) == "Your connections still know your old keys. VettID will offer the update again.")
        #expect(title(Self.item("identity.rotate_conflict", nil, "high", connection: "c1")) == "Sam Lee: verify again")
        #expect(line(Self.item("identity.rotate_conflict", connection: "c1")) == "This connection's vault announced two different new keys. That can mean someone holds an old copy of their vault. Nothing is sent or received until you check.")
        // Without the connection any more: the name falls back, never "Removed connection: …" twice.
        #expect(title(Self.item("identity.rotate_conflict", connection: "gone")) == "Removed connection: verify again")
        for k in ["device.secret_renewed", "recovery.completed", "recovery.attempt"] { #expect(line(Self.item(k, "2/3/not_success/counter")) == nil, "\(k)") }
    }

    /// Decision 2: a failed attempt raises the alarming title; after the member's own recovery, the plain count.
    @Test func aRecoveryAttemptFollowsItsPriorityAndOutcome() {
        #expect(title(Self.item("recovery.attempt", "2/3/not_success/counter", "urgent")) == "Someone tried to recover your vault (attempt 3 of 10)")
        #expect(title(Self.item("recovery.attempt", "2/4/success/counter", "urgent")) == "Your vault was recovered (attempt 4 of 10)")
        #expect(title(Self.item("recovery.attempt", "2/4/success/counter")) == "Recovery attempt 4 of 10")
        #expect(title(Self.item("recovery.attempt", "1/1/not_success/counter")) == "Recovery attempt 1 of 10")
        // A ref that does not read: the words without the number.
        #expect(title(Self.item("recovery.attempt", "2/3", "urgent")) == "Someone tried to recover your vault")
        #expect(title(Self.item("recovery.attempt", nil)) == "Recovery attempt")
        #expect(title(Self.item("recovery.attempt", "2/11/not_success/counter", "urgent")) == "Someone tried to recover your vault")
    }

    @Test func changeRequiredReadsItsRef() {
        let password = Self.item("recovery.change_required", "password", "high")
        let used = Self.item("recovery.change_required", "3", "high")
        #expect(title(password) == "Choose a stronger password to keep recovery on")
        #expect(line(password) == "Your password is too weak for recovery. Recovery stays off until you change it.")
        #expect(title(used) == "Change your PIN or password to turn recovery back on")
        #expect(line(used) == "Recovery attempts were used. A change gives you 10 new attempts.")
    }

    /// The `rollback` closure's urgent item (owner decision of 2026-10-20) and its second line.
    @Test func aRollbackHasItsAlarmingTitleAndSecondLine() {
        let r = Self.item("recovery.generation_closed", "4/rollback", "urgent")
        #expect(title(r) == "Your vault was given an older recovery record")
        #expect(line(r) == "A host may have served an older copy of your vault's recovery record, one on which recovery attempts had already been used. Your vault moved past it. If you did not try to recover your vault, change your PIN and your password now, and contact VettID.")
        #expect(FeedKinds.isKnown("recovery.generation_closed") && FeedKinds.urgent(r))
        #expect(RecoveryRefs.rollback(r.kind, ref: r.ref) && !FeedKinds.isHidden(r))
        // A `stale` or unreadable ref never raises the alarm: no rollback words, and not listed.
        for ref in ["4/stale", "rollback", "x/rollback", nil] {
            let other = Self.item("recovery.generation_closed", ref, "urgent")
            #expect(title(other) == "Activity: recovery.generation_closed" && line(other) == nil, "\(ref ?? "nil")")
            #expect(FeedKinds.isHidden(other), "\(ref ?? "nil")")
        }
        #expect(FeedKinds.isHidden(Self.item("vault.pin_changed")) && !FeedKinds.isHidden(Self.item("recovery.completed")))
    }

    /// Decision 8: "An agent used <item>"; without details (names only) or once the item is gone, no item name.
    @Test func anAgentsRunAndProxyNameTheItem() {
        for k in ["leash.item.run", "leash.item.proxy"] {
            #expect(title(Self.item(k, "01ITEM")) == "An agent used GitHub token")
            #expect(title(Self.item(k, "01ITEM"), details: false) == "An agent used an item")
            #expect(title(Self.item(k, "01GONE")) == "An agent used an item")
            #expect(FeedKinds.classify(k) == .later)
        }
    }

    /// Decision 3: the History-only kinds are titled (for an older list's sheet) but flagged; one recovery, one notification.
    @Test func theHistoryOnlyKindsAreFlagged() {
        #expect(FeedKinds.historyOnly == ["vault.pin_changed", "credential.recovered", "recovery.device_paired"])
        #expect(!FeedKinds.isHistoryOnly("recovery.completed") && !FeedKinds.isHistoryOnly("recovery.attempt"))
        #expect(title(Self.item("vault.pin_changed")) == "Your PIN was changed")
        #expect(title(Self.item("credential.recovered")) == "Your credential was restored from its backup")
        #expect(title(Self.item("recovery.device_paired")) == "Your new phone was connected to your vault")
        let added = [
            "vault.pin_changed", "device.secret_renewed", "credential.recovered", "recovery.device_paired", "recovery.completed",
            "recovery.attempt", "recovery.change_required", "recovery.counter_unavailable", "identity.rotation_failed",
            "identity.rotate_conflict", "leash.item.run", "leash.item.proxy", "recovery.generation_closed",
        ]
        for k in added {
            #expect(FeedKinds.isKnown(k), "\(k)")
            #expect(!title(Self.item(k, k == "recovery.generation_closed" ? "4/rollback" : nil)).hasPrefix("Activity:"), "\(k)")
        }
    }

    @Test func connectionsAndMessagesNameThePerson() {
        let c = { (k: String) in title(Self.item(k, connection: "c1")) }
        #expect(c("connection.added") == "You are now connected with Sam Lee")
        #expect(c("connection.removed") == "Sam Lee was removed" && c("connection.stale") == "Sam Lee has not been reachable")
        #expect(c("connection.request.peer_declined") == "Sam Lee did not accept your request")
        #expect(c("connection.asks_paused") == "Sam’s requests are paused")
        #expect(c("connection.authenticate.requested") == "Sam Lee asks you to confirm it is you")
        #expect(c("message.received") == "New message from Sam Lee" && c("call.missed") == "Missed call from Sam Lee")
        #expect(c("message.attachment_failed") == "Photo to Sam Lee not delivered")
        #expect(c("message.attachment_refused") == "Photo from Sam Lee refused: your vault is full")
        // A request's sender before it is a connection; a connection without names; one removed; none at all.
        #expect(title(Self.item("connection.request", "p1")) == "Ada Lovelace wants to connect")
        #expect(title(Self.item("message.received", connection: "c2")) == "New message from A connection")
        #expect(title(Self.item("message.received", connection: "gone")) == "New message from Removed connection")
        #expect(title(Self.item("connection.request", "unknown")) == "Someone wants to connect")
    }

    @Test func asksNameTheirItemWithDetailsOnly() {
        #expect(title(Self.item("grant.request", "g1", connection: "c1")) == "Sam asks for GitHub token")
        #expect(line(Self.item("grant.request", "g1", connection: "c1")) == "GitHub token")
        #expect(title(Self.item("grant.request", "g1", connection: "c1"), details: false) == "Sam asks for an item")
        #expect(title(Self.item("grant.request", "g1", connection: "c1", count: 3)) == "Sam asks for 3 things")
        #expect(line(Self.item("grant.request", "g1", connection: "c1", count: 3)) == "3 things")
        #expect(title(Self.item("grant.shared", connection: "c1")) == "Sam shared an item with you")
        #expect(title(Self.item("grant.revoked", connection: "c1")) == "Sam stopped sharing an item")
        #expect(title(Self.item("share.pending", "r1", connection: "c1")) == "A share rule for Sam needs a decision")
        #expect(title(Self.item("share.rate_limited", "r1", connection: "c1")) == "Sam reached the limit of a share rule")
        #expect(title(Self.item("critical-secret.use.request", "k1", connection: "c1")) == "Sam asks to use Signing key")
        #expect(title(Self.item("critical-secret.use.request", "k1", connection: "c1"), details: false) == "Sam asks to use a critical item")
        #expect(title(Self.item("item.revealed", "01ITEM")) == "GitHub token was revealed")
        #expect(title(Self.item("item.revealed", "01GONE")) == "Deleted item was revealed")
        #expect(title(Self.item("item.revealed", "01ITEM"), details: false) == "A critical item was revealed")
    }

    @Test func devicesCredentialAndTheDailyCheck() {
        let t = { (k: String, ref: String?) in title(Self.item(k, ref)) }
        #expect(t("device.pair.pending", nil) == "A device asks to pair" && t("device.paired", nil) == "A device was paired")
        #expect(t("device.unlinked", nil) == "A device was removed" && t("device.transferred", nil) == "Your vault moved to this phone")
        #expect(t("device.replaced", nil) == "Your vault moved to a new phone")
        #expect(t("device.signer_changed", nil) == "Your vault moved to another version of VettID")
        #expect(line(Self.item("device.signer_changed", "google_play:vettid")) == "From Google Play (signed by Google) to F-Droid or direct (signed by VettID)")
        #expect(line(Self.item("device.signer_changed", "development:ios")) == "From a development build to another signer")
        #expect(line(Self.item("device.signer_changed", "x")) == nil)
        #expect(t("device.session.pending", "s1") == "A device asks for access" && t("approval.pending", "a1") == "A device asks to approve a request")
        #expect(t("credential.alarm", nil) == "Your credential was used somewhere else")
        #expect(t("credential.password_failed", nil) == "Wrong credential password entered")
        #expect(t("credential.rotated", nil) == "Your credential was renewed" && t("credential.reset", nil) == "Your credential was reset")
        #expect(t("owner_check.failed", "pin") == "A daily check failed: wrong PIN")
        #expect(t("owner_check.failed", "password") == "A daily check failed: wrong password")
        #expect(t("owner_check.failed", nil) == "A daily check failed" && t("owner_check.locked", nil) == "Your vault locked after 10 failed checks")
        #expect(t("owner_check.hold_changed", "on") == "Hold turned on" && t("owner_check.hold_changed", "off") == "Hold turned off")
        #expect(t("owner_check.hold_changed", "on:expired") == "Hold back on" && t("owner_check.hold_changed", "off_until:x") == "Hold turned off")
        #expect(t("owner_check.hold_changed", "off_until:2026-11-01T00:00:00.000Z").hasPrefix("Hold turned off until "))
    }

    @Test func laterKindsGuidesAndUnknownKinds() {
        let t = { (k: String) in title(Self.item(k, connection: "c1")) }
        #expect(t("leash.rate_limited") == "An agent reached its limit" && t("leash.item.read") == "An agent read an item")
        #expect(t("leash.agent.suspended") == "An agent was suspended" && t("leash.referrals_limited") == "An agent’s referrals were limited")
        #expect(t("leash.future") == "Agent activity")
        #expect(t("action.request") == "Sam asks you to run an action" && t("intro.request") == "Sam wants to introduce someone")
        #expect(t("location.shared") == "Sam shared a location" && t("location.request") == "Sam asks for your location")
        #expect(t("wallet.signed") == "A wallet transaction was signed")
        #expect(t("guide") == "A tip from VettID")
        var guide = Self.item("guide")
        guide.title = "Welcome"
        guide.body = "First line\nSecond line"
        #expect(title(guide) == "Welcome" && line(guide) == "First line")
        #expect(t("future.kind") == "Activity: future.kind" && FeedKinds.classify("future.kind") == .unknown && !FeedKinds.isKnown("future.kind"))
    }
}

// swiftlint:enable line_length
