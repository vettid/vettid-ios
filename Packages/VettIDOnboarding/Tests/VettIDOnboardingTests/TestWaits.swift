import Foundation

/// Waits until [condition] holds, checking every 10 ms, for at most [within] (20 s by default): a wait that returns as
/// soon as the work is done, never a fixed number of yields.
@MainActor
func eventually(within: Duration = .seconds(20), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: within)
    while clock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
