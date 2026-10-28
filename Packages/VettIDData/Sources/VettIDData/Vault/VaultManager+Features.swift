import Foundation
import VettIDVault

// The managers of the features over this manager's session: the shared profile and the name change (VAULT-MESSAGING
// §10.8), the connections (§6.4, §10.4) and the messages (§10.5).
extension VaultManager {
    /// The shared profile and the name change over this manager's session: the request kept with the account record it
    /// was sent for, the checks left read again after a wrong PIN or password. The profile's calls have the connections'
    /// session rules: nothing goes to a vault whose lock is pending, and a read nobody asked for never opens a session.
    static func profiles(_ ref: ManagerRef, checks: OwnerCheckManager, record rec: AccountRecord) -> ProfileManager {
        ProfileManager(
            ops: {
                guard let m = ref.manager else { throw VaultFailure(.other, code: "session_dropped") }
                return VaultProfileOps(api: try m.openApi(try await m.openSession()), gate: Self.pinGate(ref))
            },
            profileOps: { VaultProfileOps(api: try await memberApi(ref)) },
            quietOps: { VaultProfileOps(api: try quietApi(ref)) },
            // Memory only, like the snapshot (``OwnAccount``): dropped when the vault closed while the request was on its way.
            onRequest: { r, since in ref.manager?.keepNameRequest(r, since: since) },
            checksLeft: {
                try? await checks.refreshOwnerCheck()
                return checks.ownerCheck?.checksLeft
            },
            mark: { ref.manager?.ownAccount.mark() ?? 0 },
            open: { ref.manager?.ownProfileOpen ?? false },
            notes: Self.failureNotes(ref)
        )
    }

    /// Whether this phone may hold a vault, even a provisional one: paired, a vault pinned by `vault.enrolled`, or an
    /// enrollment request whose outcome is not known (a lost answer, a crash mid-request) started less than
    /// ``unknownEnrollmentKept`` ago. Its keys are then never forgotten by a start-over (chosen; not in the spec:
    /// vettid-android forgets an unpaired device's).
    func mayHoldVault(_ d: VaultDevice?) -> Bool { startOverRefusal(d) != nil }

    /// The files earlier builds wrote and this one no longer does (``VaultFiles/retired``), with the temporary files an
    /// interrupted write of them left, are deleted, once per process once it succeeds (IOS-PLAN §6.9): a file already gone
    /// is not an error, and one that could not be deleted is tried again at the next call, and at every start until it is
    /// gone. Nothing of them is read.
    func removeRetiredFiles() {
        guard !retiredRemoved else { return }
        var left = false
        for name in VaultFiles.retired {
            do { try config.file(name).clearRetired() } catch { left = true }
        }
        retiredRemoved = !left
    }

    /// The connections over this manager's session, in memory only (nothing of them is written to the phone).
    static func connectionsManager(_ config: VaultManagerConfig, _ ref: ManagerRef) -> ConnectionsManager {
        ConnectionsManager(
            // Nothing goes to a vault whose lock is pending, and no session is opened for it.
            ops: {
                guard let m = ref.manager else { throw VaultFailure(.other, code: "session_dropped") }
                guard m.lockGuard.admits() else { throw VaultFailure(.other, code: Self.codeLockPending) }
                return try m.openApi(try await m.openSession())
            },
            // A read nobody asked for goes only over the session open now, while the vault is open and collecting: it
            // never opens one (in the background, after a lock).
            quietOps: {
                guard let m = ref.manager, m.phase == .unlocked, !m.backgrounded, let s = m.session else {
                    throw VaultFailure(.other, code: "session_dropped")
                }
                return try m.openApi(s)
            },
            now: config.now
        )
    }

    /// The messages over this manager's session, with the same session rules as the connections (``connectionsManager``):
    /// nothing goes to a vault whose lock is pending, and a read nobody asked for never opens a session. Nothing of them
    /// is written to the phone.
    static func messagesManager(_ ref: ManagerRef, _ connections: ConnectionsManager) -> MessagesManager {
        let messages = MessagesManager(
            ops: {
                guard let m = ref.manager else { throw VaultFailure(.other, code: "session_dropped") }
                guard m.lockGuard.admits() else { throw VaultFailure(.other, code: Self.codeLockPending) }
                return try m.openApi(try await m.openSession())
            },
            quietOps: {
                guard let m = ref.manager, m.phase == .unlocked, !m.backgrounded, let s = m.session else {
                    throw VaultFailure(.other, code: "session_dropped")
                }
                return try m.openApi(s)
            },
            connections: { [weak connections] in connections?.connections ?? [] },
            refreshConnections: { [weak connections] in try await connections?.refresh() }
        )
        connections.onForget = { [weak messages] id in messages?.forgetConversation(id) }
        return messages
    }

    /// The messages and their photos: photo attachments over this manager's session with the messages' session rules, the
    /// probe (once after each unlock) only over the session already open; a sent photo's message joins its conversation.
    static func messageManagers(_ ref: ManagerRef, _ connections: ConnectionsManager) -> (MessagesManager, AttachmentManager) {
        let messages = messagesManager(ref, connections)
        let attachments = AttachmentManager(
            ops: { try await memberApi(ref) },
            quietOps: { try quietApi(ref) },
            onSent: { [weak messages] m in messages?.addSent(m) }
        )
        return (messages, attachments)
    }

    /// The vault is no longer open on this phone: what was read from it is dropped (the connections, the requests, the
    /// messages and their photos, the items and tags, the feed, the approvals' lists, History and the member's own profile).
    func forgetOpenLists() {
        forgetOwnProfile()
        forgetHeld()
    }

    /// The vault opened, or an owner check passed (§3.6.3: nothing held back is replayed as events): the member's own
    /// profile, the connections and the requests, the approvals' lists, the feed, then the conversations (one request per connection, last, so that asks
    /// that expire are not kept waiting behind them) and the items are read again, one after the other; failures are left
    /// for the screens.
    func refreshListsQuietly() {
        listsReads += 1
        listsRead = Task { [weak self] in
            guard let self else { return }
            profiles.refreshQuietly()
            try? await connections.refresh(quietly: true)
            try? await connections.refreshRequests(quietly: true)
            try? await approvals.refreshApprovals(quietly: true, requests: false)
            await feed.openNow()
            await messages.refreshConversationsQuietly()
            // The items last (chosen; not in the spec: vettid-android reads them beside the others): nothing that expires
            // waits behind them, and no screen needs them before the member opens the Vault.
            try? await items.refresh(quietly: true)
        }
    }
}

/// The vault manager, for what it makes before it is fully initialised (the owner check's operations).
@MainActor
final class ManagerRef {
    weak var manager: VaultManager?
}
