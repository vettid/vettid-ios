import Foundation
import VettIDCrypto
import VettIDVault

// Connection requests (VAULT-MESSAGING §6.4, §10.4; 0.10.2–0.10.6): the vault's events about connections and requests,
// the member's decisions, and how a request ends. Mirrors the request part of vettid-android `SocialManager`.
extension ConnectionsManager {
    /// Longer than any request lives (§6.4: an approved incoming one, 16 days).
    static let nameRetention: TimeInterval = 17 * 86_400

    // MARK: - Events

    /// One event of the vault (§9.1). The state changes at once; the lists the event invalidates are read again in the
    /// background.
    public func onEvent(_ m: VaultMessage) {
        let b = m.object
        switch m.type {
        case "connection.request.pending":
            if let r = ConnectionParser.incoming(b, at: now()) { onRequest(.incoming(r)) }
        case "connection.request.outgoing":
            if let r = ConnectionParser.outgoing(b, at: now()) { onRequest(.outgoing(r)) }
        case "connection.event":
            onConnectionEvent(b)
        case "connection.authenticate.result":
            onAuthenticateResult(b)
        case "connection.authenticate.key":
            onAuthenticateKey(b)
        case "sync.event":
            onSync(VaultJSON.string(b, "kind") ?? "", b)
        default:
            break
        }
    }

    /// `connection.authenticate.result` (§10.4): built from the state held now, so a list read taken in meanwhile is not
    /// undone (see ``ConnectionParser/authResult(_:now:previous:)``: only a successful verdict decides the key warning).
    private func onAuthenticateResult(_ b: JsonObject) {
        guard let id = VaultJSON.string(b, "connection_id"),
              let s = ConnectionParser.authResult(b, now: now(), previous: authentication[id]) else { return }
        authentication[id] = s
    }

    /// `connection.authenticate.key {connection_id, key}` (VAULT-MESSAGING 0.88.1 §10.4): this vault followed a delivered
    /// `connection.authenticate.rotated` chain from the key it had pinned and pinned the chain's last key. The vault did
    /// every check; the app follows no chain (it never sees `rotated` or `rotations`).
    ///
    /// What it does: re-reads `connection.list` and `connection.authenticate.list` and takes them in as ``refresh()`` does.
    /// The list is authoritative: the event's `key` is only checked for form (an event without a `connection_id` and a
    /// well-formed `key` is ignored, no read) and is never written.
    ///
    /// What it does NOT do: change ``AuthenticationState/keyChanged``. A standing `keyChanged` came from a successful
    /// `.result` with `key_changed: true`: the vault saw a key its pin did not lead to and re-pinned to it without
    /// verifying the step. A `.key` event follows a chain from the vault's pin at that moment, which after such a result is
    /// that unverified key, so it verifies nothing about the change the warning is about. Only the next successful
    /// `.result` decides the warning again.
    ///
    /// Off the event path and conflated: a peer controls how often it rotates, so one re-read runs at a time, and an event
    /// that comes while it runs only marks one more read due (a burst costs at most two reads, the last starting after the
    /// last event). The write needs the ``generation`` of the event (the lock, a hold and a wipe each advance it).
    private func onAuthenticateKey(_ b: JsonObject) {
        guard VaultJSON.string(b, "connection_id") != nil, ConnectionParser.credentialKey(b) != nil else { return }
        let g = generation
        if keyRereadRunning {
            keyRereadQueued = g
            return
        }
        keyRereadRunning = true
        Task { [weak self] in await self?.rereadAuthentication(first: g) }
    }

    /// The re-read job: reads for [first], then once more for the mark left while it read, until none is left. Each read
    /// ends: every vault request has a reply timeout (``VaultDevice/requestTimeout``), so the job always frees its slot.
    private func rereadAuthentication(first: Int) async {
        var next: Int? = first
        while let g = next {
            await rereadAuthenticationOnce(at: g)
            next = keyRereadQueued
            keyRereadQueued = nil
            if next == nil { keyRereadRunning = false }
        }
    }

    /// One re-read for an event taken at [g]: written only if the vault was not locked, held or wiped since (the check and
    /// the write have no suspension between them). A failed read, in either half, writes nothing (the next
    /// ``refresh()`` reads both), and nothing is raised to the member: it is a read nobody asked for (``quietOps``).
    private func rereadAuthenticationOnce(at g: Int) async {
        let asked = Set(connections.map(\.id))
        guard let read = try? await readConnections(quietOps) else { return }
        await keyRereadHook?()
        guard read.states != nil, read.authFailure == nil, g == generation else { return }
        take(read, asked: asked)
    }

    /// A request event (`connection.request.pending` / `.outgoing`): shown at once; an event never takes back what a
    /// decision already moved on.
    func onRequest(_ r: PendingConnection) {
        if let i = open.firstIndex(where: { $0.id == r.id }) {
            open[i] = open[i].merged(r)
        } else {
            open.append(r)
        }
        requestEnds[r.id] = nil
        if let n = r.name { rememberNames([(r.id, n)]) }
    }

    private func onConnectionEvent(_ b: JsonObject) {
        guard let conn = VaultJSON.string(b, "connection_id") else { return }
        switch VaultJSON.string(b, "event") {
        case "added": onAdded(request: VaultJSON.string(b, "pending_id") ?? conn)
        // An outgoing request ended without a connection other than by this member's decline (§6.4); `reason:
        // "declined"`: the inviter declined (0.10.5), told once with the sync.event that accompanies it.
        case "failed":
            if VaultJSON.string(b, "reason") == "declined" {
                onPeerDeclined(conn, outgoing: true)
            } else {
                endRequest(conn, .failed)
            }
        case "removed": forget(conn)
        // VAULT-MESSAGING 0.88.7 §3.4.1 "Stale is not final": the peer's rekey or reconnect makes a stale connection
        // active again; shown at once, before the list read below says so (the vault's list is authoritative).
        case "rekeyed", "reconnected": activateIfStale(conn)
        default: break
        }
        Task { [weak self] in try? await self?.refresh(quietly: true) }
    }

    private func activateIfStale(_ id: String) {
        guard let i = connections.firstIndex(where: { $0.id == id }), connections[i].state == .stale else { return }
        connections[i].state = .active
    }

    /// A new connection: the request it came from ([request], §10.4 `pending_id`) is done with.
    private func onAdded(request: String) {
        open.removeAll { $0.id == request }
        edit { $0.requestNames[request] = nil }
    }

    /// `sync.event` kinds about connections (§10.1).
    private func onSync(_ kind: String, _ b: JsonObject) {
        switch kind {
        case "connection.changed", "block.added", "block.removed":
            Task { [weak self] in try? await self?.refresh(quietly: true) }
        case "connection.request":
            onRequestSync(b)
        default:
            break
        }
    }

    /// `sync.event{kind: "connection.request"}`: another device's decision, the peer's approval or decline (0.10.5), or
    /// an expiry (§10.1). `pending_id` names an incoming request, `connection_id` an outgoing one.
    private func onRequestSync(_ b: JsonObject) {
        let pending = VaultJSON.string(b, "pending_id")
        guard let id = pending ?? VaultJSON.string(b, "connection_id") else { return }
        switch VaultJSON.string(b, "state") {
        case "approved": patchRequest(id) { $0.with(state: .approved) }
        case "peer_approved": patchRequest(id) { $0.with(peerApproved: true) }
        case "declined": endRequest(id, .declined)
        case "peer_declined": onPeerDeclined(id, outgoing: pending == nil)
        case "expired": endRequest(id, .expired)
        default: break
        }
    }

    // MARK: - Request bookkeeping

    /// Keeps the names requests showed (0.10.5), dropping ones older than any request can live.
    func rememberNames(_ names: [(String, String)]) {
        let fresh = names.filter { local.requestNames[$0.0]?.name != $0.1 }
        guard !fresh.isEmpty else { return }
        let t = now()
        edit { l in
            l.requestNames = l.requestNames.filter { $0.value.at >= t.addingTimeInterval(-Self.nameRetention) }
            for (id, n) in fresh { l.requestNames[id] = StoredRequestName(name: n, at: t) }
        }
    }

    func patchRequest(_ id: String, _ f: (PendingConnection) -> PendingConnection) {
        guard let i = open.firstIndex(where: { $0.id == id }) else { return }
        open[i] = f(open[i])
    }

    /// The request ended without a connection. The other member's decline is
    /// what the member is told, whatever end follows it; a bare `failed` keeps the name, since an older ordering may
    /// still bring the peer's decline (0.10.5).
    func endRequest(_ id: String, _ end: RequestEnd) {
        open.removeAll { $0.id == id }
        if requestEnds[id] != .peerDeclined { requestEnds[id] = end }
        if end != .failed { edit { $0.requestNames[id] = nil } }
    }

    /// The other member declined request [id] (`connection.declined`, 0.10.5, §6.4): it ends and the member is told
    /// once, with the name the request showed. [outgoing]: this member's own outgoing request (the accepter's side).
    /// Comes as `sync.event{peer_declined}` and, on the accepter's side, also as `connection.event{failed, reason:
    /// "declined"}`, in either order.
    func onPeerDeclined(_ id: String, outgoing: Bool) {
        let name = open.first(where: { $0.id == id })?.name ?? local.requestNames[id]?.name
        let first = notedDeclines.insert(id).inserted && !local.declines.contains { $0.requestID == id }
        open.removeAll { $0.id == id }
        requestEnds[id] = .peerDeclined
        let at = now()
        edit { l in
            l.requestNames[id] = nil
            if first { l.declines.append(PeerDecline(requestID: id, name: name, outgoing: outgoing, at: at)) }
        }
    }

    public func dismissPeerDecline(_ requestID: String) {
        edit { $0.declines.removeAll { $0.requestID == requestID } }
    }

    // MARK: - ConnectionRequestsRepository

    public func refreshRequests() async throws { try await refreshRequests(quietly: false) }

    func refreshRequests(quietly: Bool) async throws {
        let g = requestGeneration
        let o = quietly ? quietOps : ops
        let list = try await guarded { try await o().requestList() }
        guard g == requestGeneration else { return }
        let t = now()
        let parsed: [PendingConnection] = VaultJSON.objects(list, "incoming").compactMap { ConnectionParser.incoming($0, at: t) }
            .map(PendingConnection.incoming)
            + VaultJSON.objects(list, "outgoing").compactMap { ConnectionParser.outgoing($0, at: t) }.map(PendingConnection.outgoing)
        // The list is authoritative for which requests are open, but a read sent before this member's decision and
        // answered after it takes nothing back: a request decided here keeps its state, and one that ended here does not
        // come back (chosen; not in the spec: vettid-android replaces its list wholesale).
        open = parsed.filter { requestEnds[$0.id] == nil }.map { r in open.first { $0.id == r.id }.map { $0.merged(r) } ?? r }
        rememberNames(parsed.compactMap { r in r.name.map { (r.id, $0) } })
    }

    /// Runs a decision on a connection request; `not_found` means it already ended.
    private func decide(_ id: String, _ body: (any ConnectionOps) async throws -> Void) async throws {
        do {
            try await guarded { try await body(try await ops()) }
        } catch let f as VaultFailure where f.kind == .notFound {
            endRequest(id, .gone)
            throw f
        }
    }

    // The connection becomes active with both approvals (0.10.3): the request stays, approved, until `added`.
    public func approveConnection(_ pendingID: String) async throws {
        try await decide(pendingID) { try await $0.connectionApprove(pendingID: pendingID) }
        patchRequest(pendingID) { $0.with(state: .approved) }
    }

    public func declineConnection(_ pendingID: String) async throws {
        try await decide(pendingID) { try await $0.connectionDecline(pendingID: pendingID) }
        endRequest(pendingID, .declined)
    }

    public func blockConnectionRequest(_ pendingID: String) async throws {
        try await decide(pendingID) { _ = try await $0.blockAdd(connectionID: nil, pendingID: pendingID, note: nil) }
        endRequest(pendingID, .declined)
    }

    public func approveOutgoing(_ connectionID: String) async throws {
        try await decide(connectionID) { try await $0.outgoingApprove(connectionID: connectionID) }
        patchRequest(connectionID) { $0.with(state: .approved) }
    }

    public func declineOutgoing(_ connectionID: String) async throws {
        try await decide(connectionID) { try await $0.outgoingDecline(connectionID: connectionID) }
        endRequest(connectionID, .declined)
    }
}
