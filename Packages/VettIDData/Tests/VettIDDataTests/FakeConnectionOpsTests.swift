import Testing
@testable import VettIDData

/// The fake itself: several managers share one, and their reads can overlap (a background read started by one, the next one's
/// refresh), so its calls must not race on its records. Run under the thread sanitizer, this is clean only while the fake is
/// isolated.
@Suite struct FakeConnectionOpsTests {
    @Test func manyReadsAtOnceAreAllRecorded() async throws {
        let ops = await FakeConnectionOps()
        await MainActor.run { ops.connections = [#"{"connection_id":"c1","state":"active"}"#] }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask { _ = try await ops.connectionList() }
            }
            try await group.waitForAll()
        }
        #expect(await ops.calls.count == 200)
    }
}
