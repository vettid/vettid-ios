import Foundation
import Testing
@testable import VettIDData
import VettIDRelay

/// TEST ONLY. Answers the votes site's requests from a table and records each request as it arrived.
class FakeSiteProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var body: [UInt8] = []
        var headers: [String: String] = [:]
    }

    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var seen: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (reply, url) = Self.lock.withLock { () -> (Reply?, URL) in
            Self.seen.append(request)
            return (request.url.flatMap { Self.replies[$0.path] }, request.url!)
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var headers = reply.headers
        headers["Content-Length"] = headers["Content-Length"] ?? String(reply.body.count)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        if (300..<400).contains(reply.status), let to = headers["Location"], let target = URL(string: to) {
            // Declined by the session (no redirects): the 3xx itself is the answer.
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The reads of the public votes site (IOS-PLAN §4.16 "The site"; ANDROID-PLAN 0.1.107): what each answer comes to, and
/// that a read carries no cookie, no identifier and follows no redirect.
@Suite(.serialized)
struct URLSessionVoteSiteTests {
    func site(_ replies: [String: FakeSiteProtocol.Reply]) -> URLSessionVoteSite {
        FakeSiteProtocol.lock.withLock {
            FakeSiteProtocol.replies = replies
            FakeSiteProtocol.seen = []
        }
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeSiteProtocol.self]
        return URLSessionVoteSite(base: "https://votes.example/", configuration: c, timeout: 5)
    }

    var seen: [URLRequest] { FakeSiteProtocol.lock.withLock { FakeSiteProtocol.seen } }

    @Test func eachAnswerComesToWhatTheVaultIsSent() async {
        let s = site([
            "/v1/services.json": .init(status: 200, body: Array("{}".utf8)),
            "/v1/p/a/proposal.json": .init(status: 404),
            "/v1/p/b/proposal.json": .init(status: 503),
            "/v1/big.json": .init(status: 200, body: [UInt8](repeating: 0x20, count: 2048)),
        ])
        #expect(s.configured)
        #expect(await s.get("services.json") == .found(Array("{}".utf8)))
        #expect(await s.get("p/a/proposal.json") == .absent)
        #expect(await s.get("p/b/proposal.json") == .unreachable)
        #expect(await s.get("big.json", maxBytes: 1024) == .tooLarge)
        // No answer at all.
        #expect(await s.get("nowhere.json") == .unreachable)
    }

    @Test func aRedirectIsNotFollowed() async {
        let s = site([
            "/v1/services.json": .init(status: 302, headers: ["Location": "https://elsewhere.example/v1/services.json"]),
            "/v1/elsewhere": .init(status: 200, body: Array("{}".utf8)),
        ])
        #expect(await s.get("services.json") == .unreachable)
        #expect(!seen.contains { $0.url?.host == "elsewhere.example" })
    }

    @Test func aReadCarriesNoCookieAndTheAppsFixedUserAgent() async throws {
        let s = site(["/v1/index.json": .init(status: 200, body: Array("[]".utf8), headers: ["Set-Cookie": "id=1; Path=/"])])
        _ = await s.get("index.json")
        _ = await s.get("index.json")
        let r = try #require(seen.last)
        #expect(r.url?.absoluteString == "https://votes.example/v1/index.json")
        #expect(r.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(r.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(r.value(forHTTPHeaderField: "User-Agent") == ClientIdentity.userAgent)
    }

    @Test func aBuildWithoutASiteReadsNothing() async {
        let none = URLSessionVoteSite(base: nil)
        #expect(!none.configured)
        #expect(await none.get("services.json") == .unreachable)
        #expect(!URLSessionVoteSite(base: "").configured)
        // Plain HTTP is no site.
        let plain = URLSessionVoteSite(base: "http://votes.example")
        #expect(!plain.configured)
        #expect(await plain.get("services.json") == .unreachable)
    }
}
