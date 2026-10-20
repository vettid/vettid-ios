import Foundation
import Observation
import VettIDData

/// A link the member tapped in a message, waiting for "Open link to <host>?" (VAULT-MESSAGING §10.5 "Links", IOS-PLAN
/// §6.8): the URL ``MessageLinks`` made of it and the host, in its ASCII form, that the question names.
public struct LinkPrompt: Equatable, Sendable {
    public let url: URL
    public let host: String

    public init(url: URL, host: String) {
        self.url = url
        self.host = host
    }
}

/// A conversation's state. Names, drafts and message text are the members' own: never printed, dumped or mirrored.
/// Mirrors vettid-android `ConversationUiState` without its photos (IOS-PLAN §8 I2.4).
public struct ConversationState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let connectionID: String
    public var connection: ConnectionInfo?
    /// Oldest first (the vault's order).
    public var messages: [MessageInfo] = []
    public var loading = true
    /// What the member is writing; kept while the conversation is open (and under the screens opened over it), in memory
    /// only, as vettid-android keeps it in its view model.
    public var draft = ""
    public var sending = false
    /// The draft is over 16 KiB in UTF-8 (VAULT-MESSAGING §10.5).
    public var tooLong = false
    /// The message the member asked to delete: confirmed first.
    public var deleting: MessageInfo?
    public var error: FailureKind?
    /// Older messages remain in the vault (§10.5.2): reaching the top loads them.
    public var olderAvailable = false
    public var loadingOlder = false
    /// A tapped link waiting for the member's answer.
    public var link: LinkPrompt?

    public init(connectionID: String) { self.connectionID = connectionID }

    public var active: Bool { connection?.state == .active }

    public var canSend: Bool {
        active && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending && !tooLong
    }

    public var description: String {
        "ConversationState(loading: \(loading), messages: \(messages.count), sending: \(sending), tooLong: \(tooLong), "
            + "olderAvailable: \(olderAvailable), error: \(error.map { "\($0)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A conversation (ANDROID-PLAN §4): the messages with one connection, oldest first; incoming messages are marked read
/// while it is open (the vault sends the read receipts, VAULT-MESSAGING §10.5); older pages on reaching the top
/// (§10.5.2); send, and delete a message on this vault only; a tapped link opens only after the member confirms its host
/// (§10.5 "Links"). Mirrors vettid-android `ConversationViewModel` without its photos (IOS-PLAN §8 I2.4).
@MainActor
@Observable
public final class ConversationViewModel {
    public let connectionID: String
    @ObservationIgnored private let messages: any MessagesRepository
    @ObservationIgnored private let connections: any ConnectionsRepository
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    private var local: ConversationState

    public init(connectionID: String, messages: any MessagesRepository, connections: any ConnectionsRepository) {
        self.connectionID = connectionID
        self.messages = messages
        self.connections = connections
        local = ConversationState(connectionID: connectionID)
        load()
        // Read while open: every new incoming message is marked read (best effort; a failure is left for the next arrival
        // or the next visit).
        follows.add(follow(self, read: { $0.unreadIDs }, apply: { $0.onUnread($1) }))
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    public var state: ConversationState {
        var s = local
        s.messages = messages.messages(connectionID)
        s.connection = connections.connections.first { $0.id == connectionID } ?? local.connection
        s.olderAvailable = messages.olderAvailable(connectionID)
        return s
    }

    /// The incoming messages not read yet.
    private var unreadIDs: [String] { messages.messages(connectionID).filter { !$0.outgoing && !$0.read }.map(\.messageID) }

    private func onUnread(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let (messages, id) = (messages, connectionID)
        work.launch { try? await messages.markRead(id) }
    }

    private func load() {
        let (messages, connections, id) = (messages, connections, connectionID)
        work.launch { [weak self] in
            do {
                if !connections.connections.contains(where: { $0.id == id }) {
                    let c = try await connections.connection(id)
                    self?.local.connection = c
                }
                try await messages.load(id)
                self?.local.loading = false
            } catch {
                self?.local.loading = false
                self?.local.error = failureKind(error)
            }
        }
    }

    public func setDraft(_ v: String) {
        local.draft = v
        local.tooLong = v.utf8.count > MessageLimits.maxTextBytes
    }

    /// Sends the draft, trimmed; on success it is cleared, on a failure it stays for another try.
    public func send() {
        var s = local
        s.connection = state.connection
        guard s.canSend else { return }
        let text = s.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        local.sending = true
        local.error = nil
        let (messages, id) = (messages, connectionID)
        work.launch { [weak self] in
            do {
                try await messages.send(id, text: text)
                self?.local.sending = false
                self?.local.draft = ""
                self?.local.tooLong = false
            } catch {
                self?.local.sending = false
                self?.local.error = failureKind(error)
            }
        }
    }

    /// The member reached the top: the next older page (§10.5.2), one at a time. A failure (`response_too_large` among
    /// them) is shown; the list keeps what it has and the next reach of the top tries again.
    public func loadOlder() {
        guard !local.loadingOlder, messages.olderAvailable(connectionID) else { return }
        local.loadingOlder = true
        let (messages, id) = (messages, connectionID)
        work.launch { [weak self] in
            do {
                try await messages.loadOlder(id)
                self?.local.loadingOlder = false
            } catch {
                self?.local.loadingOlder = false
                self?.local.error = failureKind(error)
            }
        }
    }

    /// Asks to delete [m] (nil: never mind).
    public func askDelete(_ m: MessageInfo?) { local.deleting = m }

    public func confirmDelete() {
        guard let m = local.deleting else { return }
        local.deleting = nil
        let (messages, id) = (messages, connectionID)
        work.launch { [weak self] in
            do {
                try await messages.delete(id, messageID: m.messageID)
            } catch {
                self?.local.error = failureKind(error)
            }
        }
    }

    public func dismissError() { local.error = nil }

    /// A link tapped in a bubble: asked about, by its host, if the link rule makes it tappable; anything else is ignored.
    public func askOpen(_ url: URL) {
        guard let l = MessageLinks.link(url.absoluteString) else { return }
        local.link = LinkPrompt(url: l.url, host: l.host)
    }

    /// The member confirmed: the URL to hand to the system, checked once more against the link rule; nil when it fails.
    public func confirmLink() -> URL? {
        guard let p = local.link else { return nil }
        local.link = nil
        return MessageLinks.link(p.url.absoluteString)?.url
    }

    public func dismissLink() { local.link = nil }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
