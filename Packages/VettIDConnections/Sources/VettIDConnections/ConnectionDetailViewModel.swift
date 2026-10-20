import Foundation
import Observation
import VettIDData

/// What the detail screen asks the member to confirm first.
public enum DetailConfirm: Equatable, Sendable {
    case remove
}

/// A connection's detail screen state. Names are the members' own: never printed, dumped or mirrored. Mirrors
/// vettid-android `ConnectionDetailUiState` without what later rows bring: member authentication (IOS-PLAN §8 I2.3) and
/// sharing both ways (the items phase).
public struct ConnectionDetailState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var connectionID: String
    public var connection: ConnectionInfo?
    public var loading = true
    public var busy = false
    public var confirm: DetailConfirm?
    /// The connection is gone (removed here, or unknown to the vault): the screen closes.
    public var gone = false
    public var error: FailureKind?

    public init(connectionID: String) { self.connectionID = connectionID }

    public var description: String {
        "ConnectionDetailState(loaded: \(connection != nil), loading: \(loading), busy: \(busy), gone: \(gone), "
            + "error: \(error.map { "\($0)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What the connection page offers for a connection's asks (VAULT-MESSAGING 0.23.0 §10.4.1). Mirrors vettid-android
/// `AsksAction`.
public enum AsksAction: Equatable, Sendable {
    case mute
    case unmute
    /// `connection.asks.resume` while paused.
    case resume
    /// `connection.asks.resume` without a pause: clears the cooldowns of declined asks.
    case allowAgain
}

/// A connection's asks as the page shows them: muted, paused and the declined asks in cooldown, with the actions that end
/// each state. Unmuting does not resume a pause, and resuming does not unmute (§10.4.1), so both can be offered at once.
/// Nil for a vault before 0.23.0 (no `asks` on the connection): nothing is shown or offered. Mirrors vettid-android
/// `AsksView`.
public struct AsksView: Equatable, Sendable {
    public var muted: Bool
    public var paused: Bool
    public var pausedAt: Date?
    public var cooldowns: Int
    public var actions: [AsksAction]

    /// A state the member should see before the rest of the page.
    public var prominent: Bool { muted || paused }

    public static func of(_ a: AskState?) -> AsksView? {
        guard let a else { return nil }
        let resume: AsksAction? = a.paused ? .resume : (a.cooldowns > 0 ? .allowAgain : nil)
        return AsksView(
            muted: a.muted, paused: a.paused, pausedAt: a.pausedAt, cooldowns: a.cooldowns,
            actions: [resume, a.muted ? .unmute : .mute].compactMap { $0 }
        )
    }
}

public extension ConnectionInfo {
    /// The name the sharing and asks texts use: the first name on the peer's account, else its full name; nil before the
    /// names arrived (vettid-android `sharingName`).
    var sharingName: String? {
        if let f = firstName?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty { return f }
        guard let a = accountName, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return a
    }
}

/// A connection (ANDROID-PLAN §4): the profile it shares (self-asserted), its asks (mute, resume: VAULT-MESSAGING 0.23.0
/// §10.4.1), favourite and remove (confirmed). No safety code, alias, note or block here (as vettid-android, whose owner
/// decided so). Mirrors vettid-android `ConnectionDetailViewModel` without member authentication (IOS-PLAN §8 I2.3) and
/// sharing (the items phase).
@MainActor
@Observable
public final class ConnectionDetailViewModel {
    @ObservationIgnored private let connections: any ConnectionsRepository
    @ObservationIgnored private let work = Work()
    private var local: ConnectionDetailState

    public init(connectionID: String, connections: any ConnectionsRepository) {
        self.connections = connections
        local = ConnectionDetailState(connectionID: connectionID)
        work.launch { [weak self] in
            do {
                let c = try await connections.connection(connectionID)
                self?.local.loading = false
                self?.local.connection = c
            } catch {
                let kind = failureKind(error)
                self?.local.loading = false
                self?.local.error = kind
                self?.local.gone = kind == .notFound
            }
        }
    }

    deinit { work.cancelAll() }

    /// The connection as the list has it now (a change from another device shows at once), else as read.
    public var state: ConnectionDetailState {
        var s = local
        if let c = connections.connections.first(where: { $0.id == s.connectionID }) { s.connection = c }
        return s
    }

    private var id: String { local.connectionID }

    public func toggleFavorite() {
        guard let c = state.connection else { return }
        let (connections, id) = (connections, id)
        act { try await connections.setFavorite(id, favorite: !c.favorite) }
    }

    /// Mutes or unmutes this connection's asks (`connection.asks.mute`, 0.23.0 §10.4.1).
    public func muteAsks(_ muted: Bool) {
        let (connections, id) = (connections, id)
        act { try await connections.setAsksMuted(id, muted: muted) }
    }

    /// Resumes paused asks and clears the cooldowns of declined ones (`connection.asks.resume`, §10.4.1).
    public func resumeAsks() {
        let (connections, id) = (connections, id)
        act { try await connections.resumeAsks(id) }
    }

    /// Asks the member to confirm [confirm] (nil: never mind).
    public func ask(_ confirm: DetailConfirm?) { local.confirm = confirm }

    /// Removes the connection once confirmed (`connection.remove`, §10.4): the peer is told, the screen closes.
    public func confirm() {
        guard local.confirm == .remove else { return }
        local.confirm = nil
        let (connections, id) = (connections, id)
        act { [weak self] in
            try await connections.remove(id)
            self?.local.gone = true
        }
    }

    public func dismissNotice() { local.error = nil }

    private func act(_ body: @escaping @MainActor () async throws -> Void) {
        local.busy = true
        local.error = nil
        work.launch { [weak self] in
            do {
                try await body()
                self?.local.busy = false
            } catch {
                self?.local.busy = false
                self?.local.error = failureKind(error)
            }
        }
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
