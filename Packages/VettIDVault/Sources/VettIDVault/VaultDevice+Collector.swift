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
            // While a call holds the background the collection is a long poll that asks for many (``collectsLongPoll(_:)``).
            mode: mem.withLock { collectLongPoll } ? .longPoll : cfg.collectMode, wait: cfg.pollWait,
            max: mem.withLock { collectLongPoll } ? Self.heldCollectMax : RelayClient.defaultMax, now: cfg.now,
            onRequest: { [weak self] out in self?.collectorRequest(out, of: round) },
            onRecovered: { [weak self] in self?.relayCameBack() },
            onFailed: { [weak self] e, handed in self?.collectorFailed(e, handed: handed, of: round) },
            onSent: { [weak self] wait in self?.collectorSent(of: round, wait: wait) }
        )
    }

    /// How many messages a long-poll round asks for while a call holds the background.
    static let heldCollectMax = 100

    /// The mode the collection runs in: the build's, or a long poll while a call holds the background.
    public var collectMode: MailboxCollector.Mode { mem.withLock { collectLongPoll } ? .longPoll : cfg.collectMode }

    /// Collects by long poll (many a round) instead of the WebSocket while [on], and starts the collection over in that mode if
    /// it runs. For a call kept running in the background: the events held unacked (``holdEvents(_:)``) fill the WebSocket's
    /// window of unacked messages (RELAY-PROTOCOL §6.4), and the call's own would wait for their leases; a long poll skips what is
    /// leased and brings the oldest of the rest. A stopped device stays stopped.
    public func collectsLongPoll(_ on: Bool) {
        let restart: Bool = mem.withLock {
            guard collectLongPoll != on else { return false }
            collectLongPoll = on
            // Only a WebSocket collection is switched (and so cut: what the relay handed to the stream that was closed stays leased
            // until its lease ends); a long poll already skips what is leased.
            return cfg.collectMode == .webSocket && !stopped && collector != nil
        }
        if restart {
            stop()
            start()
        }
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

    /// The request of the collection [round]'s current round goes out (each attempt, after any wait for the network),
    /// with [wait], how long after it the relay may still hand something out; or, with nil, its stream opens or pushes a
    /// message. Its send time (``collectRequestSent``, ``lastCollectorSent``) is when a lease of what it is handed can
    /// begin; a stream may push, and lease, at any time while it is open (``streamOpen``).
    func collectorSent(of round: Int, wait: TimeInterval?) {
        let sent = (at: cfg.uptime(), wait: wait ?? 0)
        mem.withLock {
            guard round == collectRound else { return }
            if let since = collectSince { collectSince = (since.at, sent) }
            collectLastSent = sent
            collectStreaming = wait == nil
        }
    }

    /// Whether the collector's stream is open: what it was handed may have been pushed, and leased, as late as now.
    public var streamOpen: Bool { mem.withLock { collectStreaming } }
}
