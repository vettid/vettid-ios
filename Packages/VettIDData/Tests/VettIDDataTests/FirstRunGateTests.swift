import Foundation
import Testing
@testable import VettIDData
import VettIDKeys

/// The first-run gate (IOS-PLAN §6.1): deferred before the first unlock ("Unlock your iPhone"), run again until it ran,
/// then never again in the process.
@Suite struct FirstRunGateTests {
    final class Script: @unchecked Sendable {
        let lock = NSLock()
        var outcomes: [FirstRunCleanup.Outcome]
        var runs = 0

        init(_ outcomes: [FirstRunCleanup.Outcome]) { self.outcomes = outcomes }

        func next() -> FirstRunCleanup.Outcome {
            lock.withLock {
                runs += 1
                return outcomes.removeFirst()
            }
        }
    }

    @Test func aDeferredCleanupKeepsTheGateShutUntilItRuns() throws {
        let s = Script([.deferred, .cleaned])
        let gate = FirstRunGate { s.next() }
        #expect(throws: KeysError.unavailable("first run")) { try gate.ensure() }
        #expect(!gate.isOpen)
        #expect(try gate.ensure() == .cleaned)
        #expect(try gate.ensure() == nil)
        #expect(gate.isOpen && s.runs == 2)
    }

    @Test func dataOrAMarkerOpenTheGate() throws {
        for outcome in [FirstRunCleanup.Outcome.alreadyDone, .dataPresent] {
            let gate = FirstRunGate { outcome }
            #expect(try gate.ensure() == outcome && gate.isOpen)
        }
    }

    /// The vault manager's data files are the cleanup's: their presence refuses it.
    @Test func theManagersFilesRefuseTheCleanup() {
        let dir = URL(fileURLWithPath: "/data")
        let names = VaultFiles.all(in: dir).map(\.lastPathComponent)
        #expect(names == ["account", "vault-device", "phone-secrets", "lock-record", "owner-check", "connections"])
    }
}
