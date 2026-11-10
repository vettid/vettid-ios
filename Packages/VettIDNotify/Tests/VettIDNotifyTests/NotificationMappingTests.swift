import Foundation
import Testing
import VettIDData
import VettIDVault
@testable import VettIDNotify

/// Which feed items notify, in which category (ANDROID-PLAN §4 Notification modes 7 and 11). Mirrors vettid-android
/// `NotificationMappingTest`.
@Suite struct NotificationMappingTests {
    private func item(_ kind: String, priority: String = "normal", ref: String? = nil) -> FeedItem {
        FeedItem(itemID: "i", seq: 1, kind: kind, at: "2026-10-09T12:00:00Z", status: "active", priority: priority, ref: ref)
    }

    private let expected: [NotifyCategory: [String]] = [
        .messages: ["message.received", "message.attachment_failed", "message.attachment_refused"],
        .requests: [
            "connection.request", "connection.authenticate.requested", "grant.request", "share.pending", "critical-secret.use.request",
            "device.pair.pending", "device.session.pending", "approval.pending", "action.request", "intro.request", "location.request",
        ],
        .missedCalls: ["call.missed"],
        .security: [
            "credential.alarm", "owner_check.locked", "owner_check.failed", "owner_check.hold_changed", "credential.password_failed",
            "credential.reset", "device.replaced", "device.transferred", "device.signer_changed",
            "recovery.change_required", "recovery.counter_unavailable", "recovery.generation_closed",
        ],
        .activity: [
            "connection.added", "connection.request.peer_declined", "connection.asks_paused", "connection.stale", "connection.removed",
            "grant.shared", "grant.revoked", "share.rate_limited", "item.revealed", "device.paired", "device.unlinked",
            "credential.rotated",
            "leash.rate_limited", "leash.item.read", "leash.agent.suspended", "leash.referrals_limited", "location.shared",
            "wallet.signed",
            "device.secret_renewed", "recovery.completed", "recovery.attempt",
            "identity.rotation_failed", "identity.rotate_conflict", "leash.item.run", "leash.item.proxy",
            // ANDROID-PLAN 0.1.102 "Votes": "The channel is Vault activity; no new channel."
            "vote.open", "vote.closing", "vote.result", "vote.problem",
            // VAULT-MESSAGING 0.87.0 §6.3.1 "An app from before release 29": its "Vault activity" category, at `high`.
            "device.update_needed",
        ],
    ]

    @Test func everyKindOfTheSpecHasItsCategory() {
        let mapped = Set(expected.values.flatMap { $0 })
        #expect(mapped == FeedKinds.known.subtracting(["guide"]).subtracting(FeedKinds.historyOnly))
        for (category, kinds) in expected {
            for k in kinds { #expect(NotificationMapping.category(item(k)) == category, "\(k)") }
        }
    }

    @Test func anotherDeviceNeedingAnUpdateNotifiesAsVaultActivity() {
        #expect(NotificationMapping.category(item("device.update_needed", priority: "high")) == .activity)
    }

    @Test func theHistoryOnlyKindsNeverNotify() {
        for k in ["credential.recovered", "recovery.device_paired", "vault.pin_changed"] {
            #expect(NotificationMapping.category(item(k)) == nil)
            #expect(NotificationMapping.category(item(k, priority: "urgent")) == nil)
        }
        #expect(NotificationMapping.category(item("recovery.completed")) == .activity)
    }

    @Test func aFailedRecoveryAttemptNotifiesOnSecurity() {
        #expect(NotificationMapping.category(item("recovery.attempt", priority: "urgent", ref: "2/3/not_success/counter")) == .security)
        #expect(NotificationMapping.category(item("recovery.attempt", priority: "urgent", ref: "garbled")) == .security)
        #expect(NotificationMapping.category(item("recovery.attempt", priority: "urgent")) == .security)
        #expect(NotificationMapping.category(item("recovery.attempt", priority: "urgent", ref: "2/4/success/counter")) == .activity)
        #expect(NotificationMapping.category(item("recovery.attempt", ref: "2/3/not_success/counter")) == .activity)
        #expect(NotificationMapping.category(item("recovery.attempt")) == .activity)
        for ref in ["password", "3"] {
            #expect(NotificationMapping.category(item("recovery.change_required", priority: "high", ref: ref)) == .security)
        }
        #expect(NotificationMapping.category(item("recovery.counter_unavailable", priority: "urgent")) == .security)
        #expect(NotificationMapping.category(item("identity.rotation_failed", priority: "high")) == .activity)
        #expect(NotificationMapping.category(item("recovery.generation_closed", priority: "urgent", ref: "4/rollback")) == .security)
    }

    @Test func lowPriorityAndGuidesNeverNotifyAndUnknownKindsAreActivity() {
        #expect(NotificationMapping.category(item("guide")) == nil)
        #expect(NotificationMapping.category(item("message.received", priority: "low")) == nil)
        #expect(NotificationMapping.category(item("vault.something_new")) == .activity)
        #expect(NotificationMapping.category(item("vault.something_new", priority: "low")) == nil)
        #expect(NotificationMapping.category(item("credential.alarm", priority: "urgent")) == .security)
    }

    /// IOS-PLAN §6.7: sounds and levels by category; Vault activity is silent and passive.
    @Test func soundsLevelsAndLockScreenTexts() {
        #expect(NotifyCategory.messages.sound == "vettid_message.caf" && NotifyCategory.missedCalls.sound == "vettid_message.caf")
        #expect(NotifyCategory.requests.sound == "vettid_urgent.caf" && NotifyCategory.security.sound == "vettid_urgent.caf")
        #expect(NotifyCategory.ownerCheck.sound == "vettid_urgent.caf" && NotifyCategory.activity.sound == nil)
        #expect(NotifyCategory.activity.level == .passive && NotifyCategory.security.level == .timeSensitive)
        #expect(NotifyCategory.messages.level == .active && NotifyCategory.requests.level == .active)
        #expect(NotifyCategory.security.publicTitle == "VettID needs your attention")
        #expect(NotifyCategory.ownerCheck.publicTitle == "VettID needs your attention")
        #expect(NotifyCategory.messages.publicTitle == "New activity in VettID")
        #expect(Set(NotifyCategory.allCases.map(\.identifier)).count == NotifyCategory.allCases.count)
    }

    @Test func requestsWhoseScreensComeLaterSayToOpenANewerVettID() {
        #expect(NotificationMapping.needsNewerApp(item("intro.request")))
        #expect(NotificationMapping.needsNewerApp(item("action.request")))
        #expect(!NotificationMapping.needsNewerApp(item("grant.request")))
        #expect(!NotificationMapping.needsNewerApp(item("location.shared")), "not a request")
    }
}
