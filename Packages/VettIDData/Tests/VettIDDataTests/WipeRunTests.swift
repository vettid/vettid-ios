import Foundation
import Testing
@testable import VettIDData
import VettIDKeys
import VettIDKeysTesting

/// A wipe of this phone fails secure: the session goes first and again last, and only a complete erase says signed out.
/// Mirrors vettid-android `WipeRunTest` (its enrolment guard is the record's: ``AccountRecord/refuseWhileClosed()``).
@MainActor
@Suite struct WipeRunTests {
    @MainActor
    final class Fixture {
        let record: AccountRecord
        var steps: [String] = []
        var phase: AppPhase?
        var marks = 0
        var markFails: Int
        let eraseResult: Bool
        /// What a session asked for at each step got: refused, or opened.
        var sessions: [String] = []

        init(markFails: Int = 0, eraseResult: Bool = true) throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("vettid-wiperun-tests/\(UUID().uuidString)/account")
            record = AccountRecord(store: EncryptedFileStore(
                url: url, purpose: VaultFiles.account, keys: InMemoryFileKeyHolder(), protectedData: ProtectedDataFlag(available: true)
            ))
            try record.reset(LocalAccount(userGuid: "u", vaultID: "v", emailHint: ""))
            self.markFails = markFails
            self.eraseResult = eraseResult
        }

        private func askSession() {
            do {
                try record.refuseWhileClosed()
                sessions.append("opened")
            } catch let f as VaultFailure {
                sessions.append("refused \(f.kind)")
            } catch {
                sessions.append("other")
            }
        }

        var run: WipeRun {
            WipeRun(
                record: record,
                abandonLock: { self.steps.append("abandon") },
                detach: {
                    self.steps.append("detach")
                    self.askSession()
                },
                mark: {
                    self.marks += 1
                    self.askSession()
                    if self.markFails > 0 {
                        self.markFails -= 1
                        throw CocoaError(.fileWriteOutOfSpace)
                    }
                    self.steps.append("mark")
                },
                erase: {
                    self.steps.append("erase")
                    self.askSession()
                    return self.eraseResult
                },
                onEnd: { self.phase = $0 },
                sleep: { _ in }
            )
        }
    }

    @Test func aCompleteWipeSaysSignedOut() async throws {
        let f = try Fixture()
        await f.run.run()
        #expect(f.steps == ["abandon", "detach", "mark", "erase", "abandon", "detach"])
        #expect(f.phase == .signedOut)
        #expect(f.record.value == LocalAccount())
        #expect(!f.record.closed)
    }

    @Test func noSessionOpensWhileTheWipeRuns() async throws {
        let f = try Fixture()
        await f.run.run()
        // A lock retry, the owner check or a refresh during the wipe: refused at every step.
        #expect(f.sessions == Array(repeating: "refused \(FailureKind.busy)", count: 4))
    }

    @Test func aMarkerThatCannotBeWrittenStopsTheWipeAndSaysSo() async throws {
        let f = try Fixture(markFails: Int.max)
        await f.run.run()
        // The session went first (and again last); nothing was erased; the phase is not a clean welcome screen.
        #expect(f.steps == ["abandon", "detach", "abandon", "detach"])
        #expect(f.marks == WipeRun.markAttempts)
        #expect(f.phase == WipeRun.failedPhase)
    }

    @Test func theRecordStaysShutAfterAWipeThatDidNotFinish() async throws {
        let f = try Fixture(markFails: Int.max)
        await f.run.run()
        // The old record was never erased: nothing is written or reset over it, and no session opens.
        #expect(f.record.eraseFailed)
        #expect(try !f.record.update(since: f.record.generation) { $0.transferIn = true })
        #expect(throws: VaultFailure.self) { try f.record.reset(LocalAccount()) }
        #expect(f.record.value.userGuid == "u")
        do {
            try f.record.refuseWhileClosed()
            Issue.record("a session opened after a wipe that did not finish")
        } catch let e as VaultFailure {
            #expect(e.kind == .eraseFailed && e.code == WipeRun.codeWipePending)
        }
    }

    @Test func aMarkerIsTriedAgain() async throws {
        let f = try Fixture(markFails: 1)
        await f.run.run()
        #expect(f.marks == 2)
        #expect(f.phase == .signedOut)
    }

    @Test func anEraseThatLeavesSomethingSaysSo() async throws {
        let f = try Fixture(eraseResult: false)
        await f.run.run()
        #expect(f.phase == WipeRun.failedPhase)
        #expect(f.record.eraseFailed)
    }

    @Test func aRetriedWipeThatCompletesOpensTheRecord() async throws {
        let f = try Fixture(markFails: WipeRun.markAttempts)
        await f.run.run()
        #expect(f.record.eraseFailed)
        // "Try again": the marker can be written now.
        await f.run.run()
        #expect(f.phase == .signedOut)
        #expect(!f.record.closed)
        #expect(f.record.value == LocalAccount())
    }
}
