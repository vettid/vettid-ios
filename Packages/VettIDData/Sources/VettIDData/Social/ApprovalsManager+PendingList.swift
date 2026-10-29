import Foundation
import VettIDCrypto
import VettIDVault

/// The asks that arrive only as events, read back with `pending.list` (VAULT-MESSAGING 0.70.0 §10.4.2). The app reads every
/// page after the unlock and after a passed owner check, and replaces its kept events of the kinds it handles with the list.
/// The `action` and `location` entries are not handled on this phone (it has no screen for either): they are skipped, never
/// parsed and never a failure.
extension ApprovalsManager {
    static let sessionType = "device.session.pending"

    /// The event type each `pending.list` kind repeats, for the kinds this app handles.
    static let pendingKinds: [String: String] = [
        "authenticate": "connection.authenticate.pending", "session": sessionType, "approval": "approval.pending",
    ]

    /// The event types of those kinds.
    static let pendingTypes = Set(pendingKinds.values)

    /// At most this many pages are read in one go (chosen; not in the spec): the vault's limits keep the whole list far
    /// below it, and a vault that never ends its cursor does not hold the read.
    static let maxPendingPages = 100

    /// An entry of the list: the event type it repeats and its `body` exactly as received.
    struct OpenAsk: Equatable {
        var type: String
        var body: String
    }

    /// What the read of `pending.list` found.
    enum PendingRead {
        /// Every page was read.
        case answered([OpenAsk])
        /// Not asked, or the vault answered `unsupported_type`: nothing is covered and nothing dropped.
        case unsupported
        /// A page failed (the network, `owner_check_required` while held, ...): nothing is covered, what is known stays,
        /// and the next refresh tries again.
        case failed
    }

    /// The vault was opened (an unlock, not a passed owner check after a hold, which only drops and reads again): a vault
    /// that did not know `pending.list` is asked again (VAULT-MESSAGING 0.70.0 §10.4.2 "Older vaults").
    public func vaultOpened() { pendingListUnsupported = false }

    /// Reads every page of `pending.list` ([g] the generation the read began in). The first page's `ts` is kept from then
    /// on (``pendingListTs``), so that events processed during the read are judged by it too; if a page fails, the
    /// earlier value is kept.
    func readPendingAsks(_ o: any ApprovalOps, generation g: Int) async -> PendingRead {
        guard !pendingListUnsupported else { return .unsupported }
        let before = pendingListTs
        var asks: [OpenAsk] = []
        var after: String?
        do {
            for page in 0..<Self.maxPendingPages {
                let answer = try await o.pendingListPage(after: after, limit: nil)
                if page == 0, g == generation { pendingListTs = max(answer.ts, before ?? .distantPast) }
                for entry in VaultJSON.objects(answer.body, "asks") {
                    // Other kinds (`action`, `location`, and any a later release adds) are skipped.
                    guard let kind = VaultJSON.string(entry, "kind"), let type = Self.pendingKinds[kind],
                          let body = VaultJSON.obj(entry, "body") else { continue }
                    asks.append(OpenAsk(type: type, body: body.raw))
                }
                guard let next = VaultJSON.string(answer.body, "next"), !next.isEmpty, next != after else { return .answered(asks) }
                after = next
            }
        } catch {
            guard g == generation else { return .failed }
            pendingListTs = before
            guard (VaultFailures.map(error) as? VaultFailure)?.kind == .notSupported else { return .failed }
            pendingListUnsupported = true
            return .unsupported
        }
        if g == generation { pendingListTs = before }
        return .failed
    }

    /// Replaces the kept events of the listed kinds with [asks], merging by the ask's key: an ask the list does not hold is
    /// gone (decided elsewhere, expired or withdrawn), one it holds that is not kept comes back (received now, since the
    /// list does not say when; chosen, not in the spec), and what changed since [since] (an event that arrived, a decision
    /// or a closing) is not undone.
    func mergePendingAsks(_ asks: [OpenAsk], at t: Date, since: Int, changed: (String) -> Bool) {
        var order: [String] = []
        var byKey: [String: OpenAsk] = [:]
        for ask in asks {
            guard let o = try? StrictJson.parseObject(Array(ask.body.utf8)), let p = ApprovalParser.parse(ask.type, o, at: t),
                  (p.exp ?? .distantFuture) > t else { continue }
            // A session request whose device's session closed during the read is not taken from the list.
            if case .device(let d) = p, let id = d.deviceID, (sessionClosedAt[id] ?? 0) > since { continue }
            if byKey.updateValue(ask, forKey: p.key) == nil { order.append(p.key) }
        }
        pendingListAnswered = true
        edit { events in
            var kept: [StoredEvent] = []
            var have = Set<String>()
            for e in events {
                guard Self.pendingTypes.contains(e.type), let p = parsed(e) else {
                    kept.append(e)
                    continue
                }
                if changed(p.key) {
                    kept.append(e)
                    have.insert(p.key)
                } else if let listed = byKey[p.key] {
                    // The list's body is the vault's current one (a renamed device); the time it was first received stays.
                    kept.append(StoredEvent(type: listed.type, body: listed.body, at: e.at))
                    have.insert(p.key)
                }
            }
            for key in order where !have.contains(key) && !changed(key) {
                if let ask = byKey[key] { kept.append(StoredEvent(type: ask.type, body: ask.body, at: t)) }
            }
            events = kept
        }
    }
}
