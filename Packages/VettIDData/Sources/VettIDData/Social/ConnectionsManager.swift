import Foundation
import Observation
import VettIDCrypto
import VettIDVault

/// Connections, invitations and connection requests on this device (VAULT-MESSAGING §6.4, §10.4, §10.4.1, §10.8;
/// ANDROID-PLAN §4), over the vault client. The lists live in memory and are read again from the vault (which keeps
/// them) when it opens and on its events (``onEvent(_:)``, forwarded by ``VaultManager``). What only this phone learns,
/// the names open requests showed and the other member's declines not yet dismissed (0.10.5), is kept in an encrypted
/// file through [load] and [persist]. The safety code of a request is not kept on the phone: `connection.request.list`
/// returns it while the request is open (vettid-android writes it to its file but never reads it back; chosen; not in
/// the spec). Nothing here touches transport or crypto beyond the typed calls. Mirrors the connection part of
/// vettid-android `SocialManager`.
@MainActor
@Observable
public final class ConnectionsManager: ConnectionsRepository, ConnectionRequestsRepository {
    public internal(set) var connections: [ConnectionInfo] = []
    /// The open requests as last read or announced, in no order (``requests`` sorts and filters them).
    var open: [PendingConnection] = []
    public internal(set) var requestEnds: [String: RequestEnd] = [:]
    public internal(set) var peerDeclines: [PeerDecline] = []

    @ObservationIgnored let ops: @MainActor () async throws -> any ConnectionOps
    /// The calls of a read nobody asked for (at the opening, after an owner check, on an event): only over the session
    /// already open, never opening one.
    @ObservationIgnored let quietOps: @MainActor () async throws -> any ConnectionOps
    @ObservationIgnored private let load: @MainActor () throws -> [UInt8]?
    @ObservationIgnored private let persist: @MainActor ([UInt8]) throws -> Void
    @ObservationIgnored let now: @Sendable () -> Date
    @ObservationIgnored var local = Local()
    @ObservationIgnored private var loaded = false
    /// Peer declines noted in this run, so that the `failed` that accompanies one never shows it again (0.10.5).
    @ObservationIgnored var notedDeclines: Set<String> = []
    @ObservationIgnored private var ttls: [InviteTtl]?
    /// Bumped whenever what was read from the open vault is dropped: a list read before is not published (chosen; not in
    /// the spec).
    @ObservationIgnored var generation = 0
    /// Told of every connection that is gone (removed, blocked, or removed by the peer): its messages go with it.
    @ObservationIgnored public var onForget: @MainActor (String) -> Void = { _ in }

    /// [ops] the vault's calls, opened when needed; [quietOps] those of the background reads (nil: [ops]); [load] and
    /// [persist] the encrypted file (read by ``loadIfNeeded()``; an empty write clears it).
    public init(
        ops: @escaping @MainActor () async throws -> any ConnectionOps,
        quietOps: (@MainActor () async throws -> any ConnectionOps)? = nil,
        load: @escaping @MainActor () throws -> [UInt8]? = { nil },
        persist: @escaping @MainActor ([UInt8]) throws -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ops = ops
        self.quietOps = quietOps ?? ops
        self.load = load
        self.persist = persist
        self.now = now
    }

    public var requests: [PendingConnection] {
        let t = now()
        return open.filter { ($0.exp ?? .distantFuture) > t }.sorted { $0.receivedAt > $1.receivedAt }
    }

    // MARK: - Local state

    /// What the file keeps: the names open requests showed, by request id, and the other member's declines.
    struct Local: Codable, Equatable {
        var requestNames: [String: StoredRequestName] = [:]
        var declines: [PeerDecline] = []
    }

    /// The name a request showed, kept until a peer's decline can name it (0.10.5).
    struct StoredRequestName: Codable, Equatable {
        var name: String
        var at: Date
    }

    /// Reads the file once (after the first-run cleanup); a file that cannot be read is an empty state.
    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let b = try? load(), !b.isEmpty, let l = try? JSONDecoder().decode(Local.self, from: Data(b)) { local = l }
        peerDeclines = local.declines
    }

    /// Changes the kept state and writes it (kept in memory when the write fails; the next one retries).
    func edit(_ f: (inout Local) -> Void) {
        loadIfNeeded()
        var next = local
        f(&next)
        guard next != local else { return }
        local = next
        if peerDeclines != next.declines { peerDeclines = next.declines }
        if let b = try? JSONEncoder().encode(next) { try? persist(Array(b)) }
    }

    /// The vault is no longer open on this phone (locked, or a lock was asked for): the connections and requests read
    /// from it are dropped from memory. What the phone keeps by design stays; an unlock reads the lists again.
    public func forgetOpenVault() {
        generation += 1
        connections = []
        open = []
    }

    /// Forgets everything (a wipe, or a deleted vault).
    public func clear() {
        generation += 1
        local = Local()
        loaded = true
        try? persist([])
        connections = []
        open = []
        requestEnds = [:]
        peerDeclines = []
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
        let o = quietly ? quietOps : ops
        let list = try await guarded { try await o().connectionList() }
        guard g == generation else { return }
        connections = list.filter { $0.kind == "connection" }.map(ConnectionParser.connection)
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
        let g = generation
        let r = try await guarded { try await accepted(link) }
        if !r.exists, g == generation { addWaiting(r) }
        return r
    }

    /// `connection.invite.accept`; §6.4 "Already connected" (0.10.2): `exists` names the vault's own id for that peer, and
    /// no handshake was made.
    private func accepted(_ link: String) async throws -> AcceptedConnection {
        do {
            let a = try await ops().inviteAccept(link)
            let name = a.name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            return AcceptedConnection(connectionID: a.connectionID, name: name, exp: ConnectionParser.instant(a.exp))
        } catch let e as VaultOpError where e.code == "exists" {
            guard let id = e.body.flatMap({ VaultJSON.string(VaultJSON.object($0), "connection_id") }) else { throw e }
            return AcceptedConnection(connectionID: id, exists: true)
        }
    }

    /// The accepted invitation's outgoing request, `waiting` for its handshake; the outgoing event may already have
    /// arrived (it follows `hs.resp`): it is kept then.
    private func addWaiting(_ r: AcceptedConnection) {
        if !open.contains(where: { $0.id == r.connectionID }) {
            open.append(.outgoing(OutgoingRequest(
                connectionID: r.connectionID, sas: nil, remote: false, name: r.name, state: .waiting, receivedAt: now(), exp: r.exp
            )))
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
