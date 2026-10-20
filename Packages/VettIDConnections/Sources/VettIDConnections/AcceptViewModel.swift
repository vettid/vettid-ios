import Foundation
import Observation
import VettIDData

/// The steps of accepting an invitation (VAULT-MESSAGING §6.4, 0.10.3). Mirrors vettid-android `AcceptStep`.
public enum AcceptStep: Equatable, Sendable {
    /// Paste (or confirm an opened link).
    case input
    case accepting
    /// The vaults run the handshake; no safety code yet.
    case waiting
    /// The safety code is known: compare, then approve or decline.
    case compare
    /// This member approved; the inviter's approval is awaited.
    case approved
    case connected
    /// This vault is already connected to the inviter (or has asked to connect).
    case exists
    /// The request ended without a connection.
    case ended
}

/// The accept screen's state. The invitation's text lets whoever holds it ask to connect: never printed, dumped or
/// mirrored. Mirrors vettid-android `AcceptUiState`.
public struct AcceptState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var step = AcceptStep.input
    public var input = ""
    /// The screen was opened from a link (a Universal Link or `vettid://connect`): the member confirms first.
    public var fromLink = false
    public var connectionID: String?
    /// The inviter's name from the invitation, else the connection's.
    public var name: String?
    public var sas: String?
    public var remote = false
    public var end: RequestEnd?
    public var connectionName: String?
    public var busy = false
    public var error: FailureKind?

    public init(input: String = "", fromLink: Bool = false) {
        self.input = input
        self.fromLink = fromLink
    }

    public var description: String {
        "AcceptState(step: \(step), fromLink: \(fromLink), busy: \(busy), end: \(end.map { "\($0)" } ?? "nil"), "
            + "error: \(error.map { "\($0)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What the accept screen follows: the requests, the connections and how requests ended.
struct AcceptSources: Equatable, Sendable {
    var requests: [PendingConnection]
    var connections: [ConnectionInfo]
    var ends: [String: RequestEnd]
}

/// Accept an invitation (VAULT-MESSAGING §6.4, 0.10.2/0.10.3): a pasted or opened link or a scanned code. The vault
/// fetches the claim and runs the handshake; once it has, the safety code appears here (`connection.request.outgoing`)
/// and the member compares it with the inviter's screen and approves or declines their own side. The connection is made
/// once both have approved. A vault already connected to the inviter says so (`exists`). A scanned code is accepted at
/// once; an opened link waits for the member. Mirrors vettid-android `AcceptViewModel` (this one lives as long as its
/// screen, so a scanned code is sent once without a saved-state flag).
@MainActor
@Observable
public final class AcceptViewModel {
    public private(set) var state: AcceptState

    @ObservationIgnored private let connections: any ConnectionsRepository
    @ObservationIgnored private let requests: any ConnectionRequestsRepository
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()

    private static let followed: Set<AcceptStep> = [.waiting, .compare, .approved]

    /// [input]: a scanned code (accepted at once) or, with [opened], an opened link (the member confirms first); nil: the
    /// member pastes one.
    public init(
        connections: any ConnectionsRepository,
        requests: any ConnectionRequestsRepository,
        input: String? = nil,
        opened: Bool = false
    ) {
        self.connections = connections
        self.requests = requests
        state = AcceptState(input: input ?? "", fromLink: opened)
        if !state.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !opened { accept() }
        follows.add(follow(self, read: { $0.sources }, apply: { $0.onSources($1) }))
    }

    private var sources: AcceptSources {
        AcceptSources(requests: requests.requests, connections: connections.connections, ends: requests.requestEnds)
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    private func onSources(_ s: AcceptSources) {
        guard let id = state.connectionID, Self.followed.contains(state.step) else { return }
        let active = s.connections.first { $0.id == id && $0.state == .active }
        let request = s.requests.lazy.compactMap { p -> OutgoingRequest? in
            if case .outgoing(let r) = p, r.connectionID == id { return r }
            return nil
        }.first
        let end = s.ends[id]
        if end == .peerDeclined && request == nil && active == nil {
            // The inviter declined (0.10.5): told here, once (the notice is dismissed).
            state.step = .ended
            state.end = end
            requests.dismissPeerDecline(id)
            return
        }
        if let active {
            state.step = .connected
            state.connectionName = active.displayName.isEmpty ? nil : active.displayName
        } else if let end, request == nil {
            state.step = .ended
            state.end = end
        } else if let request {
            state.sas = request.sas ?? state.sas
            state.name = state.name ?? request.name
            state.remote = request.remote
            state.step = switch request.state {
            case .waiting: .waiting
            case .pending: state.step == .approved ? .approved : .compare
            case .approved: .approved
            }
        }
    }

    public func setInput(_ v: String) {
        state.input = v
        state.error = nil
    }

    /// Sends the invitation once: only from the input step (never a second time while one is under way).
    public func accept() {
        let text = state.input
        guard state.step == .input, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        state.step = .accepting
        state.error = nil
        let (connections, requests) = (connections, requests)
        work.launch { [weak self] in
            do {
                let r = try await connections.acceptInvite(text)
                guard let self else { return }
                if r.exists {
                    let c = connections.connections.first { $0.id == r.connectionID }
                    state.step = .exists
                    state.connectionID = r.connectionID
                    state.connectionName = c.flatMap { $0.displayName.isEmpty ? nil : $0.displayName }
                    return
                }
                state.step = .waiting
                state.connectionID = r.connectionID
                state.name = r.name
                // The code may have arrived already (the handshake is quick): show it.
                onSources(sources)
                try? await requests.refreshRequests()
            } catch {
                guard let self else { return }
                state.step = .input
                state.error = failureKind(error)
            }
        }
    }

    /// This member's approval of their side, after comparing the codes.
    public func approve() {
        guard let id = state.connectionID else { return }
        state.busy = true
        state.error = nil
        let requests = requests
        work.launch { [weak self] in
            do {
                try await requests.approveOutgoing(id)
                guard let self else { return }
                state.busy = false
                if state.step == .compare { state.step = .approved }
            } catch {
                self?.fail(error)
            }
        }
    }

    /// Declines (the codes differ, or the member changed their mind); the vault tells the inviter's vault (§6.4, 0.10.5).
    public func decline() {
        guard let id = state.connectionID else { return }
        state.busy = true
        state.error = nil
        let requests = requests
        work.launch { [weak self] in
            do {
                try await requests.declineOutgoing(id)
                guard let self else { return }
                state.busy = false
                state.step = .ended
                state.end = .declined
            } catch {
                self?.fail(error)
            }
        }
    }

    private func fail(_ error: any Error) {
        state.busy = false
        state.error = failureKind(error)
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
