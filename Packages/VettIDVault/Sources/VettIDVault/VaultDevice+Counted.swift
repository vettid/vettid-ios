import Foundation
import VettIDCrypto
import VettIDRelay

// What bears on the owner check's estimate of tries left (VAULT-MESSAGING §3.6.4, 0.73.0 §3.6.5): a request that ended
// with no answer may have counted at the vault, and one answered `bad_pin` or `bad_password` did. The app keeps the
// types it counts (vettid-android tags the send's I/O failure with its type for the same purpose).
extension VaultDevice {
    /// The type of each request that ended with no answer (none in time, or a deposit the relay or the network did not
    /// take), or that was answered `bad_pin` or `bad_password`.
    public func countedEnds() -> AsyncStream<String> { countedBroadcast.stream() }

    /// Each time the relay connection came back: a collect round succeeded after failed ones. (A collection started again
    /// is not one: a request restarts it whether or not the relay can be reached.)
    public func relayReconnects() -> AsyncStream<Int> { reconnectBroadcast.stream() }

    /// Runs the deposit of a request of [type]: a failure of the relay or the network is a send without an answer.
    func countingSend<T>(_ type: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let e where e is URLError || e is RelayError {
            countedBroadcast.emit(type)
            throw e
        }
    }

    /// The answer [inner] to a request of [type]: a `bad_pin` or `bad_password` is reported.
    func countingAnswer(_ type: String, _ inner: Inner) -> Inner {
        if inner.status != Inner.statusOK, let code = inner.error?.code, Self.countedCodes.contains(code) {
            countedBroadcast.emit(type)
        }
        return inner
    }

    /// A request of [type] got no answer.
    func countingNoAnswer(_ type: String) { countedBroadcast.emit(type) }

    static let countedCodes: Set<String> = ["bad_pin", "bad_password"]
}
