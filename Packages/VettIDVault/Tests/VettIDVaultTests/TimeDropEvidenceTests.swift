import Foundation
import Testing
@testable import VettIDVault
import VettIDCrypto

// swiftlint:disable line_length

/// A message dropped for its time is reported as evidence of a wrong clock only when it points at the clock: a `ts` too far in
/// the future. A plain expiry (a signal collected late) is not.
@Suite struct TimeDropEvidenceTests {
    let base = VaultDeviceTests()

    func dropped(_ inner: (FakeVault) -> Inner) async throws -> [String] {
        let (d, v) = try await base.pairedDevice()
        let seen = Box<[String]>([])
        let stream = d.droppedForTime()
        let reader = Task { for await t in stream { seen.value.append(t) } }
        try await d.handle(v.msg(try #require(v.keyring.current()).seal(inner(v))))
        try await Task.sleep(for: .milliseconds(200))
        reader.cancel()
        return seen.value
    }

    @Test func aPlainExpiryIsNoEvidenceOfAWrongClock() async throws {
        let late = try await dropped { _ in Inner(id: Ulid.new(), type: "call.ringing", ts: Date().addingTimeInterval(-30), exp: Date().addingTimeInterval(-10), body: Array("{}".utf8)) }
        #expect(late.isEmpty)
    }

    @Test func aTimestampInTheFutureIs() async throws {
        let ahead = try await dropped { _ in Inner(id: Ulid.new(), type: "presence.ping", ts: Date().addingTimeInterval(3_600), exp: Date().addingTimeInterval(3_660), body: Array("{}".utf8)) }
        #expect(ahead == ["presence.ping"])
    }
}

// swiftlint:enable line_length
