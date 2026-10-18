import Foundation

/// TEST ONLY. An in-process HTTP server behind `URLProtocol`: each instance answers the requests of the
/// `URLSession` it makes (``session``), from a queue of scripted answers, and records every request it saw. Each server
/// has its own host name, so tests that run in parallel never see each other's requests.
public final class FakeHTTPServer: @unchecked Sendable {
    /// One scripted answer: an HTTP response, or a transport failure.
    public enum Answer: Sendable {
        case response(status: Int, body: [UInt8], headers: [String: String])
        case failure(URLError.Code)

        public static func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Answer {
            .response(status: status, body: Array(body.utf8), headers: ["Content-Type": "application/json"].merging(headers) { $1 })
        }

        public static func empty(_ status: Int) -> Answer { .response(status: status, body: [], headers: [:]) }

        public static func bytes(_ status: Int, _ body: [UInt8], headers: [String: String] = [:]) -> Answer {
            .response(status: status, body: body, headers: headers)
        }
    }

    /// A request as it reached the server.
    public struct Request: Sendable {
        public let method: String
        public let url: URL
        public let headers: [String: String]
        public let body: [UInt8]

        public var path: String { url.path }
        public var query: String? { URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery }

        public func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    public let host: String
    private let lock = NSLock()
    private var queue: [Answer] = []
    private var seen: [Request] = []
    private var handler: (@Sendable (Request) -> Answer)?

    public init() {
        host = "fake-\(UUID().uuidString.lowercased()).test"
        FakeURLProtocol.register(self)
    }

    deinit { FakeURLProtocol.unregister(host) }

    /// The server's base URL.
    public var baseURL: String { "https://\(host)" }

    /// A session whose requests to this server's host are answered by it.
    public var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeURLProtocol.self]
        return URLSession(configuration: c)
    }

    /// Queues answers, served in order.
    public func enqueue(_ answers: Answer...) { lock.withLock { queue += answers } }

    /// Answers every request with [handler] once the queue is empty.
    public func handle(_ handler: @escaping @Sendable (Request) -> Answer) { lock.withLock { self.handler = handler } }

    /// The requests seen so far, oldest first.
    public var requests: [Request] { lock.withLock { seen } }

    public var requestCount: Int { lock.withLock { seen.count } }

    func answer(_ r: Request) -> Answer {
        lock.withLock {
            seen.append(r)
            if !queue.isEmpty { return queue.removeFirst() }
            return handler?(r) ?? .json(599, #"{"code":"fake_server_unscripted"}"#)
        }
    }
}

/// The `URLProtocol` behind ``FakeHTTPServer``.
final class FakeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: FakeHTTPServer] = [:]

    static func register(_ s: FakeHTTPServer) { lock.withLock { servers[s.host] = s } }
    static func unregister(_ host: String) { _ = lock.withLock { servers.removeValue(forKey: host) } }
    private static func server(_ host: String?) -> FakeHTTPServer? { lock.withLock { host.flatMap { servers[$0] } } }

    override static func canInit(with request: URLRequest) -> Bool { server(request.url?.host) != nil }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = Self.server(url.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let r = FakeHTTPServer.Request(
            method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request)
        )
        switch server.answer(r) {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .response(let status, let body, let headers):
            var h = headers
            h["Content-Length"] = String(body.count)
            guard let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// A request's body: URLSession moves `httpBody` into a stream before a protocol sees it.
    private static func body(of r: URLRequest) -> [UInt8] {
        if let b = r.httpBody { return Array(b) }
        guard let s = r.httpBodyStream else { return [] }
        s.open()
        defer { s.close() }
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 16_384)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out += buf[0..<n]
        }
        return out
    }
}
