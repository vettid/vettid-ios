import Foundation
import Testing
@testable import VettIDTesting

/// The fake server answers its own session's requests, in order, and records them.
@Test func theFakeServerAnswersInOrder() async throws {
    let s = FakeHTTPServer()
    s.enqueue(.json(201, "{}"), .failure(.cannotConnectToHost))
    var r = URLRequest(url: try #require(URL(string: s.baseURL + "/a?b=1")))
    r.httpMethod = "POST"
    r.httpBody = Data([1, 2])
    let (_, resp) = try await s.session.data(for: r)
    #expect((resp as? HTTPURLResponse)?.statusCode == 201)
    await #expect(throws: URLError.self) { _ = try await s.session.data(from: try #require(URL(string: s.baseURL + "/c"))) }
    #expect(s.requests.map(\.path) == ["/a", "/c"])
    #expect(s.requests[0].body == [1, 2] && s.requests[0].query == "b=1")
}
