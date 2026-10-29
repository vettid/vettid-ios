import Foundation
import VettIDCrypto

/// Whether the device has a network the app may use right now. ``always`` where nothing tells; the app passes one
/// backed by `NWPathMonitor`.
public struct NetworkGate: Sendable {
    public let usable: @Sendable () -> Bool

    public init(usable: @escaping @Sendable () -> Bool) { self.usable = usable }

    public static let always = NetworkGate { true }
}

/// What the app tells every host about itself (VAULT-MESSAGING 0.75.0 §13.6 "Device details"): exactly `VettID-iOS`,
/// with nothing appended (no app or OS version, model or build), in place of the system's `CFNetwork/x Darwin/y`, on
/// every request the app's own code sends: the member API, the relay (long-polls, WebSocket upgrades, blobs) and any other
/// host. `Accept-Language` is sent empty: the system would otherwise add the phone's languages and region, and the Android
/// app sends no such header (owner decision 2026-10-29, to match Android; the system adds it back when the header is
/// removed, so an empty value is the nearest).
public enum ClientIdentity {
    public static let userAgent = "VettID-iOS"

    /// [r] with the fixed `User-Agent`, replacing any other, and an empty `Accept-Language`.
    public static func identified(_ r: URLRequest) -> URLRequest {
        var r = r
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("", forHTTPHeaderField: "Accept-Language")
        return r
    }
}

/// An HTTP answer: status, headers and at most the requested number of body bytes.
public struct HTTPAnswer: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: [UInt8]

    /// A header by name, case-insensitively.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// A response body larger than the caller allows.
public struct BodyTooLarge: Error, Sendable {
    public let status: Int
}

/// Sends HTTP requests with the transport retry of vettid-android `TransportRetry`: a call that failed in transport
/// (no HTTP status) is retried while the device wakes up, by [Policy]; an answer with a status is never touched, it is
/// the caller's. The request is built again (and so signed again) right before every attempt, after any wait for the
/// network, so that no attempt sends a signature made before a wait (RELAY-PROTOCOL §4.1: a signature is accepted
/// within 90 s of its timestamp and only once).
///
/// URLSession does not say whether a failed request had started going out, so "not sent" is read from the error:
/// a host that could not be found or connected to, or no network, never reached the server.
public struct HTTPTransport: Sendable {
    public enum Policy: Sendable {
        /// GET and HEAD: any transport failure except a timeout and TLS errors.
        case idempotent
        /// Signed requests and every other method: only a failure before the request could reach the server.
        case unsentOnly
        /// Never retried (a relay claim fetch, §6.9).
        case never
    }

    public static let defaultRetries = 2
    public static let defaultNetworkWait: TimeInterval = 8
    public static let defaultBackoff: [TimeInterval] = [0.25, 1]
    static let pollInterval: TimeInterval = 0.1

    public let session: URLSession
    let gate: NetworkGate
    let maxRetries: Int
    let networkWait: TimeInterval
    let backoff: [TimeInterval]
    let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Development only: origin → origin, keeping path and query (the local dev stack's relay and API addresses).
    /// Signatures cover method, path and body, not the host, so they are unaffected.
    let originMap: [String: String]

    public init(
        session: URLSession,
        gate: NetworkGate = .always,
        maxRetries: Int = defaultRetries,
        networkWait: TimeInterval = defaultNetworkWait,
        backoff: [TimeInterval] = defaultBackoff,
        originMap: [String: String] = [:],
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    ) {
        self.session = session
        self.gate = gate
        self.maxRetries = maxRetries
        self.networkWait = networkWait
        self.backoff = backoff
        self.originMap = originMap.reduce(into: [:]) { $0[Self.trimSlash($1.key)] = Self.trimSlash($1.value) }
        self.sleep = sleep
    }

    /// Sends the request [build] makes (called again for every attempt), reading at most [maxBody] body bytes.
    public func send(
        policy: Policy,
        maxBody: Int,
        timeout: TimeInterval? = nil,
        _ build: () throws -> URLRequest
    ) async throws -> HTTPAnswer {
        var budget = networkWait
        var attempt = 0
        while true {
            budget -= try await awaitNetwork(budget)
            var r = try build()
            if let timeout { r.timeoutInterval = timeout }
            do {
                return try await once(prepared(r), maxBody: maxBody)
            } catch let e as URLError {
                try Task.checkCancellation()
                guard attempt < maxRetries, Self.retryable(e, policy) else { throw e }
            }
            try await sleep(backoff.isEmpty ? 0 : backoff[min(attempt, backoff.count - 1)])
            attempt += 1
        }
    }

    private func once(_ r: URLRequest, maxBody: Int) async throws -> HTTPAnswer {
        let (bytes, response) = try await session.bytes(for: r)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.expectedContentLength > Int64(maxBody) { throw BodyTooLarge(status: http.statusCode) }
        var body: [UInt8] = []
        for try await b in bytes {
            guard body.count < maxBody else {
                Bytes.wipe(&body)
                throw BodyTooLarge(status: http.statusCode)
            }
            body.append(b)
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        return HTTPAnswer(status: http.statusCode, headers: headers, body: body)
    }

    /// Waits while no network is usable, at most [budget] seconds; returns how long it waited.
    private func awaitNetwork(_ budget: TimeInterval) async throws -> TimeInterval {
        var waited: TimeInterval = 0
        while waited < budget, !gate.usable() {
            try Task.checkCancellation()
            let step = min(Self.pollInterval, budget - waited)
            try await sleep(step)
            waited += step
        }
        return waited
    }

    /// [r] as it is sent: to its mapped origin (``mapped(_:)``), with the fixed `User-Agent` (``ClientIdentity``).
    public func prepared(_ r: URLRequest) -> URLRequest { ClientIdentity.identified(mapped(r)) }

    /// [r] sent to the origin the dev stack's map names for it (unchanged without a map or a match).
    public func mapped(_ r: URLRequest) -> URLRequest {
        guard !originMap.isEmpty, let url = r.url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = c.scheme, let host = c.host
        else { return r }
        let origin = "\(scheme)://\(host)" + (c.port.map { ":\($0)" } ?? "")
        guard let to = originMap[origin], let target = URLComponents(string: to) else { return r }
        c.scheme = target.scheme
        c.host = target.host
        c.port = target.port
        var out = r
        out.url = c.url
        return out
    }

    private static func trimSlash(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }

    /// Failures that happen before the request can reach the server. `notConnectedToInternet` is not one of them: the
    /// system can report it when the interface drops in the middle of a transfer, so it is retried for idempotent
    /// requests only.
    static let unsent: Set<URLError.Code> = [
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
    ]

    /// Not a passing state of the network: a certificate or pin that does not match, a bad answer, cleartext refused.
    static let fatal: Set<URLError.Code> = [
        .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired, .secureConnectionFailed,
        .appTransportSecurityRequiresSecureConnection, .badServerResponse, .cancelled, .userCancelledAuthentication,
    ]

    /// Whether a transport failure may be retried under [policy].
    static func retryable(_ e: URLError, _ policy: Policy) -> Bool {
        switch policy {
        case .never: return false
        case _ where fatal.contains(e.code): return false
        case _ where unsent.contains(e.code): return true
        case .unsentOnly: return false
        case .idempotent: return e.code != .timedOut
        }
    }
}
