import Foundation
import Observation
import VettIDCrypto
import VettIDVault

/// Messages with connections on this device (VAULT-MESSAGING §10.5, §10.5.2; ANDROID-PLAN §4 Messages, Conversation),
/// over the vault client. The vault keeps the messages; the phone holds the pages it read and what its events brought in
/// memory only, and drops them when the vault is no longer open (as vettid-android: nothing of a message is written to
/// the phone). A conversation is in the vault's order (arrival), never sorted by `sent_at` (the sender's clock), and its
/// pages join by that order (``MessagePages``). Mirrors the message part of vettid-android `SocialManager`.
@MainActor
@Observable
public final class MessagesManager: MessagesRepository {
    /// The loaded messages by connection, oldest first.
    var byConnection: [String: [MessageInfo]] = [:]
    /// Per conversation, where its loaded history stands (§10.5.2); dropped with its messages.
    var paging: [String: MessagePaging] = [:]

    @ObservationIgnored let ops: @MainActor () async throws -> any MessageOps
    /// The calls of a read nobody asked for (at the opening, after an owner check): only over the session already open,
    /// never opening one.
    @ObservationIgnored let quietOps: @MainActor () async throws -> any MessageOps
    @ObservationIgnored private let connections: @MainActor () -> [ConnectionInfo]
    @ObservationIgnored private let refreshConnections: @MainActor () async throws -> Void
    @ObservationIgnored let now: @Sendable () -> Date
    /// Bumped whenever what was read from the open vault is dropped: an answer to a call made before is not taken in
    /// (chosen; not in the spec).
    @ObservationIgnored var generation = 0

    /// Messages asked for per `message.list` page (vettid-android's); the vault also stops at 131,072 bytes (§10.5.2).
    static let pageSize = 100
    static let codeTooLarge = "response_too_large"

    /// [ops] the vault's calls, opened when needed; [quietOps] those of the background reads (nil: [ops]); [connections]
    /// the connections as last read (the conversations are theirs) and [refreshConnections] reads them again.
    public init(
        ops: @escaping @MainActor () async throws -> any MessageOps,
        quietOps: (@MainActor () async throws -> any MessageOps)? = nil,
        connections: @escaping @MainActor () -> [ConnectionInfo],
        refreshConnections: @escaping @MainActor () async throws -> Void = {},
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ops = ops
        self.quietOps = quietOps ?? ops
        self.connections = connections
        self.refreshConnections = refreshConnections
        self.now = now
    }

    public var conversations: [ConversationSummary] { ConversationSummary.of(connections(), byConnection) }

    public func messages(_ connectionID: String) -> [MessageInfo] { byConnection[connectionID] ?? [] }

    public func olderAvailable(_ connectionID: String) -> Bool { paging[connectionID]?.hasOlder == true }

    // MARK: - Lifecycle

    /// The vault is no longer open on this phone (locked, or a lock was asked for): every message is dropped from memory;
    /// an unlock reads the conversations again.
    public func forgetOpenVault() {
        generation += 1
        byConnection = [:]
        paging = [:]
    }

    /// Forgets everything (a wipe, or a deleted vault). Nothing of the messages is on the phone, so it is the same.
    public func clear() { forgetOpenVault() }

    /// The connection is gone (removed, blocked, or removed by the peer): its conversation goes with it.
    public func forgetConversation(_ connectionID: String) {
        byConnection[connectionID] = nil
        paging[connectionID] = nil
    }

    /// The newest page of every active connection, read only over the session already open; failures are left for the
    /// screens to retry.
    func refreshConversationsQuietly() async {
        for c in connections() where c.state == .active {
            try? await load(c.id, quietly: true, fresh: false)
        }
    }

    /// Runs [body] and turns every failure into a ``VaultFailure`` (a cancellation stays one).
    private func guarded<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw VaultFailures.map(error)
        }
    }

    // MARK: - MessagesRepository

    public func refreshConversations() async throws {
        if connections().isEmpty { try await refreshConnections() }
        for c in connections() where c.state == .active {
            try await load(c.id, quietly: false, fresh: false)
        }
    }

    public func load(_ connectionID: String) async throws { try await load(connectionID, quietly: false, fresh: false) }

    /// The newest page (§10.5.2). Older pages the member already scrolled to stay when the new page joins them
    /// (``MessagePages/newest(_:nextBefore:current:paging:)``); [fresh] drops them first (a position the vault no longer
    /// holds).
    private func load(_ connectionID: String, quietly: Bool, fresh: Bool) async throws {
        let g = generation
        let page = try await guarded { try await pageFitting(quietly ? quietOps : ops, connectionID, before: nil) }
        guard g == generation else { return }
        let start = fresh ? MessagePaging() : paging[connectionID] ?? MessagePaging()
        let merged = MessagePages.newest(
            page.messages.map(MessageInfo.of), nextBefore: page.nextBefore, current: messages(connectionID), paging: start
        )
        byConnection[connectionID] = merged.messages
        paging[connectionID] = merged.paging
    }

    /// The next older page, before the oldest loaded one (§10.5.2). A position the vault no longer holds (`not_found`: the
    /// message was deleted meanwhile, on another device) starts again from the newest page.
    public func loadOlder(_ connectionID: String) async throws {
        guard let before = paging[connectionID]?.nextBefore else { return }
        let g = generation
        let page: MessagePage
        do {
            page = try await guarded { try await pageFitting(ops, connectionID, before: before) }
        } catch let f as VaultFailure where f.kind == .notFound {
            guard g == generation else { return }
            return try await load(connectionID, quietly: false, fresh: true)
        }
        // A reload may have replaced the position meanwhile: then this page is not the next one.
        guard g == generation, paging[connectionID]?.nextBefore == before else { return }
        let merged = MessagePages.older(page.messages.map(MessageInfo.of), nextBefore: page.nextBefore, current: messages(connectionID))
        byConnection[connectionID] = merged.messages
        paging[connectionID] = merged.paging
    }

    /// A page asked for with ``pageSize`` messages and, when the answer could not be sealed (`response_too_large`, §8.1),
    /// asked for again with half as many, down to one: a page of long messages still arrives (as vettid-android).
    private func pageFitting(
        _ opener: @MainActor () async throws -> any MessageOps, _ connectionID: String, before: String?
    ) async throws -> MessagePage {
        let o = try await opener()
        var limit = Self.pageSize
        while true {
            do {
                return try await o.messagePage(connectionID, limit: limit, before: before)
            } catch let e as VaultOpError where e.code == Self.codeTooLarge && limit > 1 {
                limit /= 2
            }
        }
    }

    public func send(_ connectionID: String, text: String) async throws -> MessageInfo {
        guard MessageLimits.fits(text) else { throw VaultFailure(.limit) }
        let g = generation
        let sent = try await guarded { try await ops().messageSend(connectionID, text: text) }
        let m = MessageInfo(
            connectionID: connectionID, messageID: sent.messageID, outgoing: true, text: text,
            sentAt: ConnectionParser.instant(sent.sentAt) ?? now()
        )
        // The vault tells only the owner's other devices (vettid-vault `send`: `NotifyDevices`): this one adds it here.
        if g == generation { upsert(m) }
        return m
    }

    /// One `message.read` per unread incoming message, in order. One the vault no longer holds (deleted on another device;
    /// `message.delete` sends no event) is dropped here and the others go on (chosen; not in the spec: vettid-android
    /// stops at it).
    public func markRead(_ connectionID: String) async throws {
        let unread = messages(connectionID).filter { !$0.outgoing && !$0.read }
        guard !unread.isEmpty else { return }
        let g = generation
        let o = try await guarded { try await ops() }
        for m in unread {
            do {
                try await guarded { try await o.messageRead(connectionID, messageID: m.messageID) }
                if g == generation { patch(connectionID, m.messageID) { $0.read = true } }
            } catch let f as VaultFailure where f.kind == .notFound {
                if g == generation { byConnection[connectionID]?.removeAll { $0.messageID == m.messageID } }
            }
        }
    }

    /// `message.delete`; a message the vault no longer holds is already deleted (chosen; not in the spec).
    public func delete(_ connectionID: String, messageID: String) async throws {
        let g = generation
        do {
            try await guarded { try await ops().messageDelete(connectionID, messageID: messageID) }
        } catch let f as VaultFailure where f.kind == .notFound {}
        if g == generation { byConnection[connectionID]?.removeAll { $0.messageID == messageID } }
    }

    // MARK: - Events

    /// One event of the vault (§9.1, §10.1, §10.5): `message.new`, and the receipts and reads of `sync.event`.
    public func onEvent(_ m: VaultMessage) {
        switch m.type {
        case "message.new":
            if let msg = Message.of(m.object) { upsert(.of(msg)) }
        case "sync.event":
            onSync(m.object)
        default:
            break
        }
    }

    /// `sync.event{message.receipt}` (the peer's vault stored or read an outgoing message) and `{message.read}` (another
    /// device of the owner read an incoming one). (`message.attachment` comes with the photos, IOS-PLAN §8 I2.4.)
    private func onSync(_ b: JsonObject) {
        guard let conn = VaultJSON.string(b, "connection_id"), let id = VaultJSON.string(b, "message_id") else { return }
        switch VaultJSON.string(b, "kind") {
        case "message.receipt":
            let read = VaultJSON.string(b, "receipt") == "read"
            patch(conn, id) { m in
                m.delivered = true
                m.read = m.read || read
            }
        case "message.read":
            patch(conn, id) { $0.read = true }
        default:
            break
        }
    }

    /// A message joins its conversation: a new one at the end, in the order it reached this phone (the vault's order),
    /// never by `sent_at`; one already there is replaced, keeping the receipts it had.
    func upsert(_ m: MessageInfo) {
        var list = messages(m.connectionID)
        if let i = list.firstIndex(where: { $0.messageID == m.messageID }) {
            var next = m
            next.delivered = m.delivered || list[i].delivered
            next.read = m.read || list[i].read
            list[i] = next
        } else {
            list.append(m)
        }
        byConnection[m.connectionID] = list
    }

    private func patch(_ conn: String, _ id: String, _ f: (inout MessageInfo) -> Void) {
        guard var list = byConnection[conn], let i = list.firstIndex(where: { $0.messageID == id }) else { return }
        f(&list[i])
        byConnection[conn] = list
    }
}
