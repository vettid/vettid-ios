import Foundation
import Observation
import VettIDCrypto
import VettIDVault

/// Connections, invitations and connection requests on this device (VAULT-MESSAGING §6.4, §10.4, §10.4.1, §10.8;
/// ANDROID-PLAN §4), over the vault client. The lists live in memory and are read again from the vault (which keeps
/// them) when it opens and on its events (``onEvent(_:)``, forwarded by ``VaultManager``). What only this phone learns,
/// the names open requests showed and the other member's declines not yet dismissed (0.10.5), lives in memory only, like
/// every other vault content (IOS-PLAN §6.9): nothing is written to the phone, and it is dropped with the connections and
/// the requests when the vault locks, at a hold and at a wipe. The safety code of a request is not kept apart from its
/// request: `connection.request.list` returns it while the request is open (§10.4), so an unlock or a new start reads it
/// again (IOS-PLAN §6.9; vettid-android writes it to its file but never reads it back). Nothing here touches transport or
/// crypto beyond the typed calls. Mirrors the connection part of vettid-android `SocialManager`.
@MainActor
@Observable
public final class ConnectionsManager: ConnectionsRepository, ConnectionRequestsRepository {
    public internal(set) var connections: [ConnectionInfo] = []
    /// The open requests as last read or announced, in no order (``requests`` sorts and filters them).
    var open: [PendingConnection] = []
    public internal(set) var requestEnds: [String: RequestEnd] = [:]
    public internal(set) var peerDeclines: [PeerDecline] = []
    /// What the vault says of each connection's member authentication (§10.4), by connection id: from
    /// `connection.authenticate.list` and the verdicts (`connection.authenticate.result`). In memory only, dropped with the
    /// connections (``forgetOpenVault()``), with a connection that goes, and at a wipe.
    public internal(set) var authentication: [String: AuthenticationState] = [:]

    @ObservationIgnored let ops: @MainActor () async throws -> any ConnectionOps
    /// The calls of a read nobody asked for (at the opening, after an owner check, on an event): only over the session
    /// already open, never opening one.
    @ObservationIgnored let quietOps: @MainActor () async throws -> any ConnectionOps
    @ObservationIgnored let now: @Sendable () -> Date
    @ObservationIgnored var local = Local()
    /// Peer declines noted in this run, so that the `failed` that accompanies one never shows it again (0.10.5).
    @ObservationIgnored var notedDeclines: Set<String> = []
    @ObservationIgnored private var ttls: [InviteTtl]?
    /// Bumped whenever the connections read from the open vault are dropped: a list read before is not published (chosen;
    /// not in the spec).
    @ObservationIgnored var generation = 0
    /// The same for the requests (``forgetRequests()``), apart from the connections'. Today the requests are dropped only
    /// with everything else (``forgetOpenVault()`` advances both), so the two move together; apart, a later drop of the
    /// requests alone would keep a read of the connections on its way.
    @ObservationIgnored var requestGeneration = 0
    /// A `connection.authenticate.key` re-read is running (``rereadAuthentication(first:)``); an event that comes while it
    /// runs only sets ``keyRereadQueued``.
    @ObservationIgnored var keyRereadRunning = false
    /// The ``generation`` of the latest `connection.authenticate.key` event that came while a re-read ran: one more read is due.
    @ObservationIgnored var keyRereadQueued: Int?
    /// Test hook: runs after a `connection.authenticate.key` re-read has its answers and before they are written.
    @ObservationIgnored var keyRereadHook: (@MainActor () async -> Void)?
    /// Told of every connection that is gone (removed, blocked, or removed by the peer): its messages go with it.
    @ObservationIgnored public var onForget: @MainActor (String) -> Void = { _ in }
    /// Told whenever the connections read from the vault are dropped (the lock, a hold, a wipe), for what the app derived from
    /// them and keeps in memory (the decoded photos).
    @ObservationIgnored public var onForgetAll: @MainActor () -> Void = {}

    /// [ops] the vault's calls, opened when needed; [quietOps] those of the background reads (nil: [ops]).
    public init(
        ops: @escaping @MainActor () async throws -> any ConnectionOps,
        quietOps: (@MainActor () async throws -> any ConnectionOps)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ops = ops
        self.quietOps = quietOps ?? ops
        self.now = now
    }

    public var requests: [PendingConnection] {
        let t = now()
        return open.filter { ($0.exp ?? .distantFuture) > t }.sorted { $0.receivedAt > $1.receivedAt }
    }

    // MARK: - Local state

    /// What only this phone learns, in memory: the names open requests showed, by request id, and the other member's
    /// declines.
    struct Local: Codable, Equatable {
        var requestNames: [String: StoredRequestName] = [:]
        var declines: [PeerDecline] = []
    }

    /// The name a request showed, kept until a peer's decline can name it (0.10.5).
    struct StoredRequestName: Codable, Equatable {
        var name: String
        var at: Date
    }

    /// Changes the kept state (in memory only).
    func edit(_ f: (inout Local) -> Void) {
        var next = local
        f(&next)
        guard next != local else { return }
        local = next
        if peerDeclines != next.declines { peerDeclines = next.declines }
    }

    /// The vault is no longer open on this phone (locked, or a lock was asked for): the connections and requests read
    /// from it, and the names and declines learnt of them, are dropped from memory; an unlock reads the lists again.
    /// Also at a hold (IOS-PLAN §6.9: vault content is cleared at the vault lock, at a hold and at a wipe). A read on its
    /// way is not published.
    ///
    /// The authentication states go with it unless [keepingAuthentication]: at a hold or a due owner check they stay, with
    /// the key-change warning (vettid-android's `forgetPending` keeps them; the vault is the same one and a warning the
    /// member MUST be shown is not forgotten by a hold); the lock, a wipe and ``clear()`` drop them
    /// (``forgetAuthentication()``). A read begun before the hold is not published either way (the ``generation`` moved),
    /// and the lists read after the hold take the states in again.
    public func forgetOpenVault(keepingAuthentication: Bool = false) {
        generation += 1
        connections = []
        if !keepingAuthentication { authentication = [:] }
        forgetRequests()
        onForgetAll()
    }

    /// Drops the authentication states (the lock, a wipe), after a hold kept them.
    public func forgetAuthentication() {
        generation += 1
        authentication = [:]
    }

    /// The open requests, with their names and safety codes, and the other member's declines are dropped from memory; an
    /// unlock or a passed owner check reads the requests again (`connection.request.list`). A read of the requests or an
    /// accept on its way is not published; a read of the connections is. The ids of the declines already told stay, so
    /// that a late `failed` does not tell one again (they hold no name).
    func forgetRequests() {
        requestGeneration += 1
        open = []
        edit { $0 = Local() }
    }

    /// Forgets everything (a wipe, or a deleted vault).
    public func clear() {
        forgetOpenVault()
        requestEnds = [:]
        keyRereadQueued = nil
        notedDeclines = []
        ttls = nil
    }

    /// The vault opened: the connections and the requests are read again; failures are left for the screens to retry.
    public func refreshAllQuietly() {
        Task { [weak self] in
            try? await self?.refresh(quietly: true)
            try? await self?.refreshRequests(quietly: true)
        }
    }

    /// Runs [body] and turns every failure into a ``VaultFailure`` (a cancellation stays one).
    func guarded<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw VaultFailures.map(error)
        }
    }

    // MARK: - ConnectionsRepository

    public func refresh() async throws { try await refresh(quietly: false) }

    func refresh(quietly: Bool) async throws {
        let g = generation
        let asked = Set(connections.map(\.id))
        let o = quietly ? quietOps : ops
        let read = try await guarded { try await readConnections(o) }
        guard g == generation else { return }
        take(read, asked: asked)
        if let failure = read.authFailure { throw VaultFailures.map(failure) }
    }

    /// `connection.list` and `connection.authenticate.list` as the vault answered them. A refused `authenticate.list`
    /// (the vault answered with an error: a vault without the type) is no states and no failure; any other failure of it
    /// is kept in [authFailure] for the caller to throw once the connections are taken in.
    struct ConnectionRead {
        var connections: [Connection]
        var states: [AuthenticationState]?
        var authFailure: Error?
    }

    func readConnections(_ o: @MainActor () async throws -> any ConnectionOps) async throws -> ConnectionRead {
        let api = try await o()
        let connections = try await api.connectionList()
        do {
            let states = VaultJSON.objects(try await api.authenticateList(), "states").compactMap(ConnectionParser.authState)
            return ConnectionRead(connections: connections, states: states)
        } catch is VaultOpError {
            return ConnectionRead(connections: connections, states: nil)
        } catch {
            return ConnectionRead(connections: connections, states: nil, authFailure: error)
        }
    }

    /// Takes a whole read in; the caller has checked the ``generation`` it was asked at. The connections are merged as
    /// before. The authentication list is authoritative for what it carries (times, last result, the pinned `key`); one
    /// thing it does not carry is kept from the state held: the `keyChanged` warning (`key_changed` exists only on a
    /// `connection.authenticate.result`, §10.4, so a list read cannot say whether the last verdict was a key change;
    /// without the carry-over every re-read would silently drop a warning the member MUST be shown). States the list does
    /// not name are kept, except those of connections that went.
    func take(_ read: ConnectionRead, asked: Set<String>) {
        let next = read.connections.filter { $0.kind == "connection" }.map(ConnectionParser.connection)
        let kept = Set(next.map(\.id))
        // A connection read while the list was on its way (``connection(_:)``) stays; one the vault no longer lists that
        // was known when the list was asked for (removed on another device) goes, and takes its conversation with it.
        let added = connections.filter { !asked.contains($0.id) && !kept.contains($0.id) }
        let gone = connections.map(\.id).filter { asked.contains($0) && !kept.contains($0) }
        connections = next + added
        if let states = read.states {
            var merged = authentication
            for st in states {
                var s = st
                s.keyChanged = merged[st.connectionID]?.keyChanged ?? false
                merged[st.connectionID] = s
            }
            authentication = merged
        }
        // States kept across a hold for a connection the vault no longer lists (removed meanwhile) go with it.
        if read.states != nil {
            let listed = Set(connections.map(\.id))
            authentication = authentication.filter { listed.contains($0.key) }
        }
        for id in gone {
            authentication[id] = nil
            onForget(id)
        }
    }

    public func connection(_ id: String) async throws -> ConnectionInfo {
        let g = generation
        let c = ConnectionParser.connection(try await guarded { try await ops().connectionGet(id) })
        if g == generation { replace(c, addIfMissing: true) }
        return c
    }

    func replace(_ c: ConnectionInfo, addIfMissing: Bool = false) {
        if let i = connections.firstIndex(where: { $0.id == c.id }) {
            connections[i] = c
        } else if addIfMissing {
            connections.append(c)
        }
    }

    public func inviteTtls() async throws -> [InviteTtl] {
        if let ttls { return ttls }
        let limit = try await guarded { try await ops().inviteLifetimeLimit() }
        let allowed = InviteTtl.allCases.filter { UInt64($0.seconds) <= limit }
        let t = allowed.isEmpty ? [InviteTtl.tenMinutes] : allowed
        ttls = t
        return t
    }

    public func createInvite(_ ttl: InviteTtl) async throws -> InviteInfo {
        try await guarded {
            let i = try await ops().inviteCreate(ttlSeconds: ttl.seconds)
            let exp = try ConnectionParser.instant(i.exp) ?? InviteLinks.expiry(i.link)
            return InviteInfo(inviteID: i.inviteID, link: i.link, qr: try InviteLinks.qrPayload(i.link), exp: exp, remote: i.remote)
        }
    }

    public func outstandingInvites() async throws -> [OutstandingInvite] {
        let o = try await guarded { try await ops().inviteList() }
        let t = now()
        return VaultJSON.objects(o, "invites").compactMap(ConnectionParser.invite).filter { ($0.exp ?? .distantFuture) > t }
    }

    public func cancelInvite(_ inviteID: String) async throws {
        try await guarded { try await ops().inviteCancel(inviteID) }
    }

    public func acceptInvite(_ text: String) async throws -> AcceptedConnection {
        let link: String
        switch InviteLinks.parse(text, now: now()) {
        case .ok(let l, _): link = l
        case .expired: throw VaultFailure(.inviteExpired)
        case .notAConnection: throw VaultFailure(.inviteNotConnection)
        case .invalid: throw VaultFailure(.inviteInvalid)
        }
        let g = requestGeneration
        let r = try await guarded { try await accepted(link) }
        if !r.exists, g == requestGeneration { addWaiting(r) }
        return r
    }

    /// `connection.invite.accept`; §6.4 "Already connected" (0.10.2): `exists` names the vault's own id for that peer, and
    /// no handshake was made.
    private func accepted(_ link: String) async throws -> AcceptedConnection {
        do {
            let a = try await ops().inviteAccept(link)
            let name = a.name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            return AcceptedConnection(
                connectionID: a.connectionID, name: name, exp: ConnectionParser.instant(a.exp), isService: a.peerKind == "service"
            )
        } catch let e as VaultOpError where e.code == "exists" {
            guard let id = e.body.flatMap({ VaultJSON.string(VaultJSON.object($0), "connection_id") }) else { throw e }
            return AcceptedConnection(connectionID: id, exists: true)
        }
    }

    /// The accepted invitation's outgoing request, `waiting` for its handshake; the outgoing event may already have
    /// arrived (it follows `hs.resp`): it is kept then.
    private func addWaiting(_ r: AcceptedConnection) {
        if !open.contains(where: { $0.id == r.connectionID }) {
            var w = OutgoingRequest(
                connectionID: r.connectionID, sas: nil, remote: false, name: r.name, state: .waiting, receivedAt: now(), exp: r.exp
            )
            w.isService = r.isService
            open.append(.outgoing(w))
        }
        requestEnds[r.connectionID] = nil
        if let n = r.name { rememberNames([(r.connectionID, n)]) }
    }

    public func setFavorite(_ id: String, favorite: Bool) async throws {
        try await updateMeta(id, ConnectionMetaChange(favorite: favorite))
    }

    /// `connection.update` against the version this phone has; when another device changed it first (`conflict`), once
    /// more against the current version.
    private func updateMeta(_ id: String, _ change: ConnectionMetaChange) async throws {
        try await guarded {
            let o = try await ops()
            var version = if let v = connections.first(where: { $0.id == id })?.version { v } else { try await o.connectionGet(id).version }
            do {
                _ = try await o.connectionUpdate(id, version: version, change: change)
            } catch let e as VaultOpError where e.code == "conflict" {
                version = try await o.connectionGet(id).version
                _ = try await o.connectionUpdate(id, version: version, change: change)
            }
            replace(ConnectionParser.connection(try await o.connectionGet(id)))
        }
    }

    public func remove(_ id: String) async throws {
        try await guarded { try await ops().connectionRemove(id) }
        forget(id)
    }

    public func block(_ id: String) async throws {
        _ = try await guarded { try await ops().blockAdd(connectionID: id, pendingID: nil, note: nil) }
        forget(id)
    }

    func forget(_ id: String) {
        connections.removeAll { $0.id == id }
        authentication[id] = nil
        onForget(id)
    }

    public func setAsksMuted(_ id: String, muted: Bool) async throws {
        try await guarded { try await ops().connectionAsksMute(id, muted: muted) }
        patchAsks(id) { $0.muted(muted) }
        try? await refresh()
    }

    public func resumeAsks(_ id: String) async throws {
        try await guarded { try await ops().connectionAsksResume(id) }
        patchAsks(id) { $0.resumed() }
        try? await refresh()
    }

    /// The answer is in: shown at once, before `sync.event{connection.changed}` and the list say so (§10.4.1).
    private func patchAsks(_ id: String, _ f: (AskState) -> AskState) {
        guard let i = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[i].asks = f(connections[i].asks ?? AskState())
    }
}
