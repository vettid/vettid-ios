import Foundation

/// Waits until [condition] holds, polling every 10 ms, at most [within] (20 s by default, as the other packages' tests
/// wait); returns whether it held.
@MainActor
func eventually(within: Duration = .seconds(20), _ condition: @MainActor () -> Bool) async -> Bool {
    let end = ContinuousClock.now + within
    while !condition() {
        if ContinuousClock.now >= end { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
