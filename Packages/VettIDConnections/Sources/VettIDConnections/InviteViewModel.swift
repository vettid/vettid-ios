import Foundation
import Observation
import VettIDData

/// The steps of inviting someone (VAULT-MESSAGING §6.4); ``declined``: the other member declined (0.10.5). Mirrors
/// vettid-android `InviteStep`.
public enum InviteStep: Equatable, Sendable {
    /// The invitation's lifetime.
    case choose
    /// The QR code and the link, until someone uses them.
    case showing
    /// The request arrived: compare the safety code, then approve, decline or block.
    case request
    /// This member approved; the other member's approval is awaited.
    case connecting
    case connected
    /// Nobody used the invitation in time.
    case expired
    case declined
}

/// The invite screen's state. The invitation's link lets whoever holds it ask to connect: never printed, dumped or
/// mirrored. Mirrors vettid-android `InviteUiState`.
public struct InviteState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var step = InviteStep.choose
    /// 10 minutes is always allowed (§6.4); the relay's limits may allow more.
    public var ttls: [InviteTtl] = [.tenMinutes]
    public var ttl = InviteTtl.tenMinutes
    public var invite: InviteInfo?
    public var request: ConnectionRequest?
    public var connectionID: String?
    public var connectionName: String?
    /// ``InviteStep/declined``: the name the request showed.
    public var declinedName: String?
    public var busy = false
    public var confirmBlock = false
    /// The request arrived already approved by in-person auto-approval (§6.4), not by this member here.
    public var autoApproved = false
    public var error: FailureKind?

    public init() {}

    public var description: String {
        "InviteState(step: \(step), ttl: \(ttl.seconds), busy: \(busy), error: \(error.map { "\($0)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Invite a connection (VAULT-MESSAGING §6.4, A4; 0.10.3): choose the lifetime (10 minutes in person, longer for a remote
/// link), show the QR code and the link; once the other vault has completed the handshake the request arrives with its
/// safety code (§10.4), which both members compare; each approves on their own phone, and the connection appears once
/// both have. Leaving the screen keeps the invitation (Connections lists it until it is used, cancelled or expires) and
/// the request (Approvals). Mirrors vettid-android `InviteViewModel`.
@MainActor
@Observable
public final class InviteViewModel {
    public private(set) var state = InviteState()

    @ObservationIgnored private let connections: any ConnectionsRepository
    @ObservationIgnored private let requests: any ConnectionRequestsRepository
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    /// The connections there were when the request arrived: a new active one is this invitation's.
    @ObservationIgnored private var before: Set<String> = []

    public init(
        connections: any ConnectionsRepository,
        requests: any ConnectionRequestsRepository,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.connections = connections
        self.requests = requests
        self.now = now
        work.launch { [weak self] in
            // 10 minutes is always allowed (§6.4); the vault checks the relay's limits again.
            guard let ttls = try? await connections.inviteTtls(), !ttls.isEmpty else { return }
            self?.state.ttls = ttls
        }
        follows.add(follow(self, read: { $0.requests.requests }, apply: { $0.onRequests($1) }))
        follows.add(follow(self, read: { $0.requests.peerDeclines }, apply: { $0.onDeclines($1) }))
        follows.add(follow(self, read: { $0.connections.connections }, apply: { $0.onConnections($1) }))
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
    }

    private func onRequests(_ list: [PendingConnection]) {
        guard let invite = state.invite else { return }
        let request = list.lazy.compactMap { p -> ConnectionRequest? in
            if case .incoming(let r) = p, r.inviteID == invite.inviteID { return r }
            return nil
        }.first
        guard let request else { return }
        switch state.step {
        case .showing:
            before = Set(connections.connections.map(\.id))
            // In-person auto-approval (§6.4): already approved here; the code is still shown to compare.
            let auto = request.state == .approved
            state.step = auto ? .connecting : .request
            state.request = request
            state.autoApproved = auto
        case .request, .connecting:
            state.request = request
        default:
            break
        }
    }

    /// The other member declined (0.10.5): told here, once (the notice is dismissed).
    private func onDeclines(_ list: [PeerDecline]) {
        guard state.step == .request || state.step == .connecting, let request = state.request else { return }
        guard let d = list.first(where: { !$0.outgoing && $0.requestID == request.pendingID }) else { return }
        state.step = .declined
        state.declinedName = d.name ?? request.name
        state.busy = false
        requests.dismissPeerDecline(d.requestID)
    }

    private func onConnections(_ list: [ConnectionInfo]) {
        guard state.step == .connecting || state.step == .request else { return }
        guard let added = list.first(where: { !before.contains($0.id) && $0.state == .active }) else { return }
        state.step = .connected
        state.connectionID = added.id
        state.connectionName = added.displayName.isEmpty ? nil : added.displayName
    }

    public func setTtl(_ ttl: InviteTtl) { state.ttl = ttl }

    public func create() {
        state.busy = true
        state.error = nil
        let (connections, ttl) = (connections, state.ttl)
        work.launch { [weak self] in
            do {
                let invite = try await connections.createInvite(ttl)
                guard let self else { return }
                state.busy = false
                state.step = .showing
                state.invite = invite
            } catch {
                self?.fail(error)
            }
        }
    }

    /// The screen's clock: past the expiry, the code is no longer shown.
    public func tick(_ at: Date? = nil) {
        guard state.step == .showing, let invite = state.invite, invite.exp <= (at ?? now()) else { return }
        state.step = .expired
    }

    /// This member's approval; the connection is made once the other member approves too (0.10.3).
    public func approve() {
        guard let request = state.request else { return }
        state.busy = true
        state.error = nil
        let requests = requests
        work.launch { [weak self] in
            do {
                try await requests.approveConnection(request.pendingID)
                guard let self else { return }
                state.busy = false
                if state.step != .connected { state.step = .connecting }
            } catch {
                self?.fail(error)
            }
        }
    }

    public func decline() {
        guard let request = state.request else { return }
        let requests = requests
        decide { try await requests.declineConnection(request.pendingID) }
    }

    public func askBlock(_ show: Bool) { state.confirmBlock = show }

    public func block() {
        guard let request = state.request else { return }
        state.confirmBlock = false
        let requests = requests
        decide { try await requests.blockConnectionRequest(request.pendingID) }
    }

    /// Cancels the invitation before anyone used it (the vault revokes its token and deletes the claim).
    public func cancelInvite() {
        guard let invite = state.invite else { return }
        let connections = connections
        decide { try await connections.cancelInvite(invite.inviteID) }
    }

    /// A new invitation, from the start, with the lifetimes and the choice kept.
    public func again() { state = Self.fresh(state) }

    /// A decision that ends this invitation's flow: back to the start once the vault took it.
    private func decide(_ call: @escaping @MainActor () async throws -> Void) {
        state.busy = true
        state.error = nil
        work.launch { [weak self] in
            do {
                try await call()
                guard let self else { return }
                state = Self.fresh(state)
            } catch {
                self?.fail(error)
            }
        }
    }

    private func fail(_ error: any Error) {
        state.busy = false
        state.error = failureKind(error)
    }

    private static func fresh(_ s: InviteState) -> InviteState {
        var n = InviteState()
        n.ttls = s.ttls
        n.ttl = s.ttl
        return n
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
