import Foundation
import Observation
import VettIDData

/// The Messages screen's state. Names and message text are the members' own: never printed, dumped or mirrored. Mirrors
/// vettid-android `MessagesUiState`.
public struct MessagesState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var loading = true
    /// Newest conversation first; with the Unread chip only those with unread messages, while searching only matches.
    public var conversations: [ConversationSummary] = []
    public var unreadOnly = false
    /// No active connection at all: the empty state suggests an invitation and the add button invites.
    public var noConnections = true
    public var error: FailureKind?
    /// The top bar's search: connection names and the latest message, on this phone.
    public var query = ""
    /// Whether there is any conversation at all (the search is offered then).
    public var searchable = false

    public init() {}

    public var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var description: String {
        "MessagesState(loading: \(loading), conversations: \(conversations.count), unreadOnly: \(unreadOnly), "
            + "error: \(error.map { "\($0)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public extension ConversationSummary {
    /// Whether [query] is in the connection's title or display name, or in its latest message's text, ignoring case
    /// (vettid-android `matches`).
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        // Searched as cleaned, without the isolates (VAULT-MESSAGING 0.76.0 §10.8 step 7): names and the message text alike.
        let keys = [AccountNames.cleaned(connection.displayName), AccountNames.cleaned(connection.name), AccountNames.cleaned(last?.text)]
        return keys.compactMap { $0 }.contains { $0.range(of: q, options: .caseInsensitive) != nil }
    }
}

/// Messages (ANDROID-PLAN §4, Proton's inbox): one row per connection with its latest message, newest first; the Unread
/// chip and the search filter it. Mirrors vettid-android `MessagesViewModel`.
@MainActor
@Observable
public final class MessagesViewModel {
    @ObservationIgnored private let messages: any MessagesRepository
    @ObservationIgnored private let ownerChecks: (any OwnerCheckRepository)?
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    /// What the screen holds itself; the rows come from the repository (``state``).
    private var local = MessagesState()

    /// [ownerChecks]: a list refused because the daily check was due reads again by itself once a check passes, as
    /// vettid-android's.
    public init(messages: any MessagesRepository, ownerChecks: (any OwnerCheckRepository)? = nil) {
        self.messages = messages
        self.ownerChecks = ownerChecks
        refresh()
        if ownerChecks != nil {
            follows.add(follow(self, read: { $0.ownerChecks?.ownerCheck }, apply: { $0.onOwnerCheck($1) }))
        }
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    private func onOwnerCheck(_ v: OwnerCheckView?) {
        guard v?.state == .ok, local.error == .ownerCheckRequired else { return }
        refresh()
    }

    public var state: MessagesState {
        var s = local
        let all = messages.conversations
        s.conversations = all.filter { (!s.unreadOnly || $0.unread > 0) && $0.matches(s.query) }
        s.noConnections = !all.contains { $0.connection.state == .active }
        s.searchable = !all.isEmpty
        return s
    }

    public func refresh() {
        local.error = nil
        let messages = messages
        work.launch { [weak self] in
            do {
                try await messages.refreshConversations()
                self?.local.loading = false
            } catch {
                self?.local.loading = false
                self?.local.error = failureKind(error)
            }
        }
    }

    public func setUnreadOnly(_ on: Bool) { local.unreadOnly = on }

    public func setQuery(_ q: String) { local.query = q }

    public func dismissError() { local.error = nil }

    private static func sortKey(_ c: ConnectionInfo) -> String { (AccountNames.cleaned(c.displayName) ?? "").lowercased() }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}

/// The new-message picker's state. Mirrors vettid-android `NewMessageUiState`.
public struct NewMessageState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var loading = true
    /// The active connections, favourites first, then by name.
    public var connections: [ConnectionInfo] = []
    public var error: FailureKind?

    public init() {}

    public var description: String {
        "NewMessageState(loading: \(loading), connections: \(connections.count), error: \(error.map { "\($0)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The compose button: pick an active connection to write to. Mirrors vettid-android `NewMessageViewModel`.
@MainActor
@Observable
public final class NewMessageViewModel {
    @ObservationIgnored private let connections: any ConnectionsRepository
    @ObservationIgnored private let work = Work()
    private var local = NewMessageState()

    public init(connections: any ConnectionsRepository) {
        self.connections = connections
        let repo = connections
        work.launch { [weak self] in
            do {
                try await repo.refresh()
                self?.local.loading = false
            } catch {
                self?.local.loading = false
                self?.local.error = failureKind(error)
            }
        }
    }

    deinit { work.cancelAll() }

    public var state: NewMessageState {
        var s = local
        s.connections = Self.listed(connections.connections)
        return s
    }

    /// The active ones, favourites first, then by the title lower-cased (vettid-android's order; a stable sort).
    static func listed(_ all: [ConnectionInfo]) -> [ConnectionInfo] {
        all.filter { $0.state == .active }.enumerated().sorted { a, b in
            if a.element.favorite != b.element.favorite { return a.element.favorite }
            let (x, y) = (sortKey(a.element), sortKey(b.element))
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    private static func sortKey(_ c: ConnectionInfo) -> String { (AccountNames.cleaned(c.displayName) ?? "").lowercased() }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
