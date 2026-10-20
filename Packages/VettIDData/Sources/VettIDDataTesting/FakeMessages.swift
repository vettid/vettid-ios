import Foundation
import Observation
import VettIDData

/// TEST ONLY. In-memory messages for view-model tests, like ``FakeConnections``: every call is recorded in ``calls``;
/// ``fail`` makes the next call of a name throw. Observable, as ``MessagesManager`` is. The conversations are those of
/// ``connections`` (active ones, newest first). Mirrors the message part of vettid-android `FakeSocial`.
@MainActor
@Observable
public final class FakeMessages: MessagesRepository {
    /// Every call, by name and connection, in order.
    public var calls: [String] = []
    /// A failure the next call of that name throws (once).
    public var fail: [String: VaultFailure] = [:]
    public var connections: [ConnectionInfo] = []
    /// The messages by connection, oldest first.
    public var byConnection: [String: [MessageInfo]] = [:]
    /// Older pages ``loadOlder(_:)`` puts before the loaded messages, one per call, by connection.
    public var olderPages: [String: [[MessageInfo]]] = [:]
    private var sent = 0

    public init() {}

    private func call(_ name: String, _ id: String) throws {
        calls.append("\(name):\(id)")
        if let f = fail.removeValue(forKey: name) { throw f }
    }

    public var conversations: [ConversationSummary] {
        connections.filter { $0.state == .active }
            .map { c in
                let list = messages(c.id)
                return ConversationSummary(connection: c, last: list.last, unread: list.count { !$0.outgoing && !$0.read })
            }
            .sorted { ($0.last?.sentAt ?? .distantPast) > ($1.last?.sentAt ?? .distantPast) }
    }

    public func messages(_ connectionID: String) -> [MessageInfo] { byConnection[connectionID] ?? [] }

    public func olderAvailable(_ connectionID: String) -> Bool { !(olderPages[connectionID] ?? []).isEmpty }

    public func refreshConversations() async throws { try call("refreshConversations", "") }

    public func load(_ connectionID: String) async throws { try call("load", connectionID) }

    public func loadOlder(_ connectionID: String) async throws {
        try call("loadOlder", connectionID)
        guard var pages = olderPages[connectionID], !pages.isEmpty else { return }
        byConnection[connectionID] = pages.removeLast() + messages(connectionID)
        olderPages[connectionID] = pages
    }

    /// Refuses what ``MessageLimits`` refuses, before recording a send.
    public func send(_ connectionID: String, text: String) async throws -> MessageInfo {
        guard MessageLimits.fits(text) else { throw VaultFailure(.limit) }
        try call("send", connectionID)
        sent += 1
        let m = MessageInfo(
            connectionID: connectionID, messageID: String(format: "01JSENT%019d", sent), outgoing: true, text: text, sentAt: Date()
        )
        byConnection[connectionID, default: []].append(m)
        return m
    }

    public func markRead(_ connectionID: String) async throws {
        try call("markRead", connectionID)
        byConnection[connectionID] = messages(connectionID).map { m in
            var r = m
            if !m.outgoing { r.read = true }
            return r
        }
    }

    public func delete(_ connectionID: String, messageID: String) async throws {
        try call("delete", connectionID)
        byConnection[connectionID]?.removeAll { $0.messageID == messageID }
    }
}
