import Foundation
import Observation
import VettIDVault

/// Messages with connections (VAULT-MESSAGING §10.5, §10.5.2), as ``Repositories.swift`` describes the repositories: a
/// `@MainActor` protocol whose state an `@Observable` type holds. Every failure is a ``VaultFailure``. Messages live in
/// memory only, read from the vault, which keeps them. Mirrors vettid-android `MessagesRepository`.
@MainActor
public protocol MessagesRepository: AnyObject, Observable, Sendable {
    /// One entry per active connection, with messages or not, newest conversation first.
    var conversations: [ConversationSummary] { get }

    /// The messages with one connection, oldest first (the vault's order), as loaded and as they arrive.
    func messages(_ connectionID: String) -> [MessageInfo]

    /// Whether older messages than those loaded remain in the vault (`next_before`, §10.5.2).
    func olderAvailable(_ connectionID: String) -> Bool

    /// Reloads every active connection's conversation (its newest page).
    func refreshConversations() async throws

    /// Reloads one conversation's newest page (§10.5.2), keeping older pages already loaded that it joins.
    func load(_ connectionID: String) async throws

    /// Loads the next older page of the conversation (the member scrolled to its top). A position the vault no longer
    /// holds starts again from the newest page.
    func loadOlder(_ connectionID: String) async throws

    /// Sends [text] (1 byte to 16 KiB in UTF-8; ``VaultFailure/kind`` `.limit` outside, before anything is sent).
    @discardableResult
    func send(_ connectionID: String, text: String) async throws -> MessageInfo

    /// Marks every unread incoming message of the conversation read (the vault sends read receipts).
    func markRead(_ connectionID: String) async throws

    /// Deletes a message on this vault only (the connection keeps its copy).
    func delete(_ connectionID: String, messageID: String) async throws
}

/// The limits of `message.send` (§10.5).
public enum MessageLimits {
    /// A message's text in UTF-8 bytes: 1 to 16 KiB.
    public static let maxTextBytes = 16 * 1_024

    /// Whether [text] can be sent as a message.
    public static func fits(_ text: String) -> Bool { (1...maxTextBytes).contains(text.utf8.count) }
}

/// The vault calls behind ``MessagesManager`` (§10.5, §10.5.2), one per type, as ``VaultApi`` has them; a test passes its
/// own. Errors are the vault client's (``VaultOpError`` with the spec's code), mapped by the manager.
public protocol MessageOps: Sendable {
    func messageSend(_ connectionID: String, text: String) async throws -> SentMessage
    func messagePage(_ connectionID: String, limit: Int?, before: String?) async throws -> MessagePage
    func messageRead(_ connectionID: String, messageID: String) async throws
    func messageDelete(_ connectionID: String, messageID: String) async throws
}

extension VaultApi: MessageOps {}
