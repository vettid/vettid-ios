import Foundation
import Network
import Observation
import VettIDRelay

/// Whether the phone has a network the app may use: an `NWPathMonitor` behind the transport's ``NetworkGate`` (IOS-PLAN
/// §6.6). It says "usable" until the first path arrives, so that nothing waits for a report that may never come. The relay
/// and member-API requests wait for it for a few seconds before they are sent (``HTTPTransport``); a request that then
/// finds no network fails as "no connection". ``restoreCount`` goes up each time a path comes back after none, for the
/// root screen to read a phase that could not be read.
@Observable
final class NetworkMonitor: @unchecked Sendable {
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var satisfied = true
    /// How many times a network came back after none (read on the main actor).
    @MainActor private(set) var restoreCount = 0

    init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "org.vettid.network-monitor", qos: .utility))
    }

    deinit { monitor.cancel() }

    /// The gate for the app's transport.
    var gate: NetworkGate {
        NetworkGate { [weak self] in self?.lock.withLock { self?.satisfied ?? true } ?? true }
    }

    private func update(_ now: Bool) {
        let came: Bool = lock.withLock {
            defer { satisfied = now }
            return now && !satisfied
        }
        if came { Task { @MainActor [weak self] in self?.restoreCount += 1 } }
    }
}
