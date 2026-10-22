import Foundation
import Observation
import VettIDData

/// Asking a connection for "your <category>" (§10.12 `grant.request`, a category entry they answer). Mirrors vettid-android
/// `GrantAskForm`.
public struct GrantAskForm: Equatable, Sendable {
    public var category = "other"
    public var label = ""
    public var reason = ""
    public var busy = false

    public init(category: String = "other", label: String = "", reason: String = "", busy: Bool = false) {
        self.category = category
        self.label = label
        self.reason = reason
        self.busy = busy
    }
}

/// What a connection shares with the member. Fetched contents are the connection's data: never printed or reflected. Mirrors
/// vettid-android `SharedWithYouUiState`.
public struct SharedWithYouState: Equatable, Sendable, Failing, CustomStringConvertible, CustomReflectable {
    public let connectionID: String
    public var connectionName: String?
    public var received: [GrantView] = []
    /// Fetched contents by grant id, in memory while the screen is in front.
    public var opened: [String: SharedContent] = [:]
    /// The connection's vault refused a fetch, by grant id (`revoked`, `expired`, `exhausted`, `unavailable`, `rate_limited`).
    public var refused: [String: String] = [:]
    /// A `rate_limited` refusal's end (0.23.0 §10.12 `retry_after`), by grant id: "Try again in …".
    public var retryAt: [String: Date] = [:]
    public var fetching: String?
    public var loading = true
    public var error: FailureKind?
    /// The code an unmapped refusal names (shown with ``error``), or nil.
    public var errorCode: String?
    /// The limit a `limit` error named (VAULT-MESSAGING 0.21.0 §10.1).
    public var limit: VaultLimit?
    public var confirmGiveUp: GrantView?
    /// Requests this vault made of the connection (§10.12 `grant.list` `requested`).
    public var requested: [GrantAsk] = []
    /// The "ask for something" form, while open.
    public var ask: GrantAskForm?
    public var asked = false

    public init(connectionID: String, connectionName: String? = nil) {
        self.connectionID = connectionID
        self.connectionName = connectionName
    }

    public var description: String { "SharedWithYouState(\(connectionID), opened: \(opened.count))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What a connection shares with the member (§10.12 received grants): read-only and labelled as theirs. A value is fetched on
/// purpose (each fetch can count one of the connection's uses), sealed to this phone for that fetch only, and kept only while
/// the screen is in front (``hide()``, and when the model goes). Mirrors vettid-android `SharedWithYouViewModel`.
@MainActor
@Observable
public final class SharedWithYouViewModel {
    public private(set) var state: SharedWithYouState

    @ObservationIgnored private let sharing: any SharingRepository
    @ObservationIgnored private let items: any ItemsRepository
    @ObservationIgnored private let follows = TaskBag()
    /// Counts the times the vault's items were cleared: an answer that started before one is not kept.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored let work = Work()

    /// [ask]: opens the "ask for something" form at once (the connection's screen "Ask for something"). [now]: the clock for a
    /// refusal's `retry_after`.
    public init(
        connectionID: String, ask: Bool = false, sharing: any SharingRepository, items: any ItemsRepository,
        connections: any ConnectionsRepository, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sharing = sharing
        self.items = items
        self.now = now
        state = SharedWithYouState(connectionID: connectionID, connectionName: connectionName(connections, connectionID))
        load()
        if ask { openAsk(true) }
        // The vault locked, was held or is due, or this phone was wiped: nothing fetched is kept, nor a form being typed.
        let at = items.cleared
        follows.add(follow(self, read: { $0.items.cleared }, apply: { m, c in if c != at { m.dropValues() } }))
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    private func dropValues() {
        epoch += 1
        state.opened = [:]
        state.refused = [:]
        state.retryAt = [:]
        state.ask = nil
        state.asked = false
        state.confirmGiveUp = nil
        state.fetching = nil
    }

    public func load() {
        state.loading = true
        state.error = nil
        let id = state.connectionID
        work.launch { [weak self, sharing] in
            do {
                let g = try await sharing.grants()
                guard let self else { return }
                state.received = grantOrder(g.received.filter { $0.connectionID == id })
                state.requested = g.requested.filter { $0.connectionID == id }
                state.loading = false
            } catch {
                guard let self else { return }
                state.loading = false
                state.fail(error)
            }
        }
    }

    public func fetch(_ grantID: String) {
        if state.fetching != nil { return }
        state.fetching = grantID
        state.error = nil
        let at = epoch
        work.launch { [weak self, sharing] in
            do {
                let o = try await sharing.fetchShared(grantID)
                guard let self, epoch == at else { return }
                switch o {
                case .shared(let content):
                    state.opened[grantID] = content
                    state.refused[grantID] = nil
                    state.retryAt[grantID] = nil
                case .refused(let why, let retryAfter):
                    state.refused[grantID] = why
                    state.retryAt[grantID] = retryAfter.map { now().addingTimeInterval(TimeInterval($0)) }
                }
                state.fetching = nil
            } catch {
                guard let self, epoch == at else { return }
                state.fetching = nil
                state.fail(error)
            }
        }
    }

    public func openAsk(_ show: Bool) {
        state.ask = show ? GrantAskForm() : nil
        state.asked = false
    }

    public func setAsk(_ f: GrantAskForm) { state.ask = f }

    public func sendAsk() {
        guard let form = state.ask, !form.busy else { return }
        let id = state.connectionID
        state.ask?.busy = true
        state.error = nil
        work.launch { [weak self, sharing] in
            do {
                _ = try await sharing.requestGrant(connectionID: id, category: form.category, label: form.label, reason: form.reason)
                self?.state.ask = nil
                self?.state.asked = true
                self?.load()
            } catch {
                guard let self else { return }
                state.ask = form
                state.fail(error)
            }
        }
    }

    /// Drops the fetched values (the screen stopped, or went away).
    public func hide() { state.opened = [:] }

    public func askGiveUp(_ g: GrantView?) { state.confirmGiveUp = g }

    public func giveUp() {
        guard let g = state.confirmGiveUp else { return }
        state.confirmGiveUp = nil
        work.launch { [weak self, sharing] in
            do {
                try await sharing.revokeGrant(g.grantID)
                self?.state.opened[g.grantID] = nil
                self?.load()
            } catch {
                self?.state.fail(error)
            }
        }
    }

    public func dismissError() { state.error = nil }

    /// TEST ONLY: waits until the screen's work is done.
    func settle() async { await work.settle() }
}
