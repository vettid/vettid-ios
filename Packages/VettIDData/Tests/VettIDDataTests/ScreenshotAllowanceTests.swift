import Foundation
import Testing
@testable import VettIDData

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1000

    var now: TimeInterval { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}

/// "Allow screenshots" (vettid-android `ScreenshotAllowanceTest`): off at start, an hour at most, off when the vault
/// closes; on for good in development builds.
@MainActor
@Suite struct ScreenshotAllowanceTests {
    @Test func offAtStartAnHourAtMostAndOffWhenTheVaultCloses() {
        let clock = FakeClock()
        let a = ScreenshotAllowance(onByDefault: false) { clock.now }
        #expect(!a.allowed && !a.staysOn)
        a.allow()
        #expect(a.allowed)
        clock.advance(3599)
        a.check()
        #expect(a.allowed)
        clock.advance(1)
        a.check() // on the return to the app: the clock ran while the phone slept
        #expect(!a.allowed)
        a.allow()
        a.vaultClosed()
        #expect(!a.allowed)
        a.allow()
        a.disallow()
        #expect(!a.allowed)
    }

    @Test func developmentBuildsStayOn() {
        let clock = FakeClock()
        let a = ScreenshotAllowance(onByDefault: true) { clock.now }
        #expect(a.allowed && a.staysOn)
        clock.advance(10 * 3600)
        a.check()
        a.vaultClosed()
        #expect(a.allowed)
        a.disallow()
        #expect(!a.allowed)
    }
}
