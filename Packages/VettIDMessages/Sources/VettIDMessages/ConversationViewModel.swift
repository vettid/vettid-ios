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

    /// The longest URL the question shows whole.
    public static let shownLength = 300
    /// What is kept of a longer URL's start (at least up to the end of its host) and end.
    static let shownStart = 180
    static let shownEnd = 100

    /// The URL as the question shows it: whole up to ``shownLength`` characters, else its start through the host and
    /// its end around an ellipsis (chosen; not in the spec).
    public var shownURL: String {
        let s = url.absoluteString
        guard s.count > Self.shownLength else { return s }
        let afterScheme = s.index(s.startIndex, offsetBy: min(8, s.count))
        let hostEnd = s[afterScheme...].firstIndex { "/?#".contains($0) } ?? s.endIndex
        let start = max(s.distance(from: s.startIndex, to: hostEnd), Self.shownStart)
        guard start + Self.shownEnd < s.count else { return s }
        return String(s.prefix(start)) + "…" + String(s.suffix(Self.shownEnd))
    }
}

/// Where a confirmed link goes: VettID's own invitation links (an `https` URL whose path is `/connect`, the rule of an
/// opened link, VAULT-MESSAGING §6.4) to the app's accept screen, since iOS hands an app's own Universal Link back to
/// Safari when the app opens it; any other link to the system.
public enum LinkTarget: Equatable, Sendable {
    case open(URL)
    case invite(String)

    /// The longest invitation taken (as for an opened link).
    static let maxInviteLength = 4_096

    public static func of(_ url: URL) -> LinkTarget {
        let s = url.absoluteString
        if s.utf8.count <= maxInviteLength, InviteLinks.isConnectURL(s) { return .invite(s) }
        return .open(url)
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
    /// The conversation is on screen (not covered by a screen pushed over it) and the app in the foreground.
    @ObservationIgnored private var shown = false
    @ObservationIgnored private var foreground = true
    /// A `markRead` is under way; [markAgain]: unread messages changed meanwhile.
    @ObservationIgnored private var marking = false
    @ObservationIgnored private var markAgain = false
    private var local: ConversationState

    public init(connectionID: String, messages: any MessagesRepository, connections: any ConnectionsRepository) {
        self.connectionID = connectionID
        self.messages = messages
        self.connections = connections
        local = ConversationState(connectionID: connectionID)
        load()
        // Read while shown: every new incoming message is marked read (best effort; a failure is left for the next arrival
        // or the next showing).
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
        if marking {
            markAgain = true
        } else {
            markRead()
        }
    }

    /// The conversation came on screen or left it (a screen pushed over it, the screen closed). Incoming messages are
    /// marked read only while it is shown and the app is in the foreground (chosen; not in the spec: vettid-android marks
    /// them while its view model lives).
    public func setShown(_ on: Bool) {
        shown = on
        markRead()
    }

    /// The app came to the foreground or left it.
    public func setForeground(_ on: Bool) {
        foreground = on
        markRead()
    }

    /// Marks the unread incoming messages read, one call at a time (as vettid-android's collector): unread messages that
    /// arrive meanwhile are marked after it; a failure waits for the next arrival or showing.
    private func markRead() {
        guard shown, foreground, !marking, !unreadIDs.isEmpty else { return }
        marking = true
        markAgain = false
        let (messages, id) = (messages, connectionID)
        work.launch { [weak self] in
            try? await messages.markRead(id)
            guard let self else { return }
            marking = false
            if markAgain {
                markAgain = false
                markRead()
            }
        }
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

    /// The member confirmed: where the link goes, checked once more against the link rule; nil when it fails.
    public func confirmLink() -> LinkTarget? {
        guard let p = local.link else { return nil }
        local.link = nil
        return MessageLinks.link(p.url.absoluteString).map { LinkTarget.of($0.url) }
    }

    public func dismissLink() { local.link = nil }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
