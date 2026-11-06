import Foundation
import VettIDRelay

// The device's mailbox collector (RELAY-PROTOCOL §6.3, §6.4) and what it tells of its requests: when each went out, and
// which were cut, so that the settlement window of a transfer (VAULT-MESSAGING §11.14.10 rule 5) can tell what may still
// be leased. Each collection (``start()``) is a round of its own: what a stopped one tells late is not the next one's.
extension VaultDevice {
    /// A send of the collector (uptime), and how long after it the relay may still hand out what it leases.
    public typealias CollectSent = (at: TimeInterval, wait: TimeInterval)

    /// The collector of the collection [round].
    func collector(of round: Int) -> MailboxCollector {
        MailboxCollector(
            source: RelayMailbox(client: own, transport: cfg.transport, fresh: { [weak self] in self?.collectsFresh ?? false }),
            mode: cfg.collectMode, wait: cfg.pollWait, now: cfg.now,
            onRequest: { [weak self] out in self?.collectorRequest(out, of: round) },
            onRecovered: { [weak self] in self?.relayCameBack() },
            onFailed: { [weak self] e, handed in self?.collectorFailed(e, handed: handed, of: round) },
            onSent: { [weak self] wait in self?.collectorSent(of: round, wait: wait) }
        )
    }

    /// Whether the collector's long polls go on a connection of their own (``HTTPTransport/freshSession()``): while a
    /// settlement window follows this device.
    public var collectsFresh: Bool { mem.withLock { collectFresh } }

    public func setCollectsFresh(_ on: Bool) { mem.withLock { collectFresh = on } }

    /// The collection [round] ended with [e] (a terminal relay error, or anything else): ``collectionEnded``, so that it
    /// is started again. A stopped collection's end is not the next one's.
    func collectionEnded(_ e: Error, of round: Int) {
        let code = (e as? RelayError)?.code ?? String(describing: type(of: e))
        mem.withLock { if round == collectRound { collectEnded = code } }
    }

    /// The request of the collection [round]'s current round goes out (each attempt, after any wait for the network), or
    /// its stream opens or pushes a message: its send time (``collectRequestSent``, ``lastCollectorSent``), when a lease
    /// of what it is handed can begin, and [wait], how long after it the relay may still hand something out.
    func collectorSent(of round: Int, wait: TimeInterval? = nil) {
        let sent = (at: cfg.uptime(), wait: wait ?? cfg.pollWait)
        mem.withLock {
            guard round == collectRound else { return }
            if let since = collectSince { collectSince = (since.at, sent) }
            collectLastSent = sent
        }
    }
}
